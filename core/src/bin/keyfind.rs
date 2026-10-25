//! Command-line key detection for WAV files, using the same core as the
//! plugin. Handy for validating against a library of known-key stems.
//!
//!     cargo run --release --features cli -- [--mode auto|bass|guitar|mix] file.wav...

use keyfinder_core::{analyze_buffer, Selection, SourceMode};

fn main() {
    let mut mode = Selection::Auto;
    let mut files = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--mode" => {
                mode = match args.next().as_deref() {
                    Some("bass") => Selection::Mode(SourceMode::Bass),
                    Some("guitar") => Selection::Mode(SourceMode::Guitar),
                    Some("mix") => Selection::Mode(SourceMode::FullMix),
                    Some("auto") => Selection::Auto,
                    other => die(&format!("unknown mode {other:?} (auto|bass|guitar|mix)")),
                }
            }
            "-h" | "--help" => die("usage: keyfind [--mode auto|bass|guitar|mix] file.wav..."),
            _ => files.push(a),
        }
    }
    if files.is_empty() {
        die("usage: keyfind [--mode auto|bass|guitar|mix] file.wav...");
    }
    for path in files {
        match read_mono(&path) {
            Ok((mono, rate)) => {
                let t = std::time::Instant::now();
                let s = analyze_buffer(&mono, rate, mode);
                let ms = t.elapsed().as_secs_f64() * 1000.0;
                match &s.estimate {
                    Some(e) => {
                        let alts: Vec<String> = e.ranked[1..4].iter().map(|c| format!("{} {:.2}", c.key.name(), c.score)).collect();
                        println!(
                            "{path}: {}  ({:?})  confidence {:.0}%  tuning {:+.0}c  [{:.1}s audio in {ms:.0} ms]  alt: {}",
                            e.ranked[0].key.name(),
                            s.mode,
                            e.confidence * 100.0,
                            s.tuning_cents,
                            s.seconds,
                            alts.join(", ")
                        );
                    }
                    None => println!("{path}: no tonal content found"),
                }
            }
            Err(e) => eprintln!("{path}: {e}"),
        }
    }
}

fn read_mono(path: &str) -> Result<(Vec<f32>, f64), hound::Error> {
    let mut r = hound::WavReader::open(path)?;
    let spec = r.spec();
    let ch = spec.channels.max(1) as usize;
    let interleaved: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => r.samples::<f32>().collect::<Result<_, _>>()?,
        hound::SampleFormat::Int => {
            let scale = 1.0 / (1u64 << (spec.bits_per_sample - 1)) as f32;
            r.samples::<i32>().map(|s| s.map(|v| v as f32 * scale)).collect::<Result<_, _>>()?
        }
    };
    let mono = interleaved.chunks(ch).map(|f| f.iter().sum::<f32>() / ch as f32).collect();
    Ok((mono, spec.sample_rate as f64))
}

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(2)
}
