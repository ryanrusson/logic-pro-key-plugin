import SwiftUI

/// Container app. macOS installs the AUv3 extension when this app is first
/// launched; it also analyses audio files directly (e.g. bounced stems).
@main
struct KeyFinderApp: App {
    @StateObject private var engine = AnalysisEngine(sampleRate: 44_100)!

    var body: some Scene {
        WindowGroup("KeyFinder") {
            VStack(alignment: .leading, spacing: 0) {
                Text("The KeyFinder Audio Unit is installed. In Logic Pro, insert it on a track: Audio FX › KeyFinder › Key Detector.")
                    .font(.callout)
                    .padding([.horizontal, .top], 16)
                KeyDetectorView(engine: engine, isStandalone: true)
            }
            .frame(width: 440)
        }
        .windowResizability(.contentSize)
    }
}
