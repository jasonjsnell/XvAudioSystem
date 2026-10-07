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
        audioEngine.connect(reverbNode, to: audioEngine.outputNode, format: mainMixer.outputFormat(forBus: 0))
    }
    
    func setup(
        withChannelTotal: Int,
        withPitchMode:String = XvAudioConstants.kXvPitchModeTimePitch,
        enableFFT:Bool = false,
        enableDryBus:Bool = false,
        enableDelayBus:Bool = false
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
            audioEngine.connect(output, to: audioEngine.outputNode, format: format)
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
                audioEngine.connect(output, to: audioEngine.outputNode, format: format)
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
        }
        
        // Create channels
        for i in 0..<withChannelTotal {
            let channel = Channel(id: i, pitchMode: withPitchMode)
            channels.append(channel)
            
            // Attach channel nodes to the engine
            channel.attachNodes(to: audioEngine)
            
            // Connect channel nodes (to both buses when there is a dry bus, and the delay bus when there is one)
            channel.connectNodes(to: mainMixer, dryMixer: dryMixer, delayMixer: delayMixer)
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

