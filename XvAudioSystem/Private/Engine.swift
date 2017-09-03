//
//  AuGraphManager.swift
//  Refraktions
//
//  Created by Jason Snell on 2/12/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//
import Foundation
import AudioToolbox


func renderCallback(
    
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBufNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: Optional<UnsafeMutablePointer<AudioBufferList>>) -> Int32 {
    
    Utils.postNotification(name: XvAudioConstants.kXvAudioGraphRender, userInfo: nil)
    return 0
}


class Engine {
    
    //MARK: - VARS -
    
    //augraph for all audio processing
    fileprivate var processingGraph: AUGraph? = nil
    
    //nodes
    fileprivate var playerNodes:[AUNode] = []
    fileprivate var pitchNodes:[AUNode] = []
    fileprivate var mixerNode:AUNode = 0
    fileprivate var remoteIoNode:AUNode = 0
    
    //formats
    fileprivate var pitchFormat:AudioStreamBasicDescription = AudioStreamBasicDescription()
    
    //set by mixer during init
    fileprivate var channelTotal:Int = 1
    // requests the desired hardware sample rate
    fileprivate var sampleRate:Double = 44100.0 // Hertz
    
    fileprivate let debug:Bool = false
    
    
    //MARK: - INIT -
    
    //singleton code
    static let sharedInstance = Engine()
    fileprivate init() {
        
    }
    
    //MARK: - ACCESSORS -
    
