import Foundation
import AVFoundation

public protocol XvAudioSystemDelegate: AnyObject {
    func soundDidPlay(name: String, volume: Float, pitch: Float, pan: Float, filterCutoff:Float)
    func fftDidUpdate(withDecibelArray:[Float])
}

public class XvmAudioSystem: EngineDelegate {
    
    public weak var delegate: XvAudioSystemDelegate?
    
    private let debug:Bool = false

    // Singleton instance
    public static let sharedInstance = XvmAudioSystem()
    private init() {}
    
    //pitch mode can be TimePitch (time stretch) or Varispeed (no time stretch)
    private var pitchMode:String = XvAudioConstants.kXvPitchModeTimePitch

    //init session
    private let sessionManager:SessionManager = SessionManager.sharedInstance
    
    // Engine and channels
    private let engine = Engine.sharedInstance
    private var channels: [Channel] = []

    // Channel management
    private var channelTotal: Int = 1

    public func setup(
        withChannelTotal: Int,
        withPitchMode:String = XvAudioConstants.kXvPitchModeTimePitch,
        enableFFT:Bool = false
    ) -> AudioUnit? {
        
        channelTotal = withChannelTotal
        pitchMode = withPitchMode

        // Setup the engine and channels
        if let remoteIOUnitForAudioBus:AudioUnit = engine.setup(withChannelTotal: channelTotal, withPitchMode: pitchMode, enableFFT: enableFFT) {
            
            if (enableFFT){
                engine.delegate = self
            }
            channels = engine.getChannels()
            
            return remoteIOUnitForAudioBus
            
        } else {
            print("XvAudioSystem: Error: Unable to get remoteIOUnitForAudioBus")
            return nil
        }
    }
    
    public func isChannelAvailable() -> Bool {
        return channels.first { $0.isAvailable() } != nil
    }

    //play sound with pitch as a String
    public func playSound(
        name: String,
        volume: Float = 1.0,
        pitch: String = "C3",
        pan: Float = 0.0,
        loop: Bool = false,
        filterCutoff: Float = 20000
    ) -> Int {
        
        var convertedPitch:Float = 0.0
        
        if (pitchMode == XvAudioConstants.kXvPitchModeTimePitch){
            
            //time stretch uses pitch cents
            convertedPitch = 0.0 //pitch cents default, C3
            if let _pitchCents:Float = Utils.pitchShiftCents(target: pitch) {
                convertedPitch = _pitchCents
            }
            
        } else if (pitchMode == XvAudioConstants.kXvPitchModeVarispeed) {
            
            //varispeed uses rate
            convertedPitch = 1.0 //rate default, C3
            if let _rate:Float = Utils.varispeedRate(target: pitch) {
                convertedPitch = _rate
            }
        }
        
        return playSound(name: name, volume: volume, pitch: convertedPitch, pan: pan, loop: loop, filterCutoff: filterCutoff)
    }
    
    // Play sound
    //play sound with pitch as Float
    @discardableResult
    
    public func playSound(
        name: String,
        volume: Float = 1.0,
        pitch: Float = 0.0,
        pan: Float = 0.0,
        loop: Bool = false,
        filterCutoff: Float = 20000
    ) -> Int {
        
        guard let channel = getAvailableChannel() else {
            if debug { print("AUDIO SYS: All channels are busy.") }
            return -1
        }
        
        //make sure engine is running before calling the channel to play
        if !engine.isRunning() {
            engine.startEngine()
        }

        if channel.playSound(name: name, volume: volume, pitch: pitch, pan: pan, loop: loop, filterCutoff: filterCutoff) {
            delegate?.soundDidPlay(name: name, volume: volume, pitch: pitch, pan: pan, filterCutoff: filterCutoff)
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

    //callback from Engine FFT
    public func fftDidUpdate(withDecibelArray: [Float]) {
        delegate?.fftDidUpdate(withDecibelArray: withDecibelArray)
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
    
    //status debug
    public func getPercentageOfBusyChannels() -> Int {
        let total = channels.count
        guard total > 0 else { return 0 }
        let busy = channels.filter { !$0.isAvailable() }.count
        let percentage = (Double(busy) / Double(total)) * 100.0
        return Int(percentage.rounded())
    }
    
    public func outputStatus(){
        let engineState = engine.isRunning() ? "running" : "stopped"
        let total = channels.count
        let free = channels.filter { $0.isAvailable() }
        let active = channels.filter { !$0.isAvailable() }

        let activeIDs = active.map { String($0.id) }.joined(separator: ", ")
        let freeIDs = free.map { String($0.id) }.joined(separator: ", ")

        print("[AUDIO SYS] engine=\(engineState) | pitchMode=\(pitchMode) | channels total=\(total) | active=\(active.count) | free=\(free.count)")
        print("[AUDIO SYS] active IDs: \(activeIDs.isEmpty ? "none" : activeIDs)")
        print("[AUDIO SYS] free IDs: \(freeIDs.isEmpty ? "none" : freeIDs)")
    }
}

