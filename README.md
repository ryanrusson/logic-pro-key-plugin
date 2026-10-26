# KeyFinder: key detection for Logic Pro

KeyFinder is an Audio Unit (AUv3) effect for Logic Pro. Insert it on a track, play the track, and it shows the key, a confidence level, the tuning offset, and the closest alternative keys. It works best on a single guitar or bass recording. On a full mix, run Logic's Stem Splitter first and put KeyFinder on the bass or guitar stem.

```
┌──────────────────────── Logic Pro (host process) ────────────────────────┐
│  track ──▶ [KeyFinder AUv3]  ──▶ (audio passes through untouched)          │
│              │ render thread: copy samples into wait-free ring buffer     │
└──────────────┼────────────────────────────────────────────────────────────┘
               ▼
   Rust core (static lib, C ABI)            Swift (AUv3 + SwiftUI)
   ───────────────────────────              ────────────────────────────
   SPSC ring buffer (no locks/allocs)       RenderBlock.m         render block (ObjC)
   stereo → mono → FIR decimate ~5.5 kHz    KeyDetectorAudioUnit  state save/restore
   8192-pt STFT (one FFT, shared)           AnalysisEngine        100 ms drain timer
   ├─ Bass    E1–G4  peak picking ─┐        KeyDetectorView       key, confidence,
   ├─ Guitar  E2–E6  peak picking ─┼─ 10¢                         chroma, mode picker
   └─ FullMix C2–C7  strict peaks ─┘  pitch histogram
   tuning estimate → 12-bin chroma
   learned key profiles → 24-key posterior → calibrated confidence
```

## Why Swift + Rust (and not Go)

| Layer | Language | Reason |
|---|---|---|
| AUv3 extension, UI, Logic state | **Swift** | AUv3 is an Objective-C/Swift API, and SwiftUI is native. |
| Render block | **Objective-C** | Swift converts the host's pull-input block to a closure on every render call, which allocates. The Objective-C block only calls the pull block, `memcpy` and the core. |
| DSP, ring buffer, key model | **Rust** | No garbage collector or runtime, predictable latency, `#[no_mangle]` C ABI that Swift imports as a module, and testable on any OS. |
| — | ~~Go~~ | Go isn't a good fit inside an audio plugin. Its garbage collector and goroutine scheduler would run inside Logic's process, cgo calls cost too much for per-buffer work, and two Go-built plugins can't share one process. Go would only make sense for separate helper tools, and this project doesn't need any. |

Performance: the core analyses 4 minutes of 48 kHz audio in about 240 ms, roughly 1000× faster than realtime, with all three source modes running at once. On Logic's audio thread the plugin only does a bounds-checked copy into a preallocated ring buffer. It never locks or allocates there.

## What it can and can't do inside Logic

These are platform limits, not missing features:

- **A plugin can't trigger Logic's Stem Splitter.** Logic has no API, AppleScript dictionary, or plugin hook for it, and Audio Units can't control the host. The workflow below adds one manual step. If KeyFinder sees a full mix with low confidence, it suggests that step.
- **A plugin can't see other tracks or "select" a track.** It analyses the track it's inserted on. The track you insert it on is the selection.
- **A plugin can't write Logic's project key signature.** You set it yourself (Project Settings or the key signature in the LCD) using the key KeyFinder shows.
- **Live input requires playback.** An AUv3 only receives audio while Logic plays it. You can also drop an audio file (such as a bounced or exported stem) onto the plugin window or the KeyFinder app for instant offline analysis. Dropping files works in the standalone app. Whether Logic accepts drops onto the plugin window is not verified.

The way to get instant, no-playback analysis of a selected region is **ARA 2**, the extension Melodyne uses. Logic supports it, and it gives a plugin random access to region audio. It's on the roadmap below. It means C++ against the ARA SDK and an AUv2 wrapper, so it's a separate phase.

## Workflow

