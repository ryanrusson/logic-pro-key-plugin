//! End-to-end accuracy tests on synthesized music.

use keyfinder_core::{analyze_buffer, Analyzer, Key, Selection, SourceMode};
use std::f64::consts::PI;

const SR: f64 = 44100.0;

/// Tiny deterministic PRNG so tests are reproducible without a dependency.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
    }
}

fn midi_hz(m: f64, cents: f64) -> f64 {
    440.0 * 2f64.powf((m - 69.0 + cents / 100.0) / 12.0)
}

/// Plucked-string-ish note: decaying harmonics with 1/h amplitude.
fn add_note(buf: &mut [f32], start: usize, len: usize, midi: f64, cents: f64, amp: f32) {
    let f0 = midi_hz(midi, cents);
    for i in 0..len.min(buf.len().saturating_sub(start)) {
        let t = i as f64 / SR;
        let env = (-t * 2.5).exp() * (1.0 - (-t * 200.0).exp());
        let mut s = 0.0;
        for h in 1..=8 {
            let f = f0 * h as f64;
            if f < SR / 2.0 {
                s += (2.0 * PI * f * t).sin() / h as f64;
            }
        }
        buf[start + i] += amp * (env * s) as f32;
    }
}

/// Each step is (chord notes as MIDI, bass MIDI). One step per second.
fn render(steps: &[(&[i32], i32)], repeats: usize, cents: f64, with_chords: bool, with_bass: bool) -> Vec<f32> {
    let step = SR as usize;
    let mut buf = vec![0.0f32; step * steps.len() * repeats];
    for r in 0..repeats {
        for (i, (chord, bass)) in steps.iter().enumerate() {
            let start = (r * steps.len() + i) * step;
            if with_chords {
                for &n in chord.iter() {
                    add_note(&mut buf, start, step, n as f64, cents, 0.12);
                }
            }
            if with_bass {
                add_note(&mut buf, start, step / 2, *bass as f64, cents, 0.35);
                add_note(&mut buf, start + step / 2, step / 2, (*bass + 7) as f64, cents, 0.25);
            }
        }
    }
    buf
}

/// Kick + hi-hat noise bursts on every beat at 120 bpm.
fn add_drums(buf: &mut [f32], level: f32) {
    let mut rng = Lcg(42);
    let beat = (SR / 2.0) as usize;
    for b in 0..buf.len() / beat {
        let s = b * beat;
        for i in 0..4000.min(buf.len() - s) {
            let t = i as f64 / SR;
            let kick = (2.0 * PI * (50.0 + 80.0 * (-t * 30.0).exp()) * t).sin() * (-t * 12.0).exp();
            buf[s + i] += level * kick as f32;
        }
        let h = s + beat / 2;
        for i in 0..2500.min(buf.len().saturating_sub(h)) {
            let env = (-(i as f32) / 400.0).exp();
            buf[h + i] += level * 0.6 * env * rng.next();
        }
    }
}

const C_MAJOR: &[(&[i32], i32)] = &[
    (&[60, 64, 67], 36), // C
    (&[57, 60, 65], 41), // F
    (&[59, 62, 67], 43), // G
    (&[57, 60, 64], 45), // Am
    (&[60, 65, 69], 41), // F
    (&[59, 62, 67], 43), // G
    (&[60, 64, 67], 36), // C
    (&[60, 64, 67], 36), // C
];

const A_MINOR: &[(&[i32], i32)] = &[
    (&[57, 60, 64], 45), // Am
    (&[57, 62, 65], 38), // Dm
    (&[56, 59, 64], 40), // E (harmonic minor V)
    (&[57, 60, 64], 45), // Am
    (&[53, 57, 60], 41), // F
    (&[56, 59, 64], 40), // E
    (&[57, 60, 64], 45), // Am
    (&[57, 60, 64], 45), // Am
];

fn transpose(steps: &[(&[i32], i32)], by: i32) -> Vec<(Vec<i32>, i32)> {
    steps.iter().map(|(c, b)| (c.iter().map(|n| n + by).collect(), b + by)).collect()
}

fn detect(buf: &[f32], mode: SourceMode) -> (Key, f32, f32) {
    let s = analyze_buffer(buf, SR, Selection::Mode(mode));
    let e = s.estimate.expect("estimate");
    (e.ranked[0].key, e.confidence, s.tuning_cents)
}

