import AVFoundation

class SessionManager {
    static let sharedInstance = SessionManager()
    private init() {
        setup()
    }

    private func setup() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            //try session.setPreferredSampleRate(48000)
            try session.setActive(true)

            print("XvAudioSystem: Session: Sample rate set:", session.sampleRate)
            
            // Add interruption observer
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSessionInterruption),
                name: AVAudioSession.interruptionNotification,
                object: session
            )
        } catch {
            print("Error setting up audio session: \(error.localizedDescription)")
        }
    }

    @objc private func handleSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            XvmAudioSystem.sharedInstance.beginInterruption()
        case .ended:
            XvmAudioSystem.sharedInstance.endInterruption()
        @unknown default:
            break
        }
    }
}

