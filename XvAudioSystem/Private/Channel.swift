import AVFoundation

class Channel {
    
    let id: Int
    
    // Nodes
    private let playerNode:AVAudioPlayerNode = AVAudioPlayerNode()
    private let timePitchNode:AVAudioUnitTimePitch = AVAudioUnitTimePitch()
    private let varispeedPitchNode:AVAudioUnitVarispeed = AVAudioUnitVarispeed()
    private let eqNode: AVAudioUnitEQ = AVAudioUnitEQ(numberOfBands: 1)
        
    private let mixerNode: AVAudioMixerNode
    
    private var pitchMode:String = XvAudioConstants.kXvPitchModeTimePitch

    // channel states
    private var looping: Bool = false
    private var isPlaying:Bool = false

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

    // Connect nodes
    func connectNodes(to mainMixer: AVAudioMixerNode) {
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
            engine.connect(mixerNode, to: mainMixer, format: nil)
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
        
        // Stop previous playback
        stopPlayback()

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
        
        // Retain buffer
        currentBuffer = buffer
        
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

        // Schedule playback with looping option
        //slight delay to give channel time to apply incoming pan, volume, filter, etc
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let buffer = self.currentBuffer else { return }

            let options: AVAudioPlayerNodeBufferOptions = loop ? [.loops] : []
            self.playerNode.scheduleBuffer(buffer, at: nil, options: options) {
                self.playbackComplete()
            }

            if !self.playerNode.isPlaying {
                self.playerNode.play()
                self.isPlaying = true
            }
        }
        self.isPlaying = true

        return true
    }

    //called from scheduleBuffer completion handler above
    func playbackComplete(){
        //playerNode.stop()
        //playerNode.reset()
        currentBuffer = nil
        isPlaying = false
    }

    // Stop playback
    func stopPlayback() {
        playerNode.stop()
        playerNode.reset()
        currentBuffer = nil
        isPlaying = false
    }

    // Check if channel is playing
    func isAvailable() -> Bool {
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

