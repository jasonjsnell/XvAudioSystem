import AVFoundation

class Engine {
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
        audioEngine.connect(mainMixer, to: lpfNode, format: mainMixer.outputFormat(forBus: 0))
        audioEngine.connect(lpfNode, to: delayNode, format: mainMixer.outputFormat(forBus: 0))
        audioEngine.connect(delayNode, to: reverbNode, format: mainMixer.outputFormat(forBus: 0))
        audioEngine.connect(reverbNode, to: audioEngine.outputNode, format: mainMixer.outputFormat(forBus: 0))
    }
    
    func setup(withChannelTotal: Int) {
        
        // Create channels
        for i in 0..<withChannelTotal {
            let channel = Channel(id: i)
            channels.append(channel)
            
            // Attach channel nodes to the engine
            channel.attachNodes(to: audioEngine)
            
            // Connect channel nodes
            channel.connectNodes(to: mainMixer)
        }
        
        // Start the audio engine
        do {
            try audioEngine.start()
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
        }
    }
    
    func getChannels() -> [Channel] {
        return channels
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
    
    //MARK: FX
    func setLowPassFilter(frequency: Float) {
        if let filterParams = lpfNode.bands.first {
            filterParams.frequency = frequency
        }
    }
    
    func set(delayWetDryMix:Float) {
        delayNode.wetDryMix = delayWetDryMix * 100
    }
    func set(reverbWetDryMix:Float) {
        delayNode.wetDryMix = reverbWetDryMix * 100
    }

}

