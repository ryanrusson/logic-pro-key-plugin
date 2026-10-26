//! Spectral-peak pitch-class profile (HPCP-style) with tuning estimation.
//!
//! Each analysis frame is windowed and FFT'd; prominent spectral peaks are
//! located with sub-bin precision and folded into a 120-bin (10-cent) pitch
//! class histogram. Keeping 10-cent resolution lets us estimate the
//! recording's tuning offset (e.g. a guitar tuned to A=432) before folding
//! down to the 12 semitone chroma used for key matching.

use realfft::{RealFftPlanner, RealToComplex};
use std::sync::Arc;

pub const FFT_SIZE: usize = 8192;
pub const HOP: usize = 2048;
pub const BINS_PER_SEMITONE: usize = 10;
pub const HIST_BINS: usize = 12 * BINS_PER_SEMITONE;
const MAX_PEAKS: usize = 48;
/// Width, in semitones, of the band-edge tapers.
const EDGE: f32 = 6.0;
const SILENCE_RMS: f32 = 1e-3; // -60 dBFS

/// Which part of the spectrum to trust, tuned for the source material.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum SourceMode {
    /// Isolated bass (or a bass stem). Focus E1..G4, emphasise fundamentals.
    Bass = 0,
    /// Isolated guitar (or "other" stem). E2..E6.
    Guitar = 1,
    /// Full mix or vocals. Wide band; stricter peak picking to reject drums.
    FullMix = 2,
}

impl SourceMode {
    pub const ALL: [SourceMode; 3] = [Self::Bass, Self::Guitar, Self::FullMix];

    pub fn from_u32(v: u32) -> Option<Self> {
        Self::ALL.get(v as usize).copied()
    }

    /// (lowest MIDI note, highest MIDI note, peak-to-local-mean ratio)
    fn params(self) -> (f32, f32, f32) {
        match self {
            Self::Bass => (28.0, 67.0, 2.0),
            Self::Guitar => (40.0, 88.0, 2.0),
            Self::FullMix => (36.0, 96.0, 3.0),
        }
    }

    /// Relative weight of a peak at MIDI pitch `p`. Raised-cosine tapers
    /// avoid hard cut-offs. The low one sits below the band, so the lowest
    /// notes (a bass's open E1) keep full weight. The high one stays inside:
    /// widening it lets the 5th harmonic of low roots (a major third) in and
    /// turns minor keys major. Bass mode favours the low register where the
    /// root normally lives.
    fn weight(self, p: f32) -> f32 {
        let (lo, hi, _) = self.params();
        if p < lo - EDGE || p > hi {
            return 0.0;
        }
        let taper = |d: f32| if d >= EDGE { 1.0 } else { 0.5 - 0.5 * (std::f32::consts::PI * d / EDGE).cos() };
        let w = taper(p - (lo - EDGE)) * taper(hi - p);
        match self {
            Self::Bass => w * (1.0 - 0.5 * ((p - lo) / (hi - lo)).clamp(0.0, 1.0)),
            _ => w,
        }
    }
}

/// Shared front end: frames the decimated signal, windows it and computes
/// the magnitude spectrum once per hop. Each `PitchHistogram` then reads the
/// same spectrum, so analysing several source modes costs one FFT.
pub struct SpectrumFrames {
    rate: f32,
    fft: Arc<dyn RealToComplex<f32>>,
    window: Vec<f32>,
    frame: Vec<f32>,
    spectrum: Vec<realfft::num_complex::Complex<f32>>,
    scratch: Vec<realfft::num_complex::Complex<f32>>,
    mag: Vec<f32>,
    prefix: Vec<f32>,
    pending: Vec<f32>,
    pub frames: u64,
}

/// One analysed frame: magnitude spectrum plus its prefix sum (for O(1)
/// local means during peak picking).
pub struct Frame<'a> {
    pub mag: &'a [f32],
    pub prefix: &'a [f32],
    pub bin_hz: f32,
}

