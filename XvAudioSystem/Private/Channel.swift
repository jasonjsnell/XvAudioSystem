import AVFoundation

class Channel {
    
    let id: Int
    
    // Nodes
    private let playerNode = AVAudioPlayerNode()
    private let pitchNode = AVAudioUnitTimePitch()
    private let mixerNode: AVAudioMixerNode

    // Audio File
    private var audioFile: AVAudioFile?
    private var looping: Bool = false
    private var isPlaying:Bool = false

    // Initialization
    init(id: Int) {
        
        self.id = id
        
        // Initialize the mix node for this channel
        mixerNode = AVAudioMixerNode()
        mixerNode.outputVolume = 1.0
    }

    // Attach nodes to the engine
    func attachNodes(to engine: AVAudioEngine) {
        engine.attach(playerNode)
        engine.attach(pitchNode)
        engine.attach(mixerNode)
    }

    // Connect nodes
    func connectNodes(to mainMixer: AVAudioMixerNode) {
        if let engine = playerNode.engine {
            // Connect player -> pitch -> mixer
            engine.connect(playerNode, to: pitchNode, format: nil)
            engine.connect(pitchNode, to: mixerNode, format: nil)
            engine.connect(mixerNode, to: mainMixer, format: nil)
        }
    }

    // Play sound
    func playSound(name: String, volume: Float = 1.0, pitch: Float = 0.0, pan: Float = 0.0, loop: Bool = false) -> Bool {
        // Stop previous playback
        stopPlayback()

        // Load the audio file if not already loaded or if a different file is requested
        if audioFile == nil || audioFile?.url.lastPathComponent != "\(name).wav" {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
                print("Could not find audio file \(name).wav")
                return false
            }

            do {
                audioFile = try AVAudioFile(forReading: url)
            } catch {
                print("Error loading audio file: \(name) \(error.localizedDescription)")
                return false
            }
        }

        guard let audioFile = audioFile else {
            print("Audio file \(name) is not available.")
            return false
        }

        // Create a buffer from the audio file
        let processingFormat = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            print("Could not create PCM buffer for \(name).")
            return false
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            print("Error reading audio file \(name) into buffer: \(error.localizedDescription)")
            return false
        }

        // Schedule playback with looping option
        let options: AVAudioPlayerNodeBufferOptions = loop ? [.loops] : []
        playerNode.scheduleBuffer(buffer, at: nil, options: options) { [self] in
            playbackComplete()
        }

        // Set parameters
        mixerNode.outputVolume = volume
        pitchNode.pitch = pitch
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
        isPlaying = false
    }

    // Stop playback
    func stopPlayback() {
        playerNode.stop()
        playerNode.reset()
    }

    // Check if channel is playing
    func isAvailable() -> Bool {
        return !isPlaying
    }

    // Set volume
    func setVolume(_ volume: Float) {
        mixerNode.outputVolume = volume
    }

    // Set pan
    func setPan(_ pan: Float) {
        mixerNode.pan = pan
    }

    // Set pitch
    func setPitch(_ pitch: Float) {
        pitchNode.pitch = pitch
    }
}

