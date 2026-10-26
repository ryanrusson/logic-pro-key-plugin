//! KeyFinder core: musical key detection for isolated instrument tracks
//! (bass, guitar) and, with lower accuracy, full mixes.
//!
//! Pipeline: stereo → mono → decimate to ~5.5 kHz → 8192-pt STFT → spectral
//! peak picking → 10-cent pitch-class histogram → tuning estimate → 12-bin
//! chroma → likelihood under 24 learned key profiles → calibrated posterior.

pub mod analyzer;
pub mod chroma;
pub mod decimate;
pub mod ffi;
pub mod key;
// Sound only with one producer and one consumer, which `Analyzer` enforces.
mod ring;

pub use analyzer::{analyze_buffer, Analyzer, Selection, Snapshot};
pub use chroma::SourceMode;
pub use key::{Candidate, Estimate, Key};