impl SpectrumFrames {
    pub fn new(analysis_rate: f64) -> Self {
        let fft = RealFftPlanner::<f32>::new().plan_fft_forward(FFT_SIZE);
        let window = (0..FFT_SIZE)
            .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / FFT_SIZE as f32).cos())
            .collect();
        Self {
            rate: analysis_rate as f32,
            spectrum: fft.make_output_vec(),
            scratch: fft.make_scratch_vec(),
            frame: vec![0.0; FFT_SIZE],
            mag: vec![0.0; FFT_SIZE / 2 + 1],
            prefix: vec![0.0; FFT_SIZE / 2 + 2],
            fft,
            window,
            pending: Vec::with_capacity(FFT_SIZE * 2),
            frames: 0,
        }
    }

    /// Feed audio at the analysis rate; `on_frame` runs for each non-silent frame.
    pub fn process(&mut self, input: &[f32], mut on_frame: impl FnMut(&Frame)) {
        self.pending.extend_from_slice(input);
        let mut start = 0;
        while self.pending.len() - start >= FFT_SIZE {
            if self.analyze(start) {
                on_frame(&Frame { mag: &self.mag, prefix: &self.prefix, bin_hz: self.rate / FFT_SIZE as f32 });
            }
            start += HOP;
        }
        self.pending.drain(..start);
    }

    /// End of input, for offline analysis only: a clip too short to fill a
    /// single frame is analysed zero-padded, centred so the window doesn't
    /// suppress it.
    pub fn finish(&mut self, mut on_frame: impl FnMut(&Frame)) {
        if self.frames > 0 || self.pending.is_empty() {
            return;
        }
        let pad = (FFT_SIZE - self.pending.len()) / 2;
        self.pending.splice(0..0, std::iter::repeat_n(0.0, pad));
        self.pending.resize(FFT_SIZE, 0.0);
        if self.analyze(0) {
            on_frame(&Frame { mag: &self.mag, prefix: &self.prefix, bin_hz: self.rate / FFT_SIZE as f32 });
        }
        self.pending.clear();
    }

    fn analyze(&mut self, start: usize) -> bool {
        self.frames += 1;
        let src = &self.pending[start..start + FFT_SIZE];
        let rms = (src.iter().map(|x| x * x).sum::<f32>() / FFT_SIZE as f32).sqrt();
        if rms < SILENCE_RMS {
            return false;
        }
        for ((d, s), w) in self.frame.iter_mut().zip(src).zip(&self.window) {
            *d = s * w;
        }
        if self.fft.process_with_scratch(&mut self.frame, &mut self.spectrum, &mut self.scratch).is_err() {
            return false;
        }
        let mut acc = 0.0f32;
        self.prefix[0] = 0.0;
        for (k, c) in self.spectrum.iter().enumerate() {
            let m = c.norm();
            self.mag[k] = m;
            acc += m;
            self.prefix[k + 1] = acc;
        }
        true
    }
}

/// Per-mode pitch-class histogram built from spectral peaks.
pub struct PitchHistogram {
    mode: SourceMode,
    peaks: Vec<(f32, f32)>,
    /// Pitch-class energy at 10-cent resolution, accumulated over all frames.
    pub histogram: [f64; HIST_BINS],
    pub voiced_frames: u64,
    /// Sum and sum of squares of peak weights, for the effective peak count.
    weight_sum: f64,
    weight_sq_sum: f64,
}

impl PitchHistogram {
    pub fn new(mode: SourceMode) -> Self {
        Self {
            mode,
            peaks: Vec::with_capacity(256),
            histogram: [0.0; HIST_BINS],
            voiced_frames: 0,
            weight_sum: 0.0,
            weight_sq_sum: 0.0,
        }
    }

    pub fn mode(&self) -> SourceMode {
        self.mode
    }

    pub fn add_frame(&mut self, f: &Frame) {
        let mag = f.mag;
        let (lo, hi, ratio) = self.mode.params();
        let k_lo = ((midi_to_hz(lo - EDGE - 1.0) / f.bin_hz) as usize).max(2);
        let k_hi = ((midi_to_hz(hi + 1.0) / f.bin_hz) as usize).min(mag.len() - 3);
        if k_lo >= k_hi {
            return;
        }
        let max_mag = mag[k_lo..=k_hi].iter().cloned().fold(0.0f32, f32::max);
        if max_mag <= 0.0 {
            return;
        }
        let floor = max_mag * 1e-3; // -60 dB relative to the frame's loudest peak

        // Local-mean whitening: a peak must stand out from its ±W neighbourhood.
        // Broadband drum energy rarely does; harmonic partials always do.
        const W: usize = 24;
        let peaks = &mut self.peaks;
        peaks.clear(); // (midi pitch, weight)
        for k in k_lo..=k_hi {
            let m = mag[k];
            if m < floor || m <= mag[k - 1] || m < mag[k + 1] {
                continue;
            }
            let a = k.saturating_sub(W);
            let b = (k + W + 1).min(mag.len());
            let local_mean = (f.prefix[b] - f.prefix[a]) / (b - a) as f32;
            if m < ratio * local_mean {
                continue;
            }
            // Parabolic interpolation on log magnitude for sub-bin frequency.
            let (l, c, r) = (mag[k - 1].max(1e-12).ln(), m.ln(), mag[k + 1].max(1e-12).ln());
            let denom = l - 2.0 * c + r;
            let delta = if denom.abs() > 1e-12 { 0.5 * (l - r) / denom } else { 0.0 };
            let pitch = hz_to_midi((k as f32 + delta.clamp(-0.5, 0.5)) * f.bin_hz);
            let w = self.mode.weight(pitch);
            if w > 0.0 {
                peaks.push((pitch, w * m));
            }
        }
        if peaks.is_empty() {
            return;
        }
        peaks.sort_unstable_by(|a, b| b.1.total_cmp(&a.1));
        peaks.truncate(MAX_PEAKS);

        // Normalise per frame so loud passages don't dominate quiet ones, and
        // compress with sqrt so a single loud partial can't swamp the rest.
        let top = peaks[0].1;
        for &(pitch, w) in peaks.iter() {
            let w = ((w / top) as f64).sqrt();
            let pos = pitch.rem_euclid(12.0) * BINS_PER_SEMITONE as f32;
            let i0 = pos.floor() as usize % HIST_BINS;
            let frac = (pos - pos.floor()) as f64;
            self.histogram[i0] += w * (1.0 - frac);
            self.histogram[(i0 + 1) % HIST_BINS] += w * frac;
            self.weight_sum += w;
            self.weight_sq_sum += w * w;
        }
        self.voiced_frames += 1;
    }

