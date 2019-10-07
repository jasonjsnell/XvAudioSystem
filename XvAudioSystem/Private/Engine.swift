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
    
    //grab var for reference
    let hostCallbackInfo:HostCallbackInfo = Engine.sharedInstance.hostCallbackInfo
    
    //if hostUserData is not nil, it means hostCallbackInfo has successfully been init'd
    if (hostCallbackInfo.hostUserData != nil){
        
        //init vars
        var outIsPlaying:DarwinBoolean = false
        var outCurrentSampleInTimeLine:Float64 = 0
        
        /*call transport state proc 2
        pass in host user data (probably to let it know which host it is)
        outIsPlaying is whether host is currently playing or not
        outCurrentSampleInTimeline is a number showing how long the play button has been running
        If it's negative, the rewind button has been pressed during playback
         If it's 0, the rewind button has been pressed
         */
        
        let result = hostCallbackInfo.transportStateProc2!(
            hostCallbackInfo.hostUserData,
            &outIsPlaying,
            nil, //outIsRecording
            nil,
            &outCurrentSampleInTimeLine,
            nil,
            nil,
            nil)
        
        //if result is nil, it means there is no host, or host data is inaccessible
        if (result == noErr){
            
            //grab var for ref
            let hostIsPlaying:Bool = Engine.sharedInstance.hostIsPlaying
            
            //if host var is false and transport isPlaying is true
            if (!hostIsPlaying && outIsPlaying.boolValue){
                
                //update var
                Engine.sharedInstance.hostIsPlaying = true
                
                //post notification that playback has started
                Utils.postNotification(
                    name: XvAudioConstants.kXvAudioHostPlayButtonPressed,
                    userInfo: nil)
                
            } else if (hostIsPlaying && !outIsPlaying.boolValue){
                
                Engine.sharedInstance.hostIsPlaying = false
                
                //post notification that playback has started
                Utils.postNotification(
                    name: XvAudioConstants.kXvAudioHostPauseButtonPressed,
                    userInfo: nil)
            }
        }
    }
    
    //system is using a timer for rendering, not this
    //Utils.postNotification(name: XvAudioConstants.kXvAudioGraphRender, userInfo: nil)
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
    
    //host call back info
    fileprivate var hostCallbackInfo:HostCallbackInfo = HostCallbackInfo()
    fileprivate var hostIsPlaying:Bool = false
    
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
        
        
        if (!_isGraphRunning()){
            
            if (debug) { print("AUDIO ENGINE: Start engine") }
            
            var result:OSStatus? = AUGraphStart(processingGraph!)
            
            if (result == nil){ print("AUDIO ENGINE: nil result during startEngine") }
            
            if (result != noErr){
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error starting engine", withStatus: result!)
            }
            result  = nil
        
        } else {
            
            if (debug) { print("AUDIO ENGINE: Engine already running") }
        }
        
    }
    
    //accessed by mixer during interruptions
    internal func stopEngine(){
        
        if (_isGraphRunning()){
            
            if (debug) { print("AUDIO ENGINE: Stop engine") }
            
            var result:OSStatus? = AUGraphStop(processingGraph!)
            
            if (result == nil){ print("AUDIO ENGINE: nil result during stopEngine") }
            
            if (result != noErr){
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error stopping engine", withStatus: result!)
            }
            result = nil
            
        } else {
            
            if (debug) { print("AUDIO ENGINE: Engine already stopped") }
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
        
        var result:OSStatus? = AUGraphAddRenderNotify(
            processingGraph!,
            renderCallback,
            selfAsUMRP
        )
        
        if (result == nil){ print("AUDIO ENGINE: nil result during addRenderNotification") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error adding render notification", withStatus: result!)
        }
        result = nil
    }
    
    internal func removeRenderNotification(){
        
        let selfAsURP = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let selfAsUMRP = UnsafeMutableRawPointer(mutating:selfAsURP)
        
        var result:OSStatus? = AUGraphRemoveRenderNotify(
            processingGraph!,
            renderCallback,
            selfAsUMRP
        )
        
        if (result == nil){ print("AUDIO ENGINE: nil result during removeRenderNotification") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error removing render notification", withStatus: result!)
        }
        result = nil
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
        
        //add render notication (used in IAA host callback, which detects transport changes
        addRenderNotification()
        
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
    //called by audio system and result passed to Audiobus for its init
    internal func getRemoteIoUnit() -> AudioUnit? {
       
        //make local remoteIoUnit
        if let _remoteIoUnit:AudioUnit = _makeRemoteIoUnit() {
            
            //create host callback info from remoteIo unit
            if let _hostCallbackInfo:HostCallbackInfo = _getHostCallbackInfo(fromUnit: _remoteIoUnit) {
                
                //store, to access later in render callback
                hostCallbackInfo = _hostCallbackInfo
            }
            
            //return unit to caller
            return _remoteIoUnit
        }
        
        return nil
        //return _makeRemoteIoUnit()
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
        
        var result:OSStatus? = NewAUGraph(&processingGraph)
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _makeNewGraph") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error creating graph", withStatus: result!)
        }
        result = nil
    }
    
    fileprivate func _openGraph(){
        
        if (debug) { print("AUDIO ENGINE: Open graph") }
        
        var result:OSStatus? = AUGraphOpen(processingGraph!)
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _openGraph") }
        
        if (result! != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error opening graph", withStatus: result!)
        }
        result = nil
    }
    
    fileprivate func _startGraph(){
        
        if (debug) { print("AUDIO ENGINE: Init and start graph") }
        
        // Diagnostic: Call CAShow if you want to look at the state of the audio processing graph
        
        if (debug) { CAShow(UnsafeMutablePointer(processingGraph!)) }
        
        // init graph
        // configures audio data stream formats for each input and output
        // validates connections between audio units
        
        var result:OSStatus? = AUGraphInitialize(processingGraph!)
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _startGraph") }
        
        if (result! != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error initializing graph", withStatus: result!)
        }
        result = nil
        
        // start graph
        if (debug) { print("AUDIO ENGINE: Start") }
        startEngine()
        
    }
    
    fileprivate func _isGraphRunning() -> Bool {
        
        var isGraphRunning:DarwinBoolean = DarwinBoolean(false)
        
        var result:OSStatus? = AUGraphIsRunning(processingGraph!, &isGraphRunning)
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _isGraphRunning") }
        
        if (result! != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error seeing if engine is runing", withStatus: result!)
        }
        result = nil
        
        return isGraphRunning.boolValue
    }

    //MARK: Nodes
    fileprivate func makeNode(withDescription:AudioComponentDescription) -> AUNode {
        
        //if (debug) { print("AUDIO ENGINE: Make node") }
        
        var _node:AUNode = 0
        var _desc:AudioComponentDescription = withDescription
        
        var result:OSStatus? = AUGraphAddNode(
            processingGraph!,
            &_desc,
            &_node)
        
        if (result == nil){ print("AUDIO ENGINE: nil result during makeNode") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error adding I/O node", withStatus: result!)
            result = nil
            return 0
        }
        
        result = nil
        return _node
        
    }
    
    fileprivate func _connect(sourceNode:AUNode, sourceBus:UInt32, destinationNode:AUNode, destinationBus:UInt32) {
        
        var result:OSStatus? = AUGraphConnectNodeInput (
            processingGraph!,
            sourceNode,         // source node
            sourceBus,          // source node output bus number
            destinationNode,    // destination node
            destinationBus      // desintation node input bus number
        )
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _connect") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error nodes", withStatus: result!)
        }
        result = nil
        
    }
    
    
    
    //MARK: Units
    fileprivate func _makeUnit(inNode:AUNode) -> AudioUnit? {
        
        // if (debug) { print("AUDIO ENGINE: Make unit") }
        
        var unit:AudioUnit? = nil
        
        var result:OSStatus? = AUGraphNodeInfo(
            processingGraph!,
            inNode,
            nil,
            &unit
        )
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _makeUnit") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error making unit", withStatus: result!)
            result = nil
            return nil
        }
        
        //every audio unit needs to have a 4096 max fps in order to continue playing when the screen is locked
        //https://developer.apple.com/library/content/qa/qa1606/_index.html
        
        var maximumFramesPerSlice: UInt32 = 4096
        
        result = AudioUnitSetProperty(
            unit!,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFramesPerSlice,
            UInt32(MemoryLayout.size(ofValue: maximumFramesPerSlice))
        )
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting maximum fps", withStatus: result!)
            result = nil
            return nil
        }
        
        result = nil
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
        
        var result:OSStatus? = noErr
        
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
            
            if (result == nil){ print("AUDIO ENGINE: nil result during _makeMixerUnit set channel count") }
            
            if (result != noErr){
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting mixer's channel count", withStatus: result!)
                result = nil
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
            
            if (result == nil){ print("AUDIO ENGINE: nil result during _makeMixerUnit set sample rate") }
            
            if (result != noErr){
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting mixer's sample rate", withStatus: result!)
                result = nil
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
            
            if (result == nil){ print("AUDIO ENGINE: nil result during _makeMixerUnit set volume") }
            
            if (result != noErr){
                Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting mixer's volume", withStatus: result!)
                result = nil
                return nil
            }
            
            result = nil
            
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
        
        var result:OSStatus? = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            inScope,
            inElement,
            &_format,
            UInt32(MemoryLayout.size(ofValue: _format))
        )
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _set", withFormat) }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error setting stream format", withStatus: result!)
        }
        result = nil
        
    }
    
    
    fileprivate func _getFormat(fromUnit:AudioUnit) -> AudioStreamBasicDescription? {
        
        //if (debug) { print("AUDIO ENGINE: Get format") }
        
        var format:AudioStreamBasicDescription = AudioStreamBasicDescription()
        var formatSize:UInt32 = UInt32(MemoryLayout.size(ofValue: format))
        
        var result:OSStatus? = AudioUnitGetProperty(
            fromUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            &formatSize
        )
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _getFormat") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error getting unit format", withStatus: result!)
            result = nil
            return nil
        }
        
        result = nil
        return format
        
    }
    
    //MARK: Host callback info
    fileprivate func _getHostCallbackInfo(fromUnit:AudioUnit) -> HostCallbackInfo? {
        
        //https://forum.juce.com/t/audiobus/10717/35
        var hostCallbackInfo:HostCallbackInfo = HostCallbackInfo()
        var hostCallbackInfoSize:UInt32 = UInt32(MemoryLayout.size(ofValue: hostCallbackInfo))
        
        var result:OSStatus? = AudioUnitGetProperty(
            fromUnit,
            kAudioUnitProperty_HostCallbacks,
            kAudioUnitScope_Global,
            0,
            &hostCallbackInfo,
            &hostCallbackInfoSize
        )
        
        if (result == nil){ print("AUDIO ENGINE: nil result during _getHostCallbackInfo") }
        
        if (result != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error getting host callback info", withStatus: result!)
            result = nil
            return nil
        }
        
        result = nil
        return hostCallbackInfo
    }
    
    
    
    //MARK: deinit
    deinit {
        
        var result:OSStatus? = AUGraphUninitialize(processingGraph!)
        
        if (result == nil){ print("AUDIO ENGINE: nil result during uninitialize graph") }
        
        if (result! != noErr){
            Utils.printErrorMessage(errorString: "AUDIO ENGINE: Error uninitializing graph", withStatus: result!)
        }
        result = nil
        
        processingGraph = nil
        playerNodes = []
        pitchNodes = []
        mixerNode = 0
        remoteIoNode = 0
        sampleRate = 0
        
    }
    
}
