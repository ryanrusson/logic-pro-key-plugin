//! Streaming integer-factor decimator (windowed-sinc FIR low-pass + downsample).
//!
//! Key detection only needs content up to ~2.1 kHz (MIDI 96), so we run the
//! spectral analysis at ~5.5 kHz. That buys a large FFT (good low-frequency
//! resolution for bass) at a fraction of the CPU cost of full-rate analysis.

/// Target analysis rate. The real rate is `input_rate / factor`.
pub const TARGET_RATE: f64 = 5512.5;

pub struct Decimator {
    factor: usize,
    taps: Vec<f32>,
    history: Vec<f32>,
    pos: usize,
    phase: usize,
}

impl Decimator {
    pub fn new(input_rate: f64) -> Self {
        let factor = ((input_rate / TARGET_RATE).floor() as usize).max(1);
        let taps = if factor == 1 { vec![1.0] } else { design_lowpass(factor) };
        let len = taps.len();
        Self { factor, taps, history: vec![0.0; len], pos: 0, phase: 0 }
    }

    pub fn factor(&self) -> usize {
        self.factor
    }

    /// Feed input samples; decimated output is appended to `out`.
    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        let n = self.taps.len();
        for &x in input {
            self.history[self.pos] = x;
            self.pos = (self.pos + 1) % n;
            self.phase += 1;
            if self.phase == self.factor {
                self.phase = 0;
                // history[pos] is now the oldest sample.
                let (newer, older) = self.history.split_at(self.pos);
                let mut acc = 0.0f32;
                let mut t = self.taps.iter();
                for (&h, &c) in older.iter().chain(newer.iter()).zip(&mut t) {
                    acc += h * c;
                }
                out.push(acc);
            }
        }
    }
}

/// Blackman-windowed sinc low-pass with cutoff at 90% of the new Nyquist.
fn design_lowpass(factor: usize) -> Vec<f32> {
    let len = 16 * factor + 1;
    let fc = 0.9 * 0.5 / factor as f64; // cycles per input sample
    let mid = (len - 1) as f64 / 2.0;
    let mut taps: Vec<f64> = (0..len)
        .map(|i| {
            let x = i as f64 - mid;
            let sinc = if x == 0.0 {
                2.0 * fc
            } else {
                (2.0 * std::f64::consts::PI * fc * x).sin() / (std::f64::consts::PI * x)
            };
            let w = 0.42 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (len - 1) as f64).cos()
                + 0.08 * (4.0 * std::f64::consts::PI * i as f64 / (len - 1) as f64).cos();
            sinc * w
        })
        .collect();
    let sum: f64 = taps.iter().sum();
    taps.iter_mut().for_each(|t| *t /= sum);
    taps.into_iter().map(|t| t as f32).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone_rms(freq: f64, rate: f64) -> f32 {
        let mut d = Decimator::new(rate);
        let input: Vec<f32> = (0..(rate as usize))
            .map(|i| (2.0 * std::f64::consts::PI * freq * i as f64 / rate).sin() as f32)
            .collect();
        let mut out = Vec::new();
        d.process(&input, &mut out);
        let tail = &out[out.len() / 2..];
        (tail.iter().map(|x| x * x).sum::<f32>() / tail.len() as f32).sqrt()
    }

    #[test]
    fn passes_band_and_rejects_alias() {
        assert_eq!(Decimator::new(44100.0).factor(), 8);
        assert_eq!(Decimator::new(48000.0).factor(), 8);
        assert!((tone_rms(440.0, 44100.0) - 0.707).abs() < 0.02);
        // 10 kHz would alias straight into the analysis band without filtering.
        assert!(tone_rms(10_000.0, 44100.0) < 0.001);
    }
}