    /// Tuning offset in semitones (-0.5..0.5) relative to A440, estimated as
    /// the circular mean of the histogram's deviation from equal temperament.
    pub fn tuning(&self) -> f32 {
        self.tuning_vector().0
    }

    /// How tightly spectral peaks cluster on a 12-TET grid: ~1 for pitched
    /// instruments, near 0 for noise. Used to gate key confidence.
    ///
    /// The resultant length of n random angles is about 1/sqrt(n), so a few
    /// dozen noise peaks would read as tonal. With n the number of
    /// independent peaks (effective count of weighted peaks, divided by the
    /// frame overlap, since each peak shows up in up to FFT_SIZE/HOP
    /// frames), the length is bias-corrected and scaled down unless the
    /// Rayleigh statistic n·r² (≈1 for noise) shows the clustering is
    /// significant.
    pub fn tonality(&self) -> f32 {
        if self.weight_sq_sum <= 0.0 {
            return 0.0;
        }
        let r = self.tuning_vector().1 as f64;
        let overlap = ((FFT_SIZE / HOP) as u64).min(self.voiced_frames.max(1)) as f64;
        let n = self.weight_sum * self.weight_sum / self.weight_sq_sum / overlap;
        if n <= 1.0 {
            return 0.0;
        }
        let z = n * r * r;
        let corrected = ((z - 1.0) / (n - 1.0)).max(0.0).sqrt();
        let significance = ((z - 4.0) / 4.0).clamp(0.0, 1.0);
        (corrected * significance) as f32
    }

    fn tuning_vector(&self) -> (f32, f32) {
        let (mut re, mut im, mut total) = (0.0f64, 0.0f64, 0.0f64);
        for (b, &h) in self.histogram.iter().enumerate() {
            let angle = 2.0 * std::f64::consts::PI * b as f64 / BINS_PER_SEMITONE as f64;
            re += h * angle.cos();
            im += h * angle.sin();
            total += h;
        }
        if total <= 0.0 {
            return (0.0, 0.0);
        }
        ((im.atan2(re) / (2.0 * std::f64::consts::PI)) as f32, (re.hypot(im) / total) as f32)
    }

    /// 12-bin chroma (index 0 = C) folded around the estimated tuning.
    pub fn chroma(&self) -> [f32; 12] {
        let tuning = self.tuning() as f64;
        let mut out = [0.0f64; 12];
        for (b, &h) in self.histogram.iter().enumerate() {
            let semis = b as f64 / BINS_PER_SEMITONE as f64 - tuning;
            let nearest = semis.round();
            let dist = semis - nearest; // within ±0.5
            let w = (std::f64::consts::PI * dist).cos().powi(2);
            out[(nearest as i64).rem_euclid(12) as usize] += h * w;
        }
        let max = out.iter().cloned().fold(0.0, f64::max);
        let mut res = [0.0f32; 12];
        if max > 0.0 {
            for (r, o) in res.iter_mut().zip(out) {
                *r = (o / max) as f32;
            }
        }
        res
    }
}

#[inline]
pub fn midi_to_hz(m: f32) -> f32 {
    440.0 * 2f32.powf((m - 69.0) / 12.0)
}

#[inline]
pub fn hz_to_midi(f: f32) -> f32 {
    69.0 + 12.0 * (f / 440.0).log2()
}
