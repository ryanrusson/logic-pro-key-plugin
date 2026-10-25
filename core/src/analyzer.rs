//! Top-level analyzer: realtime-safe input on one side, background analysis
//! and result queries on the other.

use crate::chroma::{PitchHistogram, SourceMode, SpectrumFrames};
use crate::decimate::Decimator;
use crate::key::{self, Estimate};
use crate::ring::SpscRing;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;

/// ~10 s of audio at 96 kHz; the consumer drains every ~50-100 ms.
const RING_CAPACITY: usize = 1 << 20;

/// Which analysis to report.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Selection {
    Mode(SourceMode),
    /// Whichever mode is most confident.
    Auto,
}

impl Selection {
    pub fn from_u32(v: u32) -> Self {
        SourceMode::from_u32(v).map_or(Self::Auto, Self::Mode)
    }
}

/// All source modes are analysed in parallel from one shared spectrum, so the
/// user can switch modes instantly without replaying the track.
pub struct Engine {
    decimator: Decimator,
    spectrum: SpectrumFrames,
    modes: [PitchHistogram; 3],
    input_rate: f64,
    scratch_in: Vec<f32>,
    scratch_out: Vec<f32>,
    samples_in: u64,
}

impl Engine {
    pub fn new(input_rate: f64) -> Self {
        let decimator = Decimator::new(input_rate);
        let analysis_rate = input_rate / decimator.factor() as f64;
        Self {
            spectrum: SpectrumFrames::new(analysis_rate),
            modes: SourceMode::ALL.map(PitchHistogram::new),
            decimator,
            input_rate,
            scratch_in: Vec::with_capacity(RING_CAPACITY),
            scratch_out: Vec::with_capacity(RING_CAPACITY / 4),
            samples_in: 0,
        }
    }

    pub fn feed(&mut self, mono: &[f32]) {
        self.samples_in += mono.len() as u64;
        self.scratch_out.clear();
        self.decimator.process(mono, &mut self.scratch_out);
        let modes = &mut self.modes;
        self.spectrum.process(&self.scratch_out, |f| modes.iter_mut().for_each(|m| m.add_frame(f)));
    }

    fn snapshot_mode(&self, h: &PitchHistogram) -> Snapshot {
        let chroma = h.chroma();
        Snapshot {
            mode: h.mode(),
            estimate: key::estimate(&chroma, h.tonality()),
            chroma,
            tuning_cents: h.tuning() * 100.0,
            tonality: h.tonality(),
            seconds: (self.samples_in as f64 / self.input_rate) as f32,
            voiced_frames: h.voiced_frames,
        }
    }

    pub fn snapshot(&self, sel: Selection) -> Snapshot {
        match sel {
            Selection::Mode(m) => self.snapshot_mode(&self.modes[m as usize]),
            Selection::Auto => {
                let conf = |s: &Snapshot| s.estimate.as_ref().map_or(-1.0, |e| e.confidence);
                self.modes
                    .iter()
                    .map(|h| self.snapshot_mode(h))
                    .reduce(|best, s| if conf(&s) > conf(&best) { s } else { best })
                    .expect("three modes")
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    /// The mode this result came from (relevant for `Selection::Auto`).
    pub mode: SourceMode,
    pub estimate: Option<Estimate>,
    pub chroma: [f32; 12],
    pub tuning_cents: f32,
    /// 0..1, how pitched the material is (see `PitchHistogram::tonality`).
    pub tonality: f32,
    pub seconds: f32,
    pub voiced_frames: u64,
}

/// Thread roles:
/// * render thread: `push` only (wait-free, no allocation, no locks)
/// * one analysis thread: `process`
/// * any thread: `snapshot`, `request_reset`, `set_listening`
pub struct Analyzer {
    ring: SpscRing,
    engine: Mutex<Engine>,
    listening: AtomicBool,
    reset_requested: AtomicBool,
    pending_rate: AtomicU64, // f64 bits
}

impl Analyzer {
    pub fn new(sample_rate: f64) -> Self {
        Self {
            ring: SpscRing::with_capacity_pow2(RING_CAPACITY),
            engine: Mutex::new(Engine::new(sample_rate)),
            listening: AtomicBool::new(true),
            reset_requested: AtomicBool::new(false),
            pending_rate: AtomicU64::new(sample_rate.to_bits()),
        }
    }

    /// Realtime-safe. Downmixes to mono into the ring buffer.
    #[inline]
    pub fn push(&self, left: &[f32], right: Option<&[f32]>) -> usize {
        if !self.listening.load(Ordering::Relaxed) {
            return 0;
        }
        match right {
            Some(r) => self.ring.push_with(left.len().min(r.len()), |i| 0.5 * (left[i] + r[i])),
            None => self.ring.push_with(left.len(), |i| left[i]),
        }
    }

    pub fn set_listening(&self, on: bool) {
        self.listening.store(on, Ordering::Relaxed);
    }

    /// Clear accumulated analysis, optionally at a new sample rate. Applied by
    /// the next `process` call so it never races with the render thread.
    pub fn request_reset(&self, sample_rate: Option<f64>) {
        if let Some(sr) = sample_rate {
            self.pending_rate.store(sr.to_bits(), Ordering::Relaxed);
        }
        self.reset_requested.store(true, Ordering::Release);
    }

    /// Drain and analyze buffered audio. Returns samples consumed.
    pub fn process(&self) -> usize {
        let mut guard = self.engine.lock().unwrap_or_else(|e| e.into_inner());
        let engine = &mut *guard;
        let mut buf = std::mem::take(&mut engine.scratch_in);
        buf.clear();
        let n = self.ring.drain_into(&mut buf);
        if self.reset_requested.swap(false, Ordering::Acquire) {
            *engine = Engine::new(f64::from_bits(self.pending_rate.load(Ordering::Relaxed)));
            buf.clear(); // audio captured before the reset is discarded
        } else if n > 0 {
            engine.feed(&buf);
        }
        engine.scratch_in = buf;
        n
    }

    pub fn snapshot(&self, sel: Selection) -> Snapshot {
        self.engine.lock().unwrap_or_else(|e| e.into_inner()).snapshot(sel)
    }

    pub fn dropped_samples(&self) -> u64 {
        self.ring.dropped()
    }
}

/// One-shot analysis of a whole mono buffer (e.g. a decoded audio file).
pub fn analyze_buffer(mono: &[f32], sample_rate: f64, sel: Selection) -> Snapshot {
    let mut e = Engine::new(sample_rate);
    for chunk in mono.chunks(1 << 16) {
        e.feed(chunk);
    }
    e.snapshot(sel)
}
