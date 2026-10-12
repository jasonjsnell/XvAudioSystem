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

    /* THE IO BUFFER (Odyssey, 12 Oct 2026, additive). How much audio the render thread makes per
     cycle, in seconds. The system's default is short (a few ms); a large graph (dozens of
     channels with pitch and EQ units, reverb, delay) can then miss cycles under load, which
     CoreAudio logs as "skipping cycle due to overload" and the ear hears as pops. A longer
     buffer gives each cycle more time at the cost of that much output latency. Returns the
     duration the system actually granted. */
    @discardableResult
    func set(preferredIOBufferDuration seconds: TimeInterval) -> TimeInterval {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setPreferredIOBufferDuration(seconds)
            try session.setActive(true)
        } catch {
            print("XvAudioSystem: Session: could not set the IO buffer duration: \(error.localizedDescription)")
        }
        print("XvAudioSystem: Session: IO buffer", session.ioBufferDuration, "s (asked for", seconds, "s)")
        return session.ioBufferDuration
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

