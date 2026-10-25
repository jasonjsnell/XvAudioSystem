import AVFoundation
import Accelerate

public protocol EngineDelegate: AnyObject {
    func fftDidUpdate(withDecibelArray:[Float])
}

class Engine {
    
    public weak var delegate: EngineDelegate?
    
    // Singleton instance
    static let sharedInstance = Engine()
    
    // The AVAudioEngine instance
    private let audioEngine = AVAudioEngine()
    
    // Nodes
    private let mainMixer: AVAudioMixerNode
    private let delayNode: AVAudioUnitDelay
    private let reverbNode: AVAudioUnitReverb
    private let lpfNode: AVAudioUnitEQ
    
    // Channels
    private var channels: [Channel] = []

    /* DRY BUS (29 Sep 2026, opt-in, see XvmAudioSystem.setup(...enableDryBus:)). Only
     built when asked for; without it the graph is exactly as before. With it, every
     channel feeds two places at once: the main mixer (then the master low-pass, delay and
     reverb) and this dry mixer, which skips the effects. Both meet again in the output
     mixer. Each channel sets how much it sends to each (Channel.setSends). */
    private var dryMixer: AVAudioMixerNode?
    private var outputMixer: AVAudioMixerNode?
    private(set) var hasDryBus = false

    /* DELAY BUS (7 Oct 2026, opt-in, additive). Without it the delay sits in the one
     effects chain (low-pass, delay, reverb) and everything wet goes through it. With it
     the delay becomes its own send and return, beside the reverb: channels feed this
     delay mixer at their own level (setSends delay:), the delay runs echo-only (wet 100)
     and its echoes go straight to the output, NOT through the reverb (an echo that went
     into a fully wet reverb was never heard as an echo). The plain wet path skips the
     delay. Turning the bus on changes nothing until a channel sends to it. */
    private var delayMixer: AVAudioMixerNode?
    private(set) var hasDelayBus = false
    ///The reverb's input mixer, once a bus has made one (the delay bus, or the spatial bus below).
    private var reverbIn: AVAudioMixerNode?

    /* SPATIAL REVERB BUS (18 Oct 2026, opt-in, additive). A second reverb beside the main
     one, placed around the listener's head. The reverb's input is split: one copy goes to
     the main reverb as before, the other to this spatial reverb, whose return is summed to
     mono and rendered through an AVAudioEnvironmentNode with head-related transfer
     functions (HRTF, headphones only; on a speaker it plays as plain stereo). Two gain
     mixers in front of the reverbs set the split (set(spatialMix:), equal power), and
     setSpatial(azimuthDegrees:elevationDegrees:) moves the position. The environment's own
     reverb and distance attenuation are off: this is a reverb that is positioned, not a
     positioned sound with a room. Turning the bus on changes nothing until the mix is
     moved off 0. Costs one more reverb and one HRTF render. */
    private var spatialReverb: AVAudioUnitReverb?
    private var spatialSource: AVAudioMixerNode?
    private var environment: AVAudioEnvironmentNode?
    private var reverbGain: AVAudioMixerNode?
    private var spatialGain: AVAudioMixerNode?
    private(set) var hasSpatialBus = false

    /* MASTER (8 Oct 2026, additive): the last stage before the output, whatever graph is
     built above it: a mixer for the master gain, then a peak limiter. Gain 0 dB and the
     limiter bypassed to start, so nothing changes until an app asks. */
    private let masterMixer = AVAudioMixerNode()
    private var limiter: AVAudioUnitEffect?

