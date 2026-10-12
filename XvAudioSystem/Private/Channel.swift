import AVFoundation

class Channel {
    
    let id: Int
    
    // Nodes
    private let playerNode:AVAudioPlayerNode = AVAudioPlayerNode()
    private let timePitchNode:AVAudioUnitTimePitch = AVAudioUnitTimePitch()
    private let varispeedPitchNode:AVAudioUnitVarispeed = AVAudioUnitVarispeed()
    //band 0: the low-pass every channel has had; band 1: a high-pass, bypassed until asked for (7 Oct 2026, additive)
    private let eqNode: AVAudioUnitEQ = AVAudioUnitEQ(numberOfBands: 2)
        
    private let mixerNode: AVAudioMixerNode
    
    private var pitchMode:String = XvAudioConstants.kXvPitchModeTimePitch

    // channel states
    private var looping: Bool = false

    /* THREADS (29 Sep 2026). A channel is asked to play on the caller's thread, starts on
     the schedule queue, and is marked finished on the audio thread. The state those three
     share (busy, the buffer, which sound is current) is behind stateLock. playID counts the
     sounds on this channel, so a late completion or a delayed start from an earlier sound
     can never mark the current one finished, or start it twice. */
    private let stateLock = NSLock()
    private var isPlaying: Bool = false
    private var playID: Int = 0

    /* Where a sound actually starts, a moment after it is asked for (so volume, pan, pitch
     and filter are in place first). Its own serial queue, shared by all channels: it was
     the main thread, where a busy screen could make sounds start late. */
    private static let scheduleQueue = DispatchQueue(label: "XvAudioSystem.Channel.schedule", qos: .userInteractive)

    // Initialization
    init(id: Int, pitchMode:String = XvAudioConstants.kXvPitchModeTimePitch) {
        
        self.id = id
        self.pitchMode = pitchMode
        
        // Initialize the mix node for this channel
        mixerNode = AVAudioMixerNode()
        mixerNode.outputVolume = 1.0
        
        // Configure Low-Pass Filter (EQ)
        if let filterParams = eqNode.bands.first {
            filterParams.filterType = .lowPass
            filterParams.frequency = 20000  // Default to max freq (no filter effect)
            filterParams.bandwidth = 0.5    // Bandwidth in octaves
            filterParams.bypass = false
        }
        // The high-pass: bypassed, so a channel sounds exactly as before until it is set
        if eqNode.bands.count > 1 {
            let highPass = eqNode.bands[1]
            highPass.filterType = .highPass
            highPass.frequency = 20
            highPass.bandwidth = 0.5
            highPass.bypass = true
        }
    }

    // Attach nodes to the engine
    func attachNodes(to engine: AVAudioEngine) {
        
        //signal path: player -> EQ filter -> pitch shifter -> mixer
        engine.attach(playerNode)
        engine.attach(eqNode)
        
        //what type of pitch? time stretch or no time stretch?
        if (pitchMode == XvAudioConstants.kXvPitchModeTimePitch){
            engine.attach(timePitchNode)
        } else if (pitchMode == XvAudioConstants.kXvPitchModeVarispeed) {
            engine.attach(varispeedPitchNode)
        }
        
        engine.attach(mixerNode)
    }

    //the two destinations when the engine has a dry bus (nil without one)
    private var wetDestination: (mixer: AVAudioMixerNode, bus: AVAudioNodeBus)?
    private var dryDestination: (mixer: AVAudioMixerNode, bus: AVAudioNodeBus)?
    //and the delay send when the engine has a delay bus (nil without one)
    private var delayDestination: (mixer: AVAudioMixerNode, bus: AVAudioNodeBus)?