    //accessed by mixer during interruptions
    internal func startEngine(){
        
        let result:OSStatus = AUGraphStart(processingGraph!)
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error starting engine", withStatus: result)
            return
        }
    }
    
    //accessed by mixer during interruptions
    internal func stopEngine(){
        
        //stop if it's running
        //note: running always seems to be true
        if (_isGraphRunning()){
            let result:OSStatus = AUGraphStop(processingGraph!)
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error stopping engine", withStatus: result)
                return
            }
        }
    }
    
    //accessed by audio session maanger and audio stream formats
    internal func getSampleRate() -> Double {
        return sampleRate
    }
    
    //accessed by audio session manager
    internal func set(sampleRate:Double){
        self.sampleRate = sampleRate
    }
    
    internal func addRenderNotification(){
        
        let selfAsURP = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let selfAsUMRP = UnsafeMutableRawPointer(mutating:selfAsURP)
        
        let result:OSStatus = AUGraphAddRenderNotify(
            processingGraph!,
            renderCallback,
            selfAsUMRP
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error adding render notification", withStatus: result)
            return
        }
    }
    
    internal func removeRenderNotification(){
        
        let selfAsURP = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let selfAsUMRP = UnsafeMutableRawPointer(mutating:selfAsURP)
        
        let result:OSStatus = AUGraphRemoveRenderNotify(
            processingGraph!,
            renderCallback,
            selfAsUMRP
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error removing render notification", withStatus: result)
            return
        }
    }
    
    
    // MARK: - SETUP SEQUENCE -
    
    // Note: most of the code is below in the helper sub functions
    // This area is abstracted so it's easier to understand the process
    
    // MARK: 1. Set up graph and nodes
    // called by mixer
    
    internal func setup(withChannelTotal:Int) {
        
        channelTotal = withChannelTotal
        
        //Create an AUGraph
        _makeNewGraph()
        
        // Add nodes in reverse order, last io output is added first
        let ioDesc:AudioComponentDescription = AudioComponentDescriptions.getRemoteIoDescription()
        remoteIoNode = makeNode(withDescription: ioDesc)
        
        let mixerDesc:AudioComponentDescription = AudioComponentDescriptions.getMixerDescription()
        mixerNode = makeNode(withDescription: mixerDesc)
        
        //loop through and make a pitch and player node for each channel
        let pitchDesc:AudioComponentDescription = AudioComponentDescriptions.getPitchFxDescription()
        let playerDesc:AudioComponentDescription = AudioComponentDescriptions.getPlayerDescription()
        
        pitchNodes = []
        playerNodes = []
        
        for _ in 0 ..< channelTotal {
            
            pitchNodes.append(makeNode(withDescription: pitchDesc))
            playerNodes.append(makeNode(withDescription: playerDesc))
            
        }

        // Open graph (following this call, units are instatiated but not initialized yet)
        _openGraph()
    }
    
    // MARK: 2. Create channels with player / pitch sequence
    // called by mixer
    internal func getChannels() -> [Channel] {
        
        //create blank array
        var channels:[Channel] = []
        
        
            //grab its format
        
                
            //create loop
            for channel in 0..<channelTotal {
                
                //grab pitch unit
                if let pitchUnit:AudioUnit = _makePitchUnit(inChannel: channel) {
                    
                    pitchFormat = _getFormat(fromUnit: pitchUnit)!
                    
                    //grab player unit
                    if let playerUnit:AudioUnit = _makePlayerUnit(inChannel: channel, withFormat: pitchFormat) {
                        
                        //create audio channel and append it to the channels array
                        channels.append(Channel(
                            withBusNum: channel,
                            withPlayerUnit: playerUnit,
                            withPitchUnit: pitchUnit))
                        
                    } else {
                        print("AUDIO ENGINE: Error getting player unit")
                    }
                    
                } else {
                    print("AUDIO ENGINE: Error getting pitch unit")
                }
            }
            
           
       
        
        return channels
        
    }
    
    
    // MARK: 3. Init and format mixer unit
    // called by mixer and return obj held by mixer for volume / pan control on channels
    internal func getMixerUnit() -> AudioUnit? {
        
        return _makeMixerUnit(withFormat:pitchFormat)
    }
    
    //MARK: 4. Init and retrieve remoteIO unit
    internal func getRemoteIoUnit() -> AudioUnit? {
       
        return _makeRemoteIoUnit()
    }
     
     // MARK: 5. Connect nodes
     // called by mixer
    
    internal func connectNodes(){
        
        //connect all the players to their corresponding pitch nodes
        for channel in 0 ..< channelTotal {
            
            _connect(sourceNode: playerNodes[channel], sourceBus: 0, destinationNode: pitchNodes[channel], destinationBus: 0)
            _connect(sourceNode: pitchNodes[channel], sourceBus: 0, destinationNode: mixerNode, destinationBus: UInt32(channel))
            
        }
        
        //mixer main out goes into the remoteIoNode
        _connect(sourceNode: mixerNode, sourceBus: 0, destinationNode: remoteIoNode, destinationBus: 0)
        
       
    }
    
    
    // MARK: 6. Start engine
    // called by mixer
    internal func start(){
        
        _startGraph()
    }
    
    
   
    //MARK: - HELPER SUB FUNCTIONS -
    
    //MARK: Graph
    fileprivate func _makeNewGraph(){
        
        if (debug) { print("AUDIO ENGINE: Make new graph") }
        
        let result:OSStatus = NewAUGraph(&processingGraph)
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error creating graph", withStatus: result)
            return
        }
        
    }
    
    fileprivate func _openGraph(){
        
        if (debug) { print("AUDIO ENGINE: Open graph") }
        
        let result:OSStatus = AUGraphOpen(processingGraph!)
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error opening graph", withStatus: result)
            return
        }
        
    }
    
    fileprivate func _startGraph(){
        
        if (debug) { print("AUDIO ENGINE: Init and start graph") }
        
        // Diagnostic: Call CAShow if you want to look at the state of the audio processing graph
        
        if (debug) { CAShow(UnsafeMutablePointer(processingGraph!)) }
        
        // init graph
        // configures audio data stream formats for each input and output
        // validates connections between audio units
        
        let result:OSStatus = AUGraphInitialize(processingGraph!)
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error initializing graph", withStatus: result)
            return
        }
        
        // start graph
        if (debug) { print("AUDIO ENGINE: Start") }
        startEngine()
        
    }
    
    fileprivate func _isGraphRunning() -> Bool {
        
        var isGraphRunning: DarwinBoolean = false
        let result:OSStatus = AUGraphIsRunning(processingGraph!, &isGraphRunning)
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error seeing if engine is runing", withStatus: result)
            return false
        }
        
        return isGraphRunning.boolValue
    }

    //MARK: Nodes
    fileprivate func makeNode(withDescription:AudioComponentDescription) -> AUNode {
        
        //if (debug) { print("AUDIO ENGINE: Make node") }
        
        var _node:AUNode = 0
        var _desc:AudioComponentDescription = withDescription
        
        let result:OSStatus = AUGraphAddNode(
            processingGraph!,
            &_desc,
            &_node)
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error adding I/O node", withStatus: result)
            return 0
        }
        
        return _node
    }
    
    fileprivate func _connect(sourceNode:AUNode, sourceBus:UInt32, destinationNode:AUNode, destinationBus:UInt32) {
        
        let result:OSStatus = AUGraphConnectNodeInput (
            processingGraph!,
            sourceNode,         // source node
            sourceBus,          // source node output bus number
            destinationNode,    // destination node
            destinationBus      // desintation node input bus number
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error nodes", withStatus: result)
            return
        }
        
    }
    
    
    
    //MARK: Units
    fileprivate func _makeUnit(inNode:AUNode) -> AudioUnit? {
        
        // if (debug) { print("AUDIO ENGINE: Make unit") }
        
        var unit:AudioUnit? = nil
        
        let result:OSStatus = AUGraphNodeInfo(
            processingGraph!,
            inNode,
            nil,
            &unit
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error making unit", withStatus: result)
            return nil
        }
        
        return unit

    }
    
    fileprivate func _makeRemoteIoUnit() -> AudioUnit? {
        
        return _makeUnit(inNode: remoteIoNode)
    }
    
    fileprivate func _makePitchUnit(inChannel:Int) -> AudioUnit? {
        
        return _makeUnit(inNode: pitchNodes[inChannel])
    }
    
    fileprivate func _makePlayerUnit(inChannel:Int, withFormat:AudioStreamBasicDescription) -> AudioUnit? {
     
        //make a player unit with the incoming format and scope
        if let playerUnit:AudioUnit = _makeUnit(inNode: playerNodes[inChannel]) {
            _set(unit: playerUnit, withFormat: withFormat, inScope: kAudioUnitScope_Output, inElement: 0)
            return playerUnit
        }
        
        return nil
    }

    
    //mixer has its own make function because all the specifc properties that need to be set
    fileprivate func _makeMixerUnit(withFormat:AudioStreamBasicDescription) -> AudioUnit? {
        
        if (debug) { print("AUDIO ENGINE: Init mixer unit") }
        
        var result:OSStatus = noErr
        
        //init audio unit
        
        if let mixerUnit:AudioUnit = _makeUnit(inNode: mixerNode) {
            
            // set number of mixer inputs
            
            var channelCount:UInt32   = UInt32(channelTotal)
            
            result = AudioUnitSetProperty(
                mixerUnit,
                kAudioUnitProperty_ElementCount,
                kAudioUnitScope_Input,
                0,
                &channelCount,
                UInt32(MemoryLayout.size(ofValue: channelCount))
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting mixer's channel count", withStatus: result)
                return nil
            }
            
            
            // Increase the maximum frames per slice allows the mixer unit to accommodate the larger slice size used when the screen is locked.
            
            var maximumFramesPerSlice: UInt32 = 4096
            
            result = AudioUnitSetProperty(
                mixerUnit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &maximumFramesPerSlice,
                UInt32(MemoryLayout.size(ofValue: maximumFramesPerSlice))
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting mixer's frames per slice", withStatus: result)
                return nil
            }
            
            // Required by Audio Units: Setting mixer output sample rate.
            
            result = AudioUnitSetProperty(
                mixerUnit,
                kAudioUnitProperty_SampleRate,
                kAudioUnitScope_Output,
                0,
                &sampleRate,
                UInt32(MemoryLayout.size(ofValue: sampleRate))
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting mixer's sample rate", withStatus: result)
                return nil
            }
            
            //Set main mixer volume
            
            result = AudioUnitSetParameter(
                mixerUnit,
                kMultiChannelMixerParam_Volume,
                kAudioUnitScope_Output,
                0,
                1,
                0
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting mixer's volume", withStatus: result)
                return nil
            }
            
            
            //loop through each input on main mixer and set input stream format
            
            for channel in 0..<channelTotal {
                
                _set(unit: mixerUnit, withFormat: withFormat, inScope: kAudioUnitScope_Input, inElement: UInt32(channel))
                
            }
            
            return mixerUnit
            
        }
        
        return nil
        
        
        
    }

    
    //MARK: Format
    //set format stream, either input or output scope
    fileprivate func _set(unit:AudioUnit, withFormat:AudioStreamBasicDescription, inScope:AudioUnitScope, inElement:UInt32) {
        
        //if (debug) { print("AUDIO ENGINE: Set format with scope", inScope) }

        var _format:AudioStreamBasicDescription = withFormat
        
        let result:OSStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            inScope,
            inElement,
            &_format,
            UInt32(MemoryLayout.size(ofValue: _format))
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting stream format", withStatus: result)
            return
        }
        
    }
    
    
    fileprivate func _getFormat(fromUnit:AudioUnit) -> AudioStreamBasicDescription? {
        
        //if (debug) { print("AUDIO ENGINE: Get format") }
        
        var format:AudioStreamBasicDescription = AudioStreamBasicDescription()
        var formatSize:UInt32 = UInt32(MemoryLayout.size(ofValue: format))
        
        let result:OSStatus = AudioUnitGetProperty(
            fromUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            &formatSize
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error getting unit format", withStatus: result)
            return nil
        }
        
        return format
        
    }
    
    
    
    //MARK: deinit
    deinit {
        
        processingGraph = nil
        playerNodes = []
        pitchNodes = []
        mixerNode = 0
        remoteIoNode = 0
        sampleRate = 0
        
    }
    
}
