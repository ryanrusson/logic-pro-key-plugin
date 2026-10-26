import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyDetectorView: View {
    @ObservedObject var engine: AnalysisEngine
    /// True in the container app, where there is no live input.
    var isStandalone = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceBanner
            keyPanel
            Picker("Analyse as", selection: $engine.mode) {
                ForEach(SourceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            ChromaView(chroma: engine.result?.chroma ?? [], key: engine.result?.key)
                .frame(height: 96)
            alternatives
            Spacer(minLength: 0)
            hint
            controls
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 500)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 3 : 0)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    // MARK: Sections

    @ViewBuilder private var sourceBanner: some View {
        switch engine.source {
        case .live:
            Label(isStandalone ? "Drop an audio file to analyse it" : "Listening to this track",
                  systemImage: isStandalone ? "doc" : "waveform")
                .font(.caption).foregroundStyle(.secondary)
        case .file(let name):
            Label("File: \(name)", systemImage: "doc").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var keyPanel: some View {
        if engine.isAnalyzingFile {
            ProgressView("Analysing file…").frame(maxWidth: .infinity, minHeight: 120)
        } else if let r = engine.result, let key = r.key {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(key.name).font(.system(size: 40, weight: .bold, design: .rounded))
                    Text(key.camelot).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("Relative \(key.relative.isMinor ? "minor" : "major"): \(key.relative.name)")
                    .font(.callout).foregroundStyle(.secondary)
                ConfidenceBar(value: r.confidence)
                HStack {
                    Text(String(format: "Tuning %+.0f¢ (A = %.1f Hz)", r.tuningCents, r.referenceA))
                    Spacer()
                    Text(statusText(r))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("—").font(.system(size: 40, weight: .bold, design: .rounded))
                Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
            }
            .frame(minHeight: 120, alignment: .topLeading)
        }
    }

    @ViewBuilder private var alternatives: some View {
        if let alts = engine.result?.alternatives, !alts.isEmpty {
            HStack(spacing: 10) {
                Text("Also likely:").foregroundStyle(.secondary)
                ForEach(alts, id: \.self) { c in
                    Text("\(c.key.name) \(String(format: "%.2f", c.score))").monospacedDigit()
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder private var hint: some View {
        if let error = engine.fileError {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let r = engine.result, r.key != nil, r.confidence < 0.35, r.mode == .fullMix {
            Text("Mixed track? Logic can't be driven by plug-ins, so run Stem Splitter yourself: Control-click the region › Stem Splitter, then insert KeyFinder on the Bass (or Guitar/Other) stem.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack {
            if !isStandalone {
                Toggle("Listen", isOn: $engine.isListening).toggleStyle(.switch)
            }
            Button("Reset") { engine.reset() }
            if case .file = engine.source, !isStandalone {
                Button("Back to Live") { engine.showLive() }
            }
            Spacer()
            if isStandalone {
                Button("Open Audio File…", action: openFile)
            }
        }
    }

    // MARK: Helpers

    private var emptyMessage: String {
        if case .file = engine.source { return "No key found. The file has too little pitched audio." }
        return isStandalone ? "No file analysed yet." : "Play the track. A key appears after a few seconds of pitched audio."
    }

    private func statusText(_ r: KeyResult) -> String {
        if r.isSaved { return "Saved with project" }
        let via = engine.mode == .auto ? " · \(r.mode.label)" : ""
        return String(format: "%.0f s analysed", r.secondsAnalyzed) + via
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { engine.analyzeFile(at: url) }
        }
        return true
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { engine.analyzeFile(at: url) }
    }
}

private struct ConfidenceBar: View {
    let value: Float

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
                }
            }
            .frame(height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
        }
    }

    private var label: String { "\(value >= 0.6 ? "High" : value >= 0.3 ? "Medium" : "Low") confidence" }
    private var color: Color { value >= 0.6 ? .green : value >= 0.3 ? .yellow : .orange }
}

/// 12 pitch-class bars, with notes of the detected key's scale highlighted.
private struct ChromaView: View {
    let chroma: [Float]
    let key: MusicalKey?

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<12, id: \.self) { pc in
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(fill(pc))
                                .frame(height: geo.size.height * CGFloat(pc < chroma.count ? chroma[pc] : 0))
                        }
                    }
                    Text(MusicalKey.noteNames[pc])
                        .font(.system(size: 9, weight: pc == key?.tonic ? .bold : .regular))
                }
            }
        }
    }

    private func fill(_ pc: Int) -> Color {
        guard let key else { return .secondary.opacity(0.5) }
        if pc == key.tonic { return .accentColor }
        return key.scale.contains(pc) ? .accentColor.opacity(0.55) : .secondary.opacity(0.35)
    }
}
