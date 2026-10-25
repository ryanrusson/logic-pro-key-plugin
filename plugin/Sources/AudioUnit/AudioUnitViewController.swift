import CoreAudioKit
import SwiftUI

/// Principal class of the AUv3 extension: creates the Audio Unit and hosts
/// its SwiftUI interface inside Logic's plugin window.
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: KeyDetectorAudioUnit?
    private var hosting: NSHostingController<KeyDetectorView>?

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 540))
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 420, height: 540)
        embedInterfaceIfReady()
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try KeyDetectorAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = au
        DispatchQueue.main.async { [weak self] in
            if self?.isViewLoaded == true { self?.embedInterfaceIfReady() }
        }
        return au
    }

    private func embedInterfaceIfReady() {
        guard hosting == nil, let au = audioUnit else { return }
        let controller = NSHostingController(rootView: KeyDetectorView(engine: au.engine))
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        view.addSubview(controller.view)
        hosting = controller
    }
}