    // Connect nodes
    func connectNodes(to mainMixer: AVAudioMixerNode, dryMixer: AVAudioMixerNode? = nil, delayMixer: AVAudioMixerNode? = nil) {
        if let engine = playerNode.engine {
            // Connect nodes in the order: player -> pitch -> EQ -> mixer
            if (pitchMode == XvAudioConstants.kXvPitchModeTimePitch){
                engine.connect(playerNode, to: timePitchNode, format: nil)
                engine.connect(timePitchNode, to: eqNode, format: nil)   // Connect EQ
            } else if (pitchMode == XvAudioConstants.kXvPitchModeVarispeed) {
                engine.connect(playerNode, to: varispeedPitchNode, format: nil)
                engine.connect(varispeedPitchNode, to: eqNode, format: nil)  // Connect EQ
            }
            
            engine.connect(eqNode, to: mixerNode, format: nil) // Connect EQ to Mixer

            if dryMixer != nil || delayMixer != nil {
                //one output to every bus; each connection has its own level (setSends)
                let wetBus = mainMixer.nextAvailableInputBus
                var points = [AVAudioConnectionPoint(node: mainMixer, bus: wetBus)]
                wetDestination = (mainMixer, wetBus)
                if let dryMixer {
                    let dryBus = dryMixer.nextAvailableInputBus
                    points.append(AVAudioConnectionPoint(node: dryMixer, bus: dryBus))
                    dryDestination = (dryMixer, dryBus)
                }
                if let delayMixer {
                    let delayBus = delayMixer.nextAvailableInputBus
                    points.append(AVAudioConnectionPoint(node: delayMixer, bus: delayBus))
                    delayDestination = (delayMixer, delayBus)
                }
                engine.connect(mixerNode, to: points, fromBus: 0, format: nil)
                setSends(wet: 1.0, dry: 0.0, delay: 0.0) //the default: exactly as without the buses
            } else {
                engine.connect(mixerNode, to: mainMixer, format: nil)
            }
        }
    }

    /* How much of this channel goes through the effects (wet) and around them (dry), each
     0 to 1. Only with a dry bus; without one the channel always goes through the effects. */
    func setSends(wet: Float, dry: Float, delay: Float = 0) {
        if let wetDestination {
            mixerNode.destination(forMixer: wetDestination.mixer, bus: wetDestination.bus)?.volume = max(0, min(1, wet))
        }
        if let dryDestination {
            mixerNode.destination(forMixer: dryDestination.mixer, bus: dryDestination.bus)?.volume = max(0, min(1, dry))
        }
        if let delayDestination {
            mixerNode.destination(forMixer: delayDestination.mixer, bus: delayDestination.bus)?.volume = max(0, min(1, delay))
        }
    }

    // Play sound
    private var currentBuffer: AVAudioPCMBuffer?
      
    func playSound(
        name: String,
        volume: Float = 1.0,
        pitch: Float = 0.0,
        pan: Float = 0.0,
        loop: Bool = false,
        filterCutoff: Float = 20000
    ) -> Bool {
        
        //print("XvAudioSystem: Channel: playSound: name", name, "volume", volume, "pitch", pitch, "pan", pan, "loop", loop)
        
        // Stop previous playback (only if something is still sounding, 12 Oct 2026)
        stopIfSounding()

        // Load the audio file if not already loaded or if a different file is requested
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            print("Channel: Could not find audio file \(name).wav")
            return false
        }

