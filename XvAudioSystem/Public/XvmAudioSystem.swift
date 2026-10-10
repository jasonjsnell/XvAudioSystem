import Foundation
import AudioToolbox
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

    //unchanged: the graph as it has always been, every channel through the effects
    public func setup(
        withChannelTotal: Int,
        withPitchMode:String = XvAudioConstants.kXvPitchModeTimePitch,
        enableFFT:Bool = false
    ) -> AudioUnit? {
        return setup(withChannelTotal: withChannelTotal, withPitchMode: withPitchMode, enableFFT: enableFFT, enableDryBus: false)
    }

    /* SEND AND RETURN (29 Sep 2026, opt-in). With enableDryBus, every channel feeds both
     the effects (low-pass, delay, reverb) and a dry bus that skips them, at levels set per
     sound (the wet/dry playSound, or set(wet:dry:forChannel:)). Sounds played with the
     ordinary playSound are fully wet and not dry, which sounds exactly as without it.
     Existing projects that call the setup above are unaffected. */
    public func setup(
        withChannelTotal: Int,
        withPitchMode:String = XvAudioConstants.kXvPitchModeTimePitch,
        enableFFT:Bool = false,
        enableDryBus:Bool
    ) -> AudioUnit? {
        return setup(withChannelTotal: withChannelTotal, withPitchMode: withPitchMode, enableFFT: enableFFT,
                     enableDryBus: enableDryBus, enableDelayBus: false)
    }

    /* DELAY SEND (7 Oct 2026, opt-in, additive). With enableDelayBus the delay is its own
     send and return beside the reverb: each sound sets how much of itself goes to it (the
     delay: of playSound, playBuffer or set(wet:dry:delay:forChannel:)), the delay runs
     echo-only, and its echoes go straight to the output, clean of the reverb. The plain
     wet path no longer passes through the delay. Sounds that send nothing to it are unchanged.
     Tempo: setDelayBpm; echoes: set(delayFeedback:); tone: set(delayLowPassHz:). */
    public func setup(
        withChannelTotal: Int,
        withPitchMode:String = XvAudioConstants.kXvPitchModeTimePitch,
        enableFFT:Bool = false,
        enableDryBus:Bool,
        enableDelayBus:Bool
    ) -> AudioUnit? {
        
        channelTotal = withChannelTotal
        pitchMode = withPitchMode

        // Setup the engine and channels
        if let remoteIOUnitForAudioBus:AudioUnit = engine.setup(withChannelTotal: channelTotal, withPitchMode: pitchMode, enableFFT: enableFFT, enableDryBus: enableDryBus, enableDelayBus: enableDelayBus) {
            
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
        //fully through the effects, as always
        return playSound(name: name, volume: volume, pitch: pitch, pan: pan, loop: loop, filterCutoff: filterCutoff, wet: 1.0, dry: 0.0)
    }

    /* The same, choosing how much goes through the effects (wet) and around them (dry),
     each 0 to 1. Needs the dry bus (setup with enableDryBus: true); without it the sound
     goes through the effects whatever wet and dry say. */
    @discardableResult
    public func playSound(
        name: String,
        volume: Float = 1.0,
        pitch: Float = 0.0,
        pan: Float = 0.0,
        loop: Bool = false,
        filterCutoff: Float = 20000,
        wet: Float,
        dry: Float,
        delay: Float = 0,
        highPassCutoff: Float = 20
    ) -> Int {

        guard let channel = getAvailableChannel() else {
            if debug { print("AUDIO SYS: All channels are busy.") }
            return -1
        }

        //make sure engine is running before calling the channel to play
        if !engine.isRunning() {
            engine.startEngine()
        }

        //channels are reused, so every sound sets its sends and its high-pass (9 Oct 2026, additive: 20 is none)
        if engine.hasDryBus || engine.hasDelayBus { channel.setSends(wet: wet, dry: dry, delay: delay) }
        channel.setHighPassFilter(frequency: highPassCutoff)

        if channel.playSound(name: name, volume: volume, pitch: pitch, pan: pan, loop: loop, filterCutoff: filterCutoff) {
            delegate?.soundDidPlay(name: name, volume: volume, pitch: pitch, pan: pan, filterCutoff: filterCutoff)
            return channel.id
        } else {
            return -1
        }
    }
    

    /* Plays audio the caller prepared in memory, instead of a named file (30 Sep 2026,
     additive). Returns the channel, or -1. Same settings as playSound; wet and dry need the
     dry bus. The buffer should be in the format a file of that kind loads in
     (AVAudioFile.processingFormat). */
    @discardableResult
    public func playBuffer(
        _ buffer: AVAudioPCMBuffer,
        volume: Float = 1.0,
        pitch: Float = 0.0,
        pan: Float = 0.0,
        loop: Bool = false,
        filterCutoff: Float = 20000,
        wet: Float = 1.0,
        dry: Float = 0.0,
        delay: Float = 0,
        highPassCutoff: Float = 20
    ) -> Int {
        guard let channel = getAvailableChannel() else { return -1 }
        if !engine.isRunning() { engine.startEngine() }
        if engine.hasDryBus || engine.hasDelayBus { channel.setSends(wet: wet, dry: dry, delay: delay) }
        channel.setHighPassFilter(frequency: highPassCutoff) //channels are reused (9 Oct 2026, additive)
        return channel.playBuffer(buffer, volume: volume, pitch: pitch, pan: pan, loop: loop, filterCutoff: filterCutoff)
            ? channel.id : -1
    }

    // Get an available channel
    private func getAvailableChannel() -> Channel? {
        return channels.first { $0.isAvailable() }
    }

    /* Frees one channel, by the id playSound returned (added 29 Sep 2026, additive: no
     existing call changes). Meant for a channel that has already been faded to silence
     with set(volume:forChannel:), such as a loop that has faded out, so the channel can be
     reused. Calling it on a sounding channel cuts it off. */
    public func stop(channel index: Int) {
        guard index >= 0 && index < channels.count else { return }
        channels[index].stopPlayback()
    }

    ///A sounding channel's sends, each 0 to 1 (dry bus only; delay needs the delay bus).
    public func set(wet: Float, dry: Float, delay: Float = 0, forChannel index: Int) {
        guard engine.hasDryBus || engine.hasDelayBus, index >= 0 && index < channels.count else { return }
        channels[index].setSends(wet: wet, dry: dry, delay: delay)
    }

    /* A sounding channel's own low-pass filter, in Hz (20000 is open). Every channel has
     one; playSound sets it as a sound starts, and this moves it while the sound plays, e.g.
     to darken a long drone. Added 30 Sep 2026, additive. */
    public func set(filterCutoff: Float, forChannel index: Int) {
        guard index >= 0 && index < channels.count else { return }
        channels[index].setLowPassFilter(frequency: filterCutoff)
    }

    /* A sounding channel's pitch (added 30 Sep 2026, additive). In varispeed mode this is
     the playback rate (1 as recorded, 2 an octave up, 0.5 an octave down); in time-pitch
     mode it is cents. Changing it while the sound is audible is heard as a jump, so set it
     while the channel is silent. */
    public func set(pitch: Float, forChannel index: Int) {
        guard index >= 0 && index < channels.count else { return }
        channels[index].setPitch(pitch)
    }

    /* A sounding channel's own high-pass filter, in Hz (7 Oct 2026, additive). Every
     channel has one, bypassed until this is called; 20 or under bypasses it again. */
    public func set(highPassCutoff: Float, forChannel index: Int) {
        guard index >= 0 && index < channels.count else { return }
        channels[index].setHighPassFilter(frequency: highPassCutoff)
    }

    ///A sounding channel's pan, -1 (left) to 1 (right). Added 30 Sep 2026, additive.
    public func set(pan: Float, forChannel index: Int) {
        guard index >= 0 && index < channels.count else { return }
        channels[index].setPan(Swift.min(Swift.max(pan, -1), 1))
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
    /* THE REVERB'S FINER CONTROLS (30 Sep 2026, additive). A preset (set(reverbMode:)) sets
     all of these, so call them after choosing the preset. */

    ///How long low frequencies ring, in seconds (0.001 to 20).
    public func set(reverbDecayLowSeconds: Float) {
        engine.setReverbParameter(kReverb2Param_DecayTimeAt0Hz, value: min(max(reverbDecayLowSeconds, 0.001), 20))
    }
    ///How long high frequencies ring, in seconds (0.001 to 20). Shorter than the low decay sounds darker.
    public func set(reverbDecayHighSeconds: Float) {
        engine.setReverbParameter(kReverb2Param_DecayTimeAtNyquist, value: min(max(reverbDecayHighSeconds, 0.001), 20))
    }
    ///The shortest and longest early reflection delays, in seconds (0.0001 to 1): the size of the space.
    public func set(reverbMinDelaySeconds: Float, maxDelaySeconds: Float) {
        engine.setReverbParameter(kReverb2Param_MinDelayTime, value: min(max(reverbMinDelaySeconds, 0.0001), 1))
        engine.setReverbParameter(kReverb2Param_MaxDelayTime, value: min(max(maxDelaySeconds, 0.0001), 1))
    }
    ///The reverb's output level, in dB (-20 to 20).
    public func set(reverbGainDb: Float) {
        engine.setReverbParameter(kReverb2Param_Gain, value: min(max(reverbGainDb, -20), 20))
    }
    ///Which pattern of reflections the reverb uses (1 to 1000). A setting, not chance at
    ///play time: the same value always gives the same reverb.
    public func set(reverbReflectionPattern: Int) {
        engine.setReverbParameter(kReverb2Param_RandomizeReflections, value: Float(min(max(reverbReflectionPattern, 1), 1000)))
    }
    /* A 24 dB/octave high-pass on the reverb's return, in Hz, to keep its low end from
     muddying the mix. Needs the dry bus (setup with enableDryBus: true); nil or 0 turns
     it off, which is how it starts. */
    public func set(reverbHighPassFrequency: Float?) {
        engine.setReverbHighPass(frequency: reverbHighPassFrequency)
    }

    /* MASTER (8 Oct 2026, additive). A gain on everything the app plays, in dB (0 to
     start), and a peak limiter after it (off to start) that stops a loud moment from
     clipping. Use the gain to set the app's overall level; turn the limiter on with it. */
    public func set(masterGainDb: Float) {
        engine.set(masterGainDb: masterGainDb)
    }
    public func set(limiterEnabled: Bool) {
        engine.set(limiterEnabled: limiterEnabled)
    }
    /* A meter on the output (8 Oct 2026, additive, for tuning): called every so many
     seconds, on the audio thread, with that stretch's loudest peak and average level in
     dB full scale. nil turns it off. */
    public func set(outputMeter: ((_ peakDb: Float, _ rmsDb: Float) -> Void)?, everySeconds seconds: Double = 1) {
        engine.set(outputMeter: outputMeter, everySeconds: seconds)
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
    /* How much of the delay's echoes also go into the reverb, 0 to 1 (delay bus only). The
     echoes always reach the output clean; this adds a reverberated copy of them on top. */
    public func set(delayReverbSend:Float) {
        engine.set(delayReverbSend: delayReverbSend)
    }
    ///The delay's low-pass on its echoes, in Hz (10 to 22050). Each echo comes back darker.
    public func set(delayLowPassHz:Float) {
        engine.set(delayLowPassHz: delayLowPassHz)
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