#[test]
fn c_major_guitar() {
    let (k, conf, _) = detect(&render(C_MAJOR, 4, 0.0, true, false), SourceMode::Guitar);
    assert_eq!(k.name(), "C major");
    assert!(conf > 0.2, "confidence {conf}");
}

#[test]
fn a_minor_guitar_is_not_confused_with_relative_major() {
    let (k, _, _) = detect(&render(A_MINOR, 4, 0.0, true, false), SourceMode::Guitar);
    assert_eq!(k.name(), "A minor");
}

#[test]
fn bass_line_alone() {
    let (k, _, _) = detect(&render(C_MAJOR, 4, 0.0, false, true), SourceMode::Bass);
    assert_eq!(k.name(), "C major");
    let (k, _, _) = detect(&render(A_MINOR, 4, 0.0, false, true), SourceMode::Bass);
    assert_eq!(k.name(), "A minor");
}

#[test]
fn every_transposition() {
    for t in 0..12 {
        for (prog, minor) in [(C_MAJOR, false), (A_MINOR, true)] {
            let owned = transpose(prog, t - 6);
            let steps: Vec<(&[i32], i32)> = owned.iter().map(|(c, b)| (c.as_slice(), *b)).collect();
            let (k, _, _) = detect(&render(&steps, 3, 0.0, true, true), SourceMode::FullMix);
            let tonic = ((if minor { 9 } else { 0 }) + t - 6).rem_euclid(12) as u8;
            assert_eq!(k, Key { tonic, minor }, "transposed by {}", t - 6);
        }
    }
}

#[test]
fn detuned_recording_is_compensated() {
    // +40 cents is nearly half way to C#: without tuning estimation this flips.
    let buf = render(C_MAJOR, 4, 40.0, true, true);
    let (k, _, cents) = detect(&buf, SourceMode::Guitar);
    assert_eq!(k.name(), "C major");
    assert!((cents - 40.0).abs() < 8.0, "tuning {cents}");
    let (_, _, cents) = detect(&render(C_MAJOR, 4, -25.0, true, true), SourceMode::Guitar);
    assert!((cents + 25.0).abs() < 8.0, "tuning {cents}");
}

#[test]
fn full_mix_with_drums() {
    let mut buf = render(A_MINOR, 4, 0.0, true, true);
    add_drums(&mut buf, 0.8);
    let (k, _, _) = detect(&buf, SourceMode::FullMix);
    assert_eq!(k.name(), "A minor");
}

#[test]
fn noise_and_silence_have_no_confident_key() {
    assert!(analyze_buffer(&vec![0.0; SR as usize * 5], SR, Selection::Auto).estimate.is_none());
    let mut rng = Lcg(7);
    let noise: Vec<f32> = (0..SR as usize * 10).map(|_| 0.3 * rng.next()).collect();
    if let Some(e) = analyze_buffer(&noise, SR, Selection::Auto).estimate {
        assert!(e.confidence < 0.3, "noise confidence {}", e.confidence);
    }
}

#[test]
fn streaming_matches_offline_and_reset_clears() {
    let left = render(C_MAJOR, 3, 0.0, true, true);
    let right: Vec<f32> = left.iter().map(|x| x * 0.8).collect();
    let a = Analyzer::new(48000.0);
    a.request_reset(Some(SR));
    a.process();
    for (l, r) in left.chunks(512).zip(right.chunks(512)) {
        a.push(l, Some(r));
        a.process();
    }
    for sel in [Selection::Mode(SourceMode::Bass), Selection::Mode(SourceMode::Guitar), Selection::Auto] {
        assert_eq!(a.snapshot(sel).estimate.unwrap().ranked[0].key.name(), "C major", "{sel:?}");
    }
    let snap = a.snapshot(Selection::Auto);
    assert!((snap.seconds - 24.0).abs() < 0.1);
    assert_eq!(a.dropped_samples(), 0);

    a.request_reset(None);
    a.process();
    assert!(a.snapshot(Selection::Auto).estimate.is_none());
}

#[test]
fn auto_mode_on_a_mix_with_drums() {
    let mut buf = render(C_MAJOR, 4, 0.0, true, true);
    add_drums(&mut buf, 0.8);
    let s = analyze_buffer(&buf, SR, Selection::Auto);
    assert_eq!(s.estimate.unwrap().ranked[0].key.name(), "C major");
}