**Single guitar or bass track**
1. On the track: Audio FX › KeyFinder › Key Detector.
2. Play 20–30 seconds or more. Confidence rises as audio accumulates.
3. Leave the mode on **Auto**, or pick **Bass** or **Guitar**. All modes are computed together, so switching is instant.

**Mixed track (vocals, drums, instruments)**
1. Control-click the audio region › **Stem Splitter** (Logic Pro 11+). Choose Bass, and Guitar if your Logic version offers it.
2. Insert KeyFinder on the **Bass** stem. Bass is usually the most reliable stem because it states the root. Use the Guitar/Other stem as a cross-check.
3. Or skip splitting and use **Full Mix** mode. It's tuned to reject drums but is less reliable on dense mixes.

Confidence is the estimated chance that the key is right. On Logic's Apple Loops, High (60% or more) is right about two times in three. Check the alternatives when confidence is Medium or Low: the relative and fifth-related keys are the usual near misses.

The detected key and mode are saved in the Logic project, so reopening a session shows the key without replaying.

## Building (macOS 13+, Xcode 15+)

```sh
brew install xcodegen
curl https://sh.rustup.rs -sSf | sh   # if Rust isn't installed
make build                           # Rust xcframework → Xcode project → build
open plugin/build/Build/Products/Release/KeyFinder.app   # registers the AU
```

Launch the app once so macOS registers the extension, then rescan in Logic (Settings › Plug-in Manager). To validate the AU: `auval -v aufx kyDt KyFn`. Builds are signed to run locally. Set `DEVELOPMENT_TEAM` in `plugin/project.yml` before distributing.

On a fresh Xcode install, accept the license first (`sudo xcodebuild -license accept`, then `sudo xcodebuild -runFirstLaunch`). Otherwise every `xcrun`, `xcodebuild` and Homebrew build fails.

**Without Xcode.** With only the Command Line Tools (`xcode-select --install`), `make build-clt` builds the same universal, ad-hoc signed app with `swiftc` and `clang` into `plugin/build/clt/KeyFinder.app`. It needs no XcodeGen. It generates the Info.plists and entitlements from `plugin/project.yml`, so keep that file the single source of truth.

**Registering and validating without launching the app:**

```sh
make auval                                   # registers the Xcode build, then auval -strict
make auval APP=plugin/build/clt/KeyFinder.app   # same for the Command Line Tools build
```

`make register` first unregisters any other copy of the extension. Both builds share a bundle identifier, and with two copies registered, macOS picks one of them unpredictably.

## Testing the core (any OS)

```sh
make test     # unit tests + synthetic accuracy tests + C ABI smoke test
cd core && cargo run --release --features cli -- --mode auto song.wav stem_bass.wav
```

The accuracy suite renders chord progressions and bass lines in all 24 keys and checks:

- major vs. relative minor (C major vs. A minor)
- recordings detuned by +40¢ and −25¢
- a full mix with kick and hi-hat
- that noise and silence don't produce a confident key

Synthetic audio says little about real recordings, so key accuracy is measured on real audio too (below).

## Real-audio benchmark (Apple Loops, macOS)

Logic's Apple Loops (`/Library/Audio/Apple Loops`, about 3,200 CAF files) carry a key label in their metadata. The benchmark runs every pitched, labelled loop through the plugin's own file path: AVFoundation decode in `AnalyzerHandle.swift`, then the Rust core.

```sh
scripts/bench-apple-loops.sh                        # writes core/target/bench/apple-loops.tsv and prints the scores
scripts/bench-apple-loops.sh new.tsv old.tsv        # also compares with an earlier run, loop by loop
python3 scripts/bench/train.py core/target/bench/apple-loops.tsv   # refit the key model
```

It needs Rust, the Command Line Tools and Logic's loop library (Logic › Settings › Sound Library). The script builds the core and a small `swiftc` harness (`scripts/bench/main.swift` with the plugin's `AnalyzerHandle.swift` and `KeyResult.swift`), then analyses the loops in 8 parallel shards, which takes about 7 s. `LOOPS` and `JOBS` override the folder and the shard count.