        //Init new audioFile
        var audioFile: AVAudioFile?
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            print("Channel: Error loading audio file: \(name) \(error.localizedDescription)")
            return false
        }
        

        guard let audioFile = audioFile else {
            print("Channel: Audio file \(name) is not available.")
            return false
        }
        
        // Reset file read position
        audioFile.framePosition = 0

        // Create a buffer from the audio file
        let processingFormat = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            print("Channel: Could not create PCM buffer for \(name).")
            return false
        }

        do {
            try audioFile.read(into: buffer)
            //print("Channel: Success reading audio file \(name) into buffer:")
        } catch {
            print("Channel: Error reading audio file \(name) into buffer: \(error.localizedDescription)")
            return false
        }
        
        return start(buffer: buffer, volume: volume, pitch: pitch, pan: pan, loop: loop, filterCutoff: filterCutoff)
    }

    /* Plays audio the caller prepared, instead of a named file (30 Sep 2026, additive). For
     sounds built in memory, such as a loop with a crossfade baked into its seam. The buffer
     should be in the same format a file of that kind loads in (AVAudioFile.processingFormat). */
    /* at (Odyssey, 12 Oct 2026, additive): a host time to start at, so sounds asked for at
     different moments can start at exactly the same sample. Nil keeps the old behaviour: the
     start 0.1 s after the request. A time already past starts the sound at once. */
    func playBuffer(
        _ buffer: AVAudioPCMBuffer,
        volume: Float = 1.0,
        pitch: Float = 0.0,
        pan: Float = 0.0,
        loop: Bool = false,
        filterCutoff: Float = 20000,
        at startTime: AVAudioTime? = nil
    ) -> Bool {
        stopIfSounding()
        return start(buffer: buffer, volume: volume, pitch: pitch, pan: pan, loop: loop, filterCutoff: filterCutoff, at: startTime)
    }

    /* ONLY A SOUNDING CHANNEL IS STOPPED (Odyssey, 12 Oct 2026, additive). Every play used to
     stop and reset the player first, even on a channel that had already finished (the usual
     case: the system hands out free channels). AVAudioPlayerNode.stop waits on the engine's
     render lock, and Xcode flagged it as a priority inversion on every note (a user-interactive
     thread waiting on a default one). A finished channel is now left running and its next
     sound is simply scheduled; only a channel cut off mid-sound is stopped, as before. */
    private func stopIfSounding() {
        stateLock.lock()
        let sounding = isPlaying
        if !sounding {
            playID += 1 //any late completion or delayed start of the old sound no longer counts
            currentBuffer = nil
        }
        stateLock.unlock()
        if sounding { stopPlayback() }
    }

    //the shared second half of playSound and playBuffer: settings, then the scheduled start
    private func start(
        buffer: AVAudioPCMBuffer,
        volume: Float,
        pitch: Float,
        pan: Float,
        loop: Bool,
        filterCutoff: Float,
        at startTime: AVAudioTime? = nil
    ) -> Bool {

        // Retain buffer, and make this the current sound
        stateLock.lock()
        playID += 1
        let thisPlay = playID
        currentBuffer = buffer
        isPlaying = true
        stateLock.unlock()
        
        //mixer settings
        mixerNode.outputVolume = volume
        mixerNode.pan = pan
        
        // Pitch
        if (pitchMode == XvAudioConstants.kXvPitchModeTimePitch){
            
            timePitchNode.pitch = pitch
            
        } else if (pitchMode == XvAudioConstants.kXvPitchModeVarispeed) {
            
            varispeedPitchNode.rate = pitch
        }
        
        //Filter
        setLowPassFilter(frequency: filterCutoff)

        /* A GIVEN START TIME (Odyssey, 12 Oct 2026, additive): the buffer is scheduled now and
         the player told to start at that host time, so the settings above have until then to
         apply and the sound begins on the sample asked for, however late this call ran. */
        if let startTime {
            Channel.scheduleQueue.async { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock()
                let buffer = self.playID == thisPlay ? self.currentBuffer : nil
                self.stateLock.unlock()
                guard let buffer else { return }
                let options: AVAudioPlayerNodeBufferOptions = loop ? [.loops] : []
                /* .dataPlayedBack (12 Oct 2026): the channel is freed only once the sound has fully
                 left the output, not when the player has merely read the buffer, so the next sound
                 given this channel never stops, re-filters or re-routes a tail still in flight. */
                /* The start time goes on the buffer, not on play (12 Oct 2026, stopIfSounding): a
                 finished player is left running, and play(at:) does nothing on a running player,
                 so the buffer itself is scheduled for the host time. A player not yet running is
                 started, and plays silence until the buffer's time. A time already past starts at once. */
                self.playerNode.scheduleBuffer(buffer, at: startTime, options: options, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.playbackComplete(playID: thisPlay)
                }
                if !self.playerNode.isPlaying { self.playerNode.play() }
            }
            return true
        }

        // Schedule playback with looping option
        //slight delay to give channel time to apply incoming pan, volume, filter, etc
        Channel.scheduleQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }

            //still the current sound? (it may have been stopped or replaced meanwhile)
            self.stateLock.lock()
            let buffer = self.playID == thisPlay ? self.currentBuffer : nil
            self.stateLock.unlock()
            guard let buffer else { return }

            let options: AVAudioPlayerNodeBufferOptions = loop ? [.loops] : []
            self.playerNode.scheduleBuffer(buffer, at: nil, options: options) { [weak self] in
                self?.playbackComplete(playID: thisPlay)
            }

            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }
        }

        return true
    }

    //called from scheduleBuffer's completion handler above, on the audio thread
    func playbackComplete(playID finished: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        //a sound that has since been replaced or stopped does not free the channel
        guard finished == playID else { return }
        currentBuffer = nil
        isPlaying = false
    }

    // Stop playback
    func stopPlayback() {
        playerNode.stop()
        playerNode.reset()
        stateLock.lock()
        playID += 1 //any pending start or completion of the stopped sound no longer counts
        currentBuffer = nil
        isPlaying = false
        stateLock.unlock()
    }

    // Check if channel is playing
    func isAvailable() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isPlaying
    }

    // Set pan
    func setPan(_ pan: Float) {
        mixerNode.pan = pan
    }

    // Set pitch
    func setPitch(_ pitch: Float) {
        
        if (pitchMode == XvAudioConstants.kXvPitchModeTimePitch){
            
            timePitchNode.pitch = pitch
            
        } else if (pitchMode == XvAudioConstants.kXvPitchModeVarispeed) {
     
            varispeedPitchNode.rate = pitch
        }
    }
    
    // Set Low-Pass Filter Cutoff
    func setLowPassFilter(frequency: Float) {
        if let filterParams = eqNode.bands.first {
            filterParams.frequency = frequency
        }
    }

    ///The high-pass cutoff in Hz. 20 or under bypasses it (the channel's default).
    func setHighPassFilter(frequency: Float) {
        guard eqNode.bands.count > 1 else { return }
        let highPass = eqNode.bands[1]
        if frequency <= 20 {
            highPass.bypass = true
        } else {
            highPass.frequency = frequency
            highPass.bypass = false
        }
    }
    
    // Set volume
    func setVolume(_ volume: Float) {
        mixerNode.outputVolume = volume
    }
    
    //private var rampToTimer: Timer?

