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
   SPSC ring buffer (no locks/allocs)       KeyDetectorAudioUnit  render block,
   stereo → mono → FIR decimate ~5.5 kHz                          state save/restore
   8192-pt STFT (one FFT, shared)           AnalysisEngine        100 ms drain timer
   ├─ Bass    E1–G4  peak picking ─┐        KeyDetectorView       key, confidence,
   ├─ Guitar  E2–E6  peak picking ─┼─ 10¢                         chroma, mode picker
   └─ FullMix C2–C7  strict peaks ─┘  pitch histogram
   tuning estimate → 12-bin chroma
   Krumhansl-Kessler + Temperley correlation → 24 keys, confidence
```

## Why Swift + Rust (and not Go)

| Layer | Language | Reason |
|---|---|---|
| AUv3 extension, UI, Logic state | **Swift** | AUv3 is an Objective-C/Swift API, and SwiftUI is native. |
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

**Without Xcode.** With only the Command Line Tools (`xcode-select --install`), `make build-clt` builds the same universal, ad-hoc signed app with `swiftc` into `plugin/build/clt/KeyFinder.app`. It needs no XcodeGen. It generates the Info.plists and entitlements from `plugin/project.yml`, so keep that file the single source of truth.

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

To validate on real material, run `keyfind` over a folder of stems whose keys you already know.

## Layout

```
core/                 Rust: keyfinder-core (staticlib + rlib)
  src/ring.rs         wait-free SPSC ring buffer (render thread → analysis)
  src/decimate.rs     windowed-sinc decimator to ~5.5 kHz
  src/chroma.rs       STFT, peak picking, tuning, chroma (per source mode)
  src/key.rs          key profiles, 24-key ranking, confidence
  src/analyzer.rs     threading model, parallel modes, Auto selection
  src/ffi.rs          C ABI  ↔  include/keyfinder.h (+ module.modulemap)
  src/bin/keyfind.rs  WAV command-line tool
plugin/               Swift: XcodeGen project (container app + AUv3 extension)
  Sources/AudioUnit   AUAudioUnit subclass, AUViewController
  Sources/Shared      AnalysisEngine, KeyDetectorView, models (app + AU)
scripts/build-core.sh universal static lib → KeyFinderCore.xcframework
```

## Roadmap

1. **ARA 2 front end**: analyse the selected region instantly, with no playback.
2. **Built-in source separation**: a Core ML port of an open stem-separation model (for example HTDemucs), run in the container app, for users without Logic 11 or for automatic "pick the best stem".
3. **Key-change detection**: segment-wise chroma with an HMM over keys, to report modulations with timestamps.
4. **Modes beyond major/minor** (Dorian, Mixolydian) using mode-specific profiles.
