import Foundation
import AVFoundation

public protocol XvAudioSystemDelegate: AnyObject {
    func soundDidPlay(name: String, volume: Float, pitch: Float, pan: Float)
}

public class XvAudioSystem {
    public weak var delegate: XvAudioSystemDelegate?
    
    private let debug:Bool = false

    // Singleton instance
    public static let sharedInstance = XvAudioSystem()
    private init() {}

    // Engine and channels
    private let engine = Engine.sharedInstance
    private var channels: [Channel] = []

    // Channel management
    private var channelTotal: Int = 1

    public func setup(withChannelTotal: Int) {
        channelTotal = withChannelTotal

        // Setup the engine and channels
        engine.setup(withChannelTotal: channelTotal)
        channels = engine.getChannels()
    }

    //play sound with pitch as a String
    public func playSound(name: String, volume: Float = 1.0, rampTo: Float = 0.0,  pitch: String = "C3", pan: Float = 0.0, loop: Bool = false) -> Int {
        
         var pitchCents:Float = 1.0
         if let _pitchCents:Float = Utils.pitchShiftCents(target: pitch) {
             pitchCents = _pitchCents
         }
         
        return playSound(name: name, volume: volume, rampTo: rampTo, pitch: pitchCents, pan: pan, loop: loop)
    }
    
    // Play sound
    //play sound with pitch as Float
    @discardableResult
    public func playSound(name: String, volume: Float = 1.0, rampTo: Float = 0.0, pitch: Float = 0.0, pan: Float = 0.0, loop: Bool = false) -> Int {
        guard let channel = getAvailableChannel() else {
            if debug { print("AUDIO SYS: All channels are busy.") }
            return -1
        }

        if channel.playSound(name: name, volume: volume, rampTo: rampTo, pitch: pitch, pan: pan, loop: loop) {
            delegate?.soundDidPlay(name: name, volume: volume, pitch: pitch, pan: pan)

            return channel.id
        } else {
            return -1
        }
    }
    

    // Get an available channel
    private func getAvailableChannel() -> Channel? {
        return channels.first { $0.isAvailable() }
    }

    // Set volume for a channel
    public func set(volume: Float, forChannel index: Int) {
        guard index >= 0 && index < channels.count else { return }
        channels[index].setVolume(volume)
    }

    // FX
    public func set(reverbWetDryMix: Float) {
        engine.set(reverbWetDryMix: reverbWetDryMix)
    }
    public func set(reverbMode:AVAudioUnitReverbPreset) {
        engine.set(reverbMode: reverbMode)
    }
    public func set(delayWetDryMix:Float) {
        engine.set(delayWetDryMix: delayWetDryMix)
    }
    public func setDelayBpm(bpm: Double, subdivision: Double = 1.0) {
        engine.setDelayBpm(bpm: bpm, subdivision: subdivision)
    }
    public func set(delayFeedback:Float) {
        engine.set(delayFeedback: delayFeedback)
    }
    public func setLowPassFilter(frequency: Float) {
        engine.setLowPassFilter(frequency: frequency)
    }

    // Handle interruptions
    public func beginInterruption() {
        engine.stopEngine()
    }

    public func endInterruption() {
        engine.startEngine()
    }

    // Shutdown
    public func shutdown() {
        // Fade out and stop channels
        for channel in channels {
            channel.setVolume(0.0)
            channel.stopPlayback()
        }
        engine.stopEngine()
    }
}

