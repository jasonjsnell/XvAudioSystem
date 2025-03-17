import AVFoundation

class Channel {
    
    let id: Int
    
    // Nodes
    private let playerNode:AVAudioPlayerNode = AVAudioPlayerNode()
    private let timePitchNode:AVAudioUnitTimePitch = AVAudioUnitTimePitch()
    private let varispeedPitchNode:AVAudioUnitVarispeed = AVAudioUnitVarispeed()
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
    }

    // Attach nodes to the engine
    func attachNodes(to engine: AVAudioEngine) {
        engine.attach(playerNode)
        
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
            // Connect player -> pitch -> mixer
            
            if (pitchMode == XvAudioConstants.kXvPitchModeTimePitch){
                
                //timestretch
                engine.connect(playerNode, to: timePitchNode, format: nil)
                engine.connect(timePitchNode, to: mixerNode, format: nil)
            } else if (pitchMode == XvAudioConstants.kXvPitchModeVarispeed) {
    
                //no time stretch
                engine.connect(playerNode, to: varispeedPitchNode, format: nil)
                engine.connect(varispeedPitchNode, to: mixerNode, format: nil)
            }
            
            engine.connect(mixerNode, to: mainMixer, format: nil)
        }
    }

    // Play sound
    private var currentBuffer: AVAudioPCMBuffer?
      
    func playSound(name: String, volume: Float = 1.0, rampTo:Float = 0.0, pitch: Float = 0.0, pan: Float = 0.0, loop: Bool = false) -> Bool {
        
        //print("XvAudioSystem: Channel: playSound: name", name, "volume", volume, "rampTo", rampTo, "pitch", pitch, "pan", pan, "loop", loop)
        
        // Stop previous playback
        stopPlayback()
        
        //Init new audioFile
        var audioFile: AVAudioFile?

        // Load the audio file if not already loaded or if a different file is requested
        if audioFile == nil || audioFile?.url.lastPathComponent != "\(name).wav" {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
                print("Channel: Could not find audio file \(name).wav")
                return false
            }

            do {
                audioFile = try AVAudioFile(forReading: url)
            } catch {
                print("Channel: Error loading audio file: \(name) \(error.localizedDescription)")
                return false
            }
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

        // Schedule playback with looping option
        let options: AVAudioPlayerNodeBufferOptions = loop ? [.loops] : []
        playerNode.scheduleBuffer(buffer, at: nil, options: options) { [weak self] in
            self?.playbackComplete()
        }
        
//        print("Audio file frameLength: \(audioFile.length), framePosition: \(audioFile.framePosition)")
//        print("Buffer capacity: \(buffer.frameCapacity), buffer length: \(buffer.frameLength)")


        //volume changes either immediate or ramping to that target volume
        if (rampTo == 0.0) {
            mixerNode.outputVolume = volume
        } else if (rampTo > 0.0){
            rampToVolume(volume, duration: TimeInterval(rampTo))
        } else if (rampTo < 0.0) {
            //make the value positive
            rampToVolume(volume, duration: TimeInterval(-rampTo))
        }
        
        // Set pitch and pan
        if (pitchMode == XvAudioConstants.kXvPitchModeTimePitch){
            
            timePitchNode.pitch = pitch
            
        } else if (pitchMode == XvAudioConstants.kXvPitchModeVarispeed) {
            
            varispeedPitchNode.rate = pitch
        }
        
        
        mixerNode.pan = pan

        // Start the player node if not already playing
        if !playerNode.isPlaying {
            playerNode.play()
            isPlaying = true
        }

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
    
    // Set volume
    func setVolume(_ volume: Float) {
        mixerNode.outputVolume = volume
    }
    
    private var rampToTimer: Timer?

    func rampToVolume(_ targetVolume: Float, duration: TimeInterval) {
        // If not on the main thread, dispatch to main
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.rampToVolume(targetVolume, duration: duration)
            }
            return
        }

        let startVolume = mixerNode.outputVolume
        let volumeDelta = abs(targetVolume - startVolume)

        // Define a base step count and a minimum change threshold per step
        let baseSteps = 60
        let minChangePerStep: Float = 0.01

        // Calculate how many steps are really needed
        // For example, if volumeDelta is 0.05 and minChangePerStep is 0.01 => 5 steps
        let neededSteps = Int(ceil(volumeDelta / minChangePerStep))
        // Pick the smaller of baseSteps and neededSteps, ensuring at least 1 step
        let steps = max(1, min(baseSteps, neededSteps))

        // Step duration based on total desired time
        let stepDuration = duration / Double(steps)
        var currentStep = 0

        //print("Ramp from \(startVolume) to \(targetVolume), total delta \(volumeDelta), steps \(steps), stepDuration \(stepDuration) totalTime \(Double(steps) * stepDuration)")

        // Invalidate existing timer
        rampToTimer?.invalidate()
        rampToTimer = nil

        rampToTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            guard let self = self else { return }

            currentStep += 1
            let fraction = Float(currentStep) / Float(steps)
            
            // Interpolate linearly between startVolume and targetVolume
            let newVolume: Float
            if targetVolume >= startVolume {
                newVolume = startVolume + (volumeDelta * fraction)
            } else {
                newVolume = startVolume - (volumeDelta * fraction)
            }

            self.mixerNode.outputVolume = newVolume
            //print("Step \(currentStep): newVol \(newVolume)")

            if currentStep >= steps {
                timer.invalidate()
                self.mixerNode.outputVolume = targetVolume
                //print("Ramp complete at \(targetVolume)")
            }
        }

        // Ensure the timer fires during common run loop modes (e.g. scrolling)
        RunLoop.main.add(rampToTimer!, forMode: .common)
    }

}

