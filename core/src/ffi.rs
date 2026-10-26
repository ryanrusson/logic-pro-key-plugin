//! C ABI consumed by the Swift Audio Unit. Keep in sync with
//! `include/keyfinder.h`.

use crate::analyzer::{analyze_buffer, Analyzer, Selection, Snapshot};
use crate::key::NOTE_NAMES;
use std::ffi::c_char;

#[repr(C)]
#[derive(Default)]
pub struct KFKeyCandidate {
    pub tonic: i32,
    pub is_minor: i32,
    pub score: f32,
}

#[repr(C)]
#[derive(Default)]
pub struct KFKeyResult {
    /// 1 if a key estimate is available.
    pub has_key: i32,
    /// Source mode the result came from (useful with `KF_MODE_AUTO`).
    pub mode: u32,
    pub tonic: i32,
    pub is_minor: i32,
    pub confidence: f32,
    pub tuning_cents: f32,
    pub tonality: f32,
    pub seconds_analyzed: f32,
    pub voiced_frames: u64,
    pub chroma: [f32; 12],
    pub candidates: [KFKeyCandidate; 4],
}

fn fill(s: &Snapshot, out: &mut KFKeyResult) {
    *out = KFKeyResult {
        mode: s.mode as u32,
        tuning_cents: s.tuning_cents,
        tonality: s.tonality,
        seconds_analyzed: s.seconds,
        voiced_frames: s.voiced_frames,
        chroma: s.chroma,
        ..Default::default()
    };
    if let Some(est) = &s.estimate {
        let best = est.ranked[0].key;
        out.has_key = 1;
        out.tonic = best.tonic as i32;
        out.is_minor = best.minor as i32;
        out.confidence = est.confidence;
        for (dst, c) in out.candidates.iter_mut().zip(&est.ranked) {
            *dst = KFKeyCandidate { tonic: c.key.tonic as i32, is_minor: c.key.minor as i32, score: c.score };
        }
    }
}

/// Rates the decimator is designed for. Anything else (inf, absurd values)
/// would overflow its filter length and abort the host.
fn valid_rate(sample_rate: f64) -> bool {
    sample_rate.is_finite() && (8000.0..=768_000.0).contains(&sample_rate)
}

#[no_mangle]
pub extern "C" fn kf_analyzer_new(sample_rate: f64) -> *mut Analyzer {
    if !valid_rate(sample_rate) {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(Analyzer::new(sample_rate)))
}

/// # Safety
/// `a` must come from `kf_analyzer_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_free(a: *mut Analyzer) {
    if !a.is_null() {
        drop(Box::from_raw(a));
    }
}

/// Realtime-safe. Call from the render thread only (single producer).
///
/// # Safety
/// `left` (and `right`, if non-null) must point to `frames` valid floats.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_push(a: *const Analyzer, left: *const f32, right: *const f32, frames: usize) -> usize {
    if a.is_null() || left.is_null() || frames == 0 {
        return 0;
    }
    let l = std::slice::from_raw_parts(left, frames);
    let r = if right.is_null() { None } else { Some(std::slice::from_raw_parts(right, frames)) };
    (*a).push(l, r)
}

/// Call periodically from one background thread.
///
/// # Safety
/// `a` must be a live analyzer.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_process(a: *const Analyzer) -> usize {
    if a.is_null() { 0 } else { (*a).process() }
}

/// End of input for offline (file) analysis; never for live input.
///
/// # Safety
/// `a` must be a live analyzer.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_finish(a: *const Analyzer) {
    if !a.is_null() {
        (*a).finish();
    }
}

/// # Safety
/// `a` must be a live analyzer; `out` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_result(a: *const Analyzer, mode: u32, out: *mut KFKeyResult) -> i32 {
    if a.is_null() || out.is_null() {
        return 0;
    }
    fill(&(*a).snapshot(Selection::from_u32(mode)), &mut *out);
    (*out).has_key
}

/// Discard accumulated analysis. An unusable `sample_rate` (e.g. <= 0)
/// keeps the current rate.
///
/// # Safety
/// `a` must be a live analyzer.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_reset(a: *const Analyzer, sample_rate: f64) {
    if a.is_null() {
        return;
    }
    (*a).request_reset(valid_rate(sample_rate).then_some(sample_rate));
}

/// # Safety
/// `a` must be a live analyzer.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_set_listening(a: *const Analyzer, on: i32) {
    if !a.is_null() {
        (*a).set_listening(on != 0);
    }
}

/// # Safety
/// `a` must be a live analyzer.
#[no_mangle]
pub unsafe extern "C" fn kf_analyzer_dropped_samples(a: *const Analyzer) -> u64 {
    if a.is_null() { 0 } else { (*a).dropped_samples() }
}

/// Offline analysis of a mono buffer.
///
/// # Safety
/// `mono` must point to `n` floats; `out` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn kf_analyze_buffer(mono: *const f32, n: usize, sample_rate: f64, mode: u32, out: *mut KFKeyResult) -> i32 {
    if mono.is_null() || out.is_null() || !valid_rate(sample_rate) {
        return 0;
    }
    let s = analyze_buffer(std::slice::from_raw_parts(mono, n), sample_rate, Selection::from_u32(mode));
    fill(&s, &mut *out);
    (*out).has_key
}

/// Static, NUL-terminated note name for a pitch class (0 = C).
#[no_mangle]
pub extern "C" fn kf_note_name(pitch_class: i32) -> *const c_char {
    const NAMES: [&[u8]; 12] = [b"C\0", b"C#\0", b"D\0", b"Eb\0", b"E\0", b"F\0", b"F#\0", b"G\0", b"Ab\0", b"A\0", b"Bb\0", b"B\0"];
    debug_assert_eq!(NAMES.len(), NOTE_NAMES.len());
    NAMES[pitch_class.rem_euclid(12) as usize].as_ptr() as *const c_char
}