//    func rampToVolume(_ targetVolume: Float, duration: TimeInterval) {
//        // If not on the main thread, dispatch to main
//        if !Thread.isMainThread {
//            DispatchQueue.main.async {
//                self.rampToVolume(targetVolume, duration: duration)
//            }
//            return
//        }
//
//        let startVolume = mixerNode.outputVolume
//        let volumeDelta = abs(targetVolume - startVolume)
//
//        // Define a base step count and a minimum change threshold per step
//        let baseSteps = 60
//        let minChangePerStep: Float = 0.01
//
//        // Calculate how many steps are really needed
//        // For example, if volumeDelta is 0.05 and minChangePerStep is 0.01 => 5 steps
//        let neededSteps = Int(ceil(volumeDelta / minChangePerStep))
//        // Pick the smaller of baseSteps and neededSteps, ensuring at least 1 step
//        let steps = max(1, min(baseSteps, neededSteps))
//
//        // Step duration based on total desired time
//        let stepDuration = duration / Double(steps)
//        var currentStep = 0
//
//        //print("Ramp from \(startVolume) to \(targetVolume), total delta \(volumeDelta), steps \(steps), stepDuration \(stepDuration) totalTime \(Double(steps) * stepDuration)")
//
//        // Invalidate existing timer
//        rampToTimer?.invalidate()
//        rampToTimer = nil
//
//        rampToTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
//            guard let self = self else { return }
//
//            currentStep += 1
//            let fraction = Float(currentStep) / Float(steps)
//            
//            // Interpolate linearly between startVolume and targetVolume
//            let newVolume: Float
//            if targetVolume >= startVolume {
//                newVolume = startVolume + (volumeDelta * fraction)
//            } else {
//                newVolume = startVolume - (volumeDelta * fraction)
//            }
//
//            self.mixerNode.outputVolume = newVolume
//            //print("Step \(currentStep): newVol \(newVolume)")
//
//            if currentStep >= steps {
//                timer.invalidate()
//                self.mixerNode.outputVolume = targetVolume
//                //print("Ramp complete at \(targetVolume)")
//            }
//        }
//
//        // Ensure the timer fires during common run loop modes (e.g. scrolling)
//        RunLoop.main.add(rampToTimer!, forMode: .common)
//    }

}

