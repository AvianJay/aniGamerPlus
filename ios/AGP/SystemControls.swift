import AVFoundation
import MediaPlayer
import UIKit

/// Screen brightness and output volume, as the system owns them.
///
/// These are the two levels a web page cannot reach, and the only reason this
/// native shell exists. `UIScreen.brightness` has no web equivalent at all, and
/// mobile Safari ignores writes to `HTMLMediaElement.volume` because the
/// hardware buttons own the output — which is why the browser build dims the
/// picture with an overlay and tells the viewer to use the side buttons.
final class SystemControls: NSObject {

    /// Fires when something other than us moves a level: the hardware buttons,
    /// Control Centre, auto-brightness.
    var onChange: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var volumeObservation: NSKeyValueObservation?

    /// Off-screen, but in the view hierarchy: the slider inside `MPVolumeView`
    /// is not created until the view has a window, and that slider is still the
    /// only thing that moves the system output level. Having it present also
    /// suppresses the system volume HUD, so the player's own HUD is the only
    /// one the viewer sees.
    private let volumeHost = MPVolumeView(frame: CGRect(x: -4096, y: 0, width: 256, height: 24))

    /// The screen level from before the app touched it. A phone left dimmed
    /// after the viewer has gone reads as a fault, so it goes back on the way
    /// out and is taken again on the way in.
    private var borrowedBrightness: CGFloat?
    private var appliedBrightness: CGFloat?

    /// What we last wrote, so the change notifications our own writes provoke
    /// are not sent back to the page in the middle of a drag.
    private var lastWrittenBrightness: CGFloat?
    private var lastWrittenVolume: Float?

    // MARK: - Levels

    var brightness: Double {
        get { Double(UIScreen.main.brightness) }
        set {
            let level = CGFloat(min(1, max(0, newValue)))
            if borrowedBrightness == nil { borrowedBrightness = UIScreen.main.brightness }
            appliedBrightness = level
            lastWrittenBrightness = level
            UIScreen.main.brightness = level
        }
    }

    var volume: Double {
        get { Double(session.outputVolume) }
        set {
            let level = Float(min(1, max(0, newValue)))
            lastWrittenVolume = level
            // The slider ignores a value assigned in the same run-loop turn it
            // was asked for.
            DispatchQueue.main.async { [weak self] in
                self?.systemSlider?.value = level
            }
        }
    }

    private var systemSlider: UISlider? {
        volumeHost.subviews.compactMap { $0 as? UISlider }.first
    }

    // MARK: - Lifecycle

    func attach(to view: UIView) {
        volumeHost.showsRouteButton = false
        view.addSubview(volumeHost)

        // .playback so the ring/silent switch does not mute the episode, and so
        // outputVolume reports the level the viewer is actually hearing.
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            guard let self = self else { return }
            if let written = self.lastWrittenVolume,
               abs(session.outputVolume - written) < 0.01 { return }
            DispatchQueue.main.async { self.onChange?() }
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screenBrightnessChanged),
                           name: UIScreen.brightnessDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(willResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(didBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenBrightnessChanged() {
        if let written = lastWrittenBrightness,
           abs(UIScreen.main.brightness - written) < 0.01 { return }
        // Somebody else moved it, so whatever we were holding is no longer ours
        // to hand back.
        borrowedBrightness = nil
        appliedBrightness = nil
        onChange?()
    }

    @objc private func willResignActive() {
        guard let original = borrowedBrightness else { return }
        lastWrittenBrightness = original
        UIScreen.main.brightness = original
        // Taken again on the next write: the viewer may well have changed it
        // themselves while the app was away.
        borrowedBrightness = nil
    }

    @objc private func didBecomeActive() {
        guard let level = appliedBrightness else { return }
        brightness = Double(level)
    }
}