Labels come from the CAF `info` and `uuid` chunks: `key signature` (the tonic), `key type` and `category`. Drums, Percussion and Sound Effect loops are skipped, as are loops with no usable key. That leaves 1,416 loops labelled major or minor and 292 labelled "both" (a riff that fits either), with a median length of 8 s. `scripts/bench/score.py` reports:

- **exact**: the right tonic and major/minor.
- **MIREX**: the weighted score as mir_eval defines it: 1 for exact, 0.5 for a fifth above, 0.3 for the relative key and 0.2 for the parallel key.
- **tonic** and **both**: the right tonic, ignoring major/minor, for major/minor loops and for "both" loops.
- **confidence calibration**: the share of loops shown as High (≥ 0.6), Medium and Low confidence, and how often each band is right.
- **exact by category** (Bass, Guitars, Keyboards, Mixed, Other) and the **error intervals**: the detected tonic minus the labelled one, with the mode kept or flipped.
- with a baseline, the change in each mode, with McNemar's z over the loops one run gets right and the other wrong. |z| < 2, or about 1–2 points of exact accuracy, is noise.

Results (Auto mode, 1,416 major/minor loops):

| | exact | MIREX | both (tonic) | High confidence: share of loops, right |
|---|---|---|---|---|
| Krumhansl-Kessler + Temperley, Auto = most confident mode | 36.8% | 0.470 | 53.8% | 58.5%, 45.4% |
| Learned profiles, Auto = mean posterior | 44.4% | 0.538 | 63.4% | 10.9%, 65.2% |
| same, two-fold cross-validation | 43.9% | 0.532 | 63.4% | 11.3%, 69.4% |

The key profiles and calibration constants in `core/src/key.rs` are fitted to these loops. The cross-validated row (fitted on one half, scored on the other) is the accuracy to expect on loops the model hasn't seen. A leave-one-genre-out split gives about 42%. Loops are short and often state only a root and fifth, so many are ambiguous: a plain STFT chroma with the classical profiles also scored 33–36%. Accuracy doesn't improve past about 6 s of audio. Tried and dropped, because the benchmark didn't support them: suppressing odd harmonics, a lowest-note (bass) histogram as tonic evidence or as a separate expert, a bonus for the loudest pitch class, mixture profiles, and stronger or weaker peak compression.

After changing the DSP, rerun the benchmark, then `train.py`. It prints the cross-validated scores and the refitted constants to paste into `key.rs`.

## Layout

```
core/                 Rust: keyfinder-core (staticlib + rlib)
  src/ring.rs         wait-free SPSC ring buffer (render thread → analysis)
  src/decimate.rs     windowed-sinc decimator to ~5.5 kHz
  src/chroma.rs       STFT, peak picking, tuning, chroma (per source mode)
  src/key.rs          learned key profiles, 24-key posterior, calibrated confidence
  src/analyzer.rs     threading model, parallel modes, Auto (modes combined)
  src/ffi.rs          C ABI  ↔  include/keyfinder.h (+ module.modulemap)
  src/bin/keyfind.rs  WAV command-line tool
plugin/               Swift: XcodeGen project (container app + AUv3 extension)
  Sources/AudioUnit   AUAudioUnit subclass, Objective-C render block, AUViewController
  Sources/Shared      AnalysisEngine, KeyDetectorView, models (app + AU)
scripts/build-core.sh universal static lib → KeyFinderCore.xcframework
scripts/bench-apple-loops.sh  real-audio benchmark (bench/: harness, scoring, model fitting)
```

## Roadmap

1. **ARA 2 front end**: analyse the selected region instantly, with no playback.
2. **Built-in source separation**: a Core ML port of an open stem-separation model (for example HTDemucs), run in the container app, for users without Logic 11 or for automatic "pick the best stem".
3. **Key-change detection**: segment-wise chroma with an HMM over keys, to report modulations with timestamps.
4. **Modes beyond major/minor** (Dorian, Mixolydian) using mode-specific profiles.