    private func connectToOutput(_ node: AVAudioNode, format: AVAudioFormat) {
        if limiter == nil {
            let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                        componentSubType: kAudioUnitSubType_PeakLimiter,
                                                        componentManufacturer: kAudioUnitManufacturer_Apple,
                                                        componentFlags: 0, componentFlagsMask: 0)
            let unit = AVAudioUnitEffect(audioComponentDescription: description)
            unit.bypass = true
            audioEngine.attach(masterMixer)
            audioEngine.attach(unit)
            audioEngine.connect(masterMixer, to: unit, format: format)
            audioEngine.connect(unit, to: audioEngine.outputNode, format: format)
            limiter = unit
        }
        audioEngine.disconnectNodeOutput(node)
        audioEngine.connect(node, to: masterMixer, fromBus: 0, toBus: masterMixer.nextAvailableInputBus, format: format)
    }

    /* OUTPUT METER (8 Oct 2026, additive, for tuning): a tap on the very last node reports
     the loudest peak and the average level of each second, in dB full scale, on the
     audio thread. nil removes the tap. */
    private var meterPeak: Float = 0
    private var meterSquares: Double = 0
    private var meterFrames: Int = 0
    private var meterSeconds: Double = 1

    func set(outputMeter: ((_ peakDb: Float, _ rmsDb: Float) -> Void)?, everySeconds seconds: Double) {
        guard let limiter else { return }
        limiter.removeTap(onBus: 0)
        guard let outputMeter else { return }
        meterSeconds = max(seconds, 0.1)
        meterPeak = 0; meterSquares = 0; meterFrames = 0
        let format = limiter.outputFormat(forBus: 0)
        limiter.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
            for channel in 0..<channels {
                let samples = data[channel]
                for frame in 0..<frames {
                    let value = abs(samples[frame])
                    if value > self.meterPeak { self.meterPeak = value }
                    self.meterSquares += Double(value * value)
                }
            }
            self.meterFrames += frames * channels
            let due = Int(format.sampleRate * self.meterSeconds) * channels
            if self.meterFrames >= due {
                let rms = sqrt(self.meterSquares / Double(self.meterFrames))
                let db: (Double) -> Float = { $0 > 0 ? Float(20 * log10($0)) : -120 }
                outputMeter(db(Double(self.meterPeak)), db(rms))
                self.meterPeak = 0; self.meterSquares = 0; self.meterFrames = 0
            }
        }
    }

    ///The master gain in dB (-60 to +24), on everything the app plays.
    func set(masterGainDb: Float) {
        masterMixer.outputVolume = powf(10, min(max(masterGainDb, -60), 24) / 20)
    }
    ///The peak limiter on the output, on or off (off to start).
    func set(limiterEnabled: Bool) {
        limiter?.bypass = !limiterEnabled
    }
    /* The delay's return mixer (a mixer, since only a mixer can set a level per
     destination) and its two destinations: the output (clean echoes) and, at its own
     level, the reverb. */
    private var delayReturn: AVAudioMixerNode?
    private var delayReturnToOutput: (mixer: AVAudioMixerNode, bus: AVAudioNodeBus)?
    private var delayReturnToReverb: (mixer: AVAudioMixerNode, bus: AVAudioNodeBus)?

    /* REVERB RETURN HIGH-PASS (30 Sep 2026, dry bus only). Sits after the reverb, on the
     return, so the reverb's low end does not muddy the mix. Two 12 dB/octave high-pass
     bands at the same frequency: 24 dB/octave. Bypassed until a frequency is set, so
     turning the dry bus on does not change the sound by itself. Not available without the
     dry bus: there the reverb carries the dry signal too, and this would thin everything. */
    private var reverbHighPass: AVAudioUnitEQ?
    
    //FFT
    private var enableFFT: Bool = false
    private var fftProcessor: FFTProcessor? = nil
    
    private init() {
        
        //main mixer
        mainMixer = audioEngine.mainMixerNode
        
        //delay
        delayNode = AVAudioUnitDelay()
        delayNode.delayTime = 0.28
        delayNode.feedback = 60.0
        delayNode.wetDryMix = 0
        delayNode.lowPassCutoff = 15000
        
        //reverb
        reverbNode = AVAudioUnitReverb()
        reverbNode.loadFactoryPreset(.cathedral)
        reverbNode.wetDryMix = 0
        
        //lpf
        lpfNode = AVAudioUnitEQ(numberOfBands: 1)
        // Configure low-pass filter
        if let filterParams = lpfNode.bands.first {
            filterParams.filterType = .lowPass
            filterParams.frequency = 20000 // Set initial cutoff frequency
            filterParams.bandwidth = 0.5    // Bandwidth in octaves
            filterParams.bypass = false
        }
        
        // Attach nodes to the engine
        audioEngine.attach(lpfNode)
        audioEngine.attach(delayNode)
        audioEngine.attach(reverbNode)
        
        // Connect nodes in the desired order
        audioEngine.connect(mainMixer,  to: lpfNode, format: mainMixer.outputFormat(forBus: 0))
        audioEngine.connect(lpfNode,    to: delayNode, format: mainMixer.outputFormat(forBus: 0))
        audioEngine.connect(delayNode,  to: reverbNode, format: mainMixer.outputFormat(forBus: 0))
        connectToOutput(reverbNode, format: mainMixer.outputFormat(forBus: 0))
    }
    
    func setup(
        withChannelTotal: Int,
        withPitchMode:String = XvAudioConstants.kXvPitchModeTimePitch,
        enableFFT:Bool = false,
        enableDryBus:Bool = false,
        enableDelayBus:Bool = false,
        enableSpatialBus:Bool = false,
        contentSampleRate:Double? = nil //the rate the app's recordings are at (23 Oct 2026, additive): the players run at it
    ) -> AudioUnit? {
        
        // Set up FFT processor if needed
        if enableFFT {
            setupFFT()
        }


        //the dry bus, only when asked for: reverb and dry mixer meet in an output mixer
        if enableDryBus {
            let dry = AVAudioMixerNode()
            let output = AVAudioMixerNode()
            audioEngine.attach(dry)
            audioEngine.attach(output)
            let format = mainMixer.outputFormat(forBus: 0)
            let highPass = AVAudioUnitEQ(numberOfBands: 2)
            for band in highPass.bands {
                band.filterType = .highPass
                band.frequency = 20
                band.bypass = true
            }
            audioEngine.attach(highPass)
            audioEngine.disconnectNodeOutput(reverbNode)
            audioEngine.connect(reverbNode, to: highPass, format: format)
            audioEngine.connect(highPass, to: output, fromBus: 0, toBus: 0, format: format)
            reverbHighPass = highPass
            audioEngine.connect(dry, to: output, fromBus: 0, toBus: 1, format: format)
            connectToOutput(output, format: format)
            dryMixer = dry
            outputMixer = output
            hasDryBus = true
        }

        /* The delay bus: the delay comes out of the effects chain (low-pass straight to
         reverb) and becomes its own send and return, meeting the reverb and the dry bus in
         the output mixer. Made after the dry bus, so it can use its output mixer; without
         a dry bus it makes one. */
        if enableDelayBus {
            let format = mainMixer.outputFormat(forBus: 0)
            let delayIn = AVAudioMixerNode()
            audioEngine.attach(delayIn)
            audioEngine.disconnectNodeOutput(lpfNode)
            audioEngine.disconnectNodeOutput(delayNode)
            //the reverb's input mixer: the wet path, and the delay's echoes at their own level
            let reverbIn = AVAudioMixerNode()
            audioEngine.attach(reverbIn)
            audioEngine.connect(lpfNode, to: reverbIn, fromBus: 0, toBus: 0, format: format)
            audioEngine.connect(reverbIn, to: reverbNode, format: format)
            let output: AVAudioMixerNode
            if let existing = outputMixer {
                output = existing
            } else {
                output = AVAudioMixerNode()
                audioEngine.attach(output)
                audioEngine.disconnectNodeOutput(reverbNode)
                audioEngine.connect(reverbNode, to: output, fromBus: 0, toBus: 0, format: format)
                connectToOutput(output, format: format)
                outputMixer = output
            }
            let delayOut = AVAudioMixerNode()
            audioEngine.attach(delayOut)
            audioEngine.connect(delayIn, to: delayNode, format: format)
            audioEngine.connect(delayNode, to: delayOut, format: format)
            let outputBus = output.nextAvailableInputBus
            let reverbBus = reverbIn.nextAvailableInputBus
            audioEngine.connect(delayOut, to: [
                AVAudioConnectionPoint(node: output, bus: outputBus),
                AVAudioConnectionPoint(node: reverbIn, bus: reverbBus)
            ], fromBus: 0, format: format)
            delayReturn = delayOut
            delayReturnToOutput = (output, outputBus)
            delayReturnToReverb = (reverbIn, reverbBus)
            set(delayReverbSend: 0) //clean echoes until asked otherwise
            delayNode.wetDryMix = 100 //echoes only: the sound itself arrives by the wet and dry buses
            delayMixer = delayIn
            hasDelayBus = true
            self.reverbIn = reverbIn
        }

        /* The spatial reverb bus (see the properties above). Made after the other buses, so
         it can use their reverb input and output mixers; without them it makes its own. */
        if enableSpatialBus {
            let format = mainMixer.outputFormat(forBus: 0)
            //the reverb's input mixer: the delay bus made one; otherwise one goes in between the delay and the reverb
            let input: AVAudioMixerNode
            if let existing = reverbIn {
                input = existing
            } else {
                input = AVAudioMixerNode()
                audioEngine.attach(input)
                audioEngine.disconnectNodeOutput(delayNode)
                audioEngine.connect(delayNode, to: input, fromBus: 0, toBus: 0, format: format)
                audioEngine.connect(input, to: reverbNode, format: format)
                reverbIn = input
            }
            //the output mixer: the dry or delay bus made one; otherwise one goes in after the reverb
            let output: AVAudioMixerNode
            if let existing = outputMixer {
                output = existing
            } else {
                output = AVAudioMixerNode()
                audioEngine.attach(output)
                audioEngine.disconnectNodeOutput(reverbNode)
                audioEngine.connect(reverbNode, to: output, fromBus: 0, toBus: 0, format: format)
                connectToOutput(output, format: format)
                outputMixer = output
            }
            //the split: a gain mixer in front of each reverb (only a mixer has a level of its own)
            let toReverb = AVAudioMixerNode()
            let toSpatial = AVAudioMixerNode()
            let spatial = AVAudioUnitReverb()
            spatial.loadFactoryPreset(.cathedral)
            spatial.wetDryMix = 100 //reverb only: the sound itself arrives by the other buses
            let source = AVAudioMixerNode()
            let env = AVAudioEnvironmentNode()
            for node in [toReverb, toSpatial, spatial, source, env] as [AVAudioNode] { audioEngine.attach(node) }
            audioEngine.disconnectNodeOutput(input)
            audioEngine.connect(input, to: [
                AVAudioConnectionPoint(node: toReverb, bus: 0),
                AVAudioConnectionPoint(node: toSpatial, bus: 0)
            ], fromBus: 0, format: format)
            audioEngine.connect(toReverb, to: reverbNode, format: format)
            audioEngine.connect(toSpatial, to: spatial, format: format)
            audioEngine.connect(spatial, to: source, format: format)
            //the environment takes one mono source per input; the mixer sums the reverb's stereo return to mono
            let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) ?? format
            audioEngine.connect(source, to: env, format: mono)
            audioEngine.connect(env, to: output, fromBus: 0, toBus: output.nextAvailableInputBus, format: format)
            source.renderingAlgorithm = .HRTFHQ
            source.reverbBlend = 0
            source.position = AVAudio3DPoint(x: 0, y: 0, z: -1) //straight ahead, one unit away
            env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            env.listenerVectorOrientation = AVAudio3DVectorOrientation(forward: AVAudio3DVector(x: 0, y: 0, z: -1), up: AVAudio3DVector(x: 0, y: 1, z: 0))
            env.reverbParameters.enable = false
            env.distanceAttenuationParameters.distanceAttenuationModel = .exponential
            env.distanceAttenuationParameters.rolloffFactor = 0 //no attenuation by distance: the mix below does that
            env.distanceAttenuationParameters.referenceDistance = 1
            reverbGain = toReverb
            spatialGain = toSpatial
            spatialReverb = spatial
            spatialSource = source
            environment = env
            hasSpatialBus = true
            set(spatialMix: 0) //all main reverb until asked otherwise
        }

        let channelFormat = contentSampleRate.flatMap { AVAudioFormat(standardFormatWithSampleRate: $0, channels: 2) }
        // Create channels
        for i in 0..<withChannelTotal {
            let channel = Channel(id: i, pitchMode: withPitchMode)
            channels.append(channel)
            
            // Attach channel nodes to the engine
            channel.attachNodes(to: audioEngine)
            
            // Connect channel nodes (to both buses when there is a dry bus, and the delay bus when there is one)
            channel.connectNodes(to: mainMixer, dryMixer: dryMixer, delayMixer: delayMixer, format: channelFormat)
        }
        if let channelFormat, let first = channels.first {
            print("XvAudioSystem: channels run at", channelFormat.sampleRate, "Hz; player output", first.playerOutputDescription, "; output mixer", mainMixer.outputFormat(forBus: 0).sampleRate, "Hz")
        }
        
        // Start the audio engine
        do {
            try audioEngine.start()
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
        }
        
        return audioEngine.outputNode.audioUnit
    }
   
    
    func getChannels() -> [Channel] {
        return channels
    }
    
    func isRunning() -> Bool {
        return audioEngine.isRunning
    }
    
    func startEngine() {
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("Error starting audio engine: \(error.localizedDescription)")
            }
        }
    }
    
    func stopEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }
    
    //MARK: - FX
    func setLowPassFilter(frequency: Float) {
        if let filterParams = lpfNode.bands.first {
            filterParams.frequency = frequency
        }
    }
    
    func set(delayWetDryMix:Float) {
        delayNode.wetDryMix = delayWetDryMix * 100
    }
    func setDelayBpm(bpm: Double, subdivision: Double = 1.0) {
        // Ensure BPM is valid
        guard bpm > 0 else {
            print("Engine: Error: Invalid BPM")
            return
        }
        
        // Calculate seconds per beat
        let secondsPerBeat = 60.0 / bpm
        
        // Calculate delay time based on the subdivision (e.g., quarter note, eighth note)
        let delayTime = secondsPerBeat / subdivision
        
        if (delayTime > 2.0) {
            print("Engine: Error: Delay time cannot be more than 2.0")
            return
        }
        
        // Ensure delay time is within the allowable range
        delayNode.delayTime = delayTime
    }
    func set(delayFeedback:Float) {
        delayNode.feedback = delayFeedback
    }
    ///How much of the delay's return also goes into the reverb, 0 to 1 (delay bus only).
    func set(delayReverbSend:Float) {
        guard let delayReturn, let delayReturnToReverb else { return }
        delayReturn.destination(forMixer: delayReturnToReverb.mixer, bus: delayReturnToReverb.bus)?.volume = max(0, min(1, delayReverbSend))
        if let delayReturnToOutput {
            delayReturn.destination(forMixer: delayReturnToOutput.mixer, bus: delayReturnToOutput.bus)?.volume = 1
        }
    }
    ///The delay's own low-pass on its echoes, in Hz (10 to 22050): each echo darker than the last.
    func set(delayLowPassHz:Float) {
        delayNode.lowPassCutoff = min(max(delayLowPassHz, 10), 22050)
    }
    func set(reverbWetDryMix:Float) {
        reverbNode.wetDryMix = reverbWetDryMix * 100
    }
    func set(reverbMode:AVAudioUnitReverbPreset) {
        reverbNode.loadFactoryPreset(reverbMode)
    }

    ///The reverb return's high-pass, 24 dB/octave (dry bus only). nil or 0 bypasses it.
    func setReverbHighPass(frequency: Float?) {
        guard let highPass = reverbHighPass else { return }
        for band in highPass.bands {
            if let frequency, frequency > 0 {
                band.frequency = frequency
                band.bypass = false
            } else {
                band.bypass = true
            }
        }
    }

    /* The reverb unit's own parameters (Apple's Reverb2), beyond the preset and the mix.
     Loading a preset sets all of them, so set these AFTER choosing a preset. */
    func setReverbParameter(_ parameter: AudioUnitParameterID, value: Float) {
        AudioUnitSetParameter(reverbNode.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
    }

    //MARK: - Spatial reverb bus (18 Oct 2026)

    /* How the reverb input is split, 0 to 1: 0 all to the main reverb, 1 all to the spatial
     reverb, equal power between. Spatial bus only. */
    func set(spatialMix: Float) {
        guard let reverbGain, let spatialGain else { return }
        let mix = min(max(spatialMix, 0), 1)
        let angle = mix * Float.pi / 2
        reverbGain.outputVolume = cos(angle)
        spatialGain.outputVolume = sin(angle)
    }

    /* Where the spatial reverb sits around the head: the azimuth in degrees clockwise from
     straight ahead (0 ahead, 90 right, 180 behind, 270 left), the elevation in degrees up
     from the ear line, one unit away. Spatial bus only. */
    func setSpatial(azimuthDegrees: Float, elevationDegrees: Float) {
        guard let spatialSource else { return }
        let azimuth = azimuthDegrees * Float.pi / 180
        let elevation = min(max(elevationDegrees, -90), 90) * Float.pi / 180
        //the listener faces -z; x is right, y is up
        spatialSource.position = AVAudio3DPoint(x: sin(azimuth) * cos(elevation),
                                                y: sin(elevation),
                                                z: -cos(azimuth) * cos(elevation))
    }

    ///The spatial reverb's preset (spatial bus only). As with the main reverb, set its finer parameters after this.
    func set(spatialReverbMode: AVAudioUnitReverbPreset) {
        spatialReverb?.loadFactoryPreset(spatialReverbMode)
    }

    ///The spatial reverb unit's own parameters (Apple's Reverb2), as setReverbParameter for the main reverb.
    func setSpatialReverbParameter(_ parameter: AudioUnitParameterID, value: Float) {
        guard let spatialReverb else { return }
        AudioUnitSetParameter(spatialReverb.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
    }
    
    //MARK: - FFT
    private func setupFFT() {
        let bufferSize: AVAudioFrameCount = 1024
        fftProcessor = FFTProcessor(bufferSize: Int(bufferSize))
        
        mainMixer.installTap(onBus: 0, bufferSize: bufferSize, format: mainMixer.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self = self, let fft = self.fftProcessor else { return }

            // Step 1: Get magnitudes (power spectrum)
            let magnitudes = fft.performFFT(buffer: buffer)

            // Step 2: Convert to dB
            var dbValues = [Float](repeating: 0.0, count: magnitudes.count)
            var zeroRef: Float = 1.0 // Reference value, usually 1.0
            vDSP_vdbcon(magnitudes, 1, &zeroRef, &dbValues, 1, vDSP_Length(magnitudes.count), 0) // 0 = power

            // Step 3 (optional): Clamp to visible range
            let minDb: Float = -80
            let maxDb: Float = 0
            let clampedDb = dbValues.map { max(min($0, maxDb), minDb) }

            //let avgDb = clampedDb.prefix(10).reduce(0, +) / Float(clampedDb.prefix(10).count)
            //print("FFT dB Avg (first 10 bins):", avgDb, "Count:", clampedDb.count)
            
            //send to parent
            delegate?.fftDidUpdate(withDecibelArray: clampedDb)
        }
    }

    
    func disableFFT() {
        mainMixer.removeTap(onBus: 0)
        fftProcessor = nil
    }

}

