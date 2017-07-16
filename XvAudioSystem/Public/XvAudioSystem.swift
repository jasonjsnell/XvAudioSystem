//
//  AudioOutput.swift
//  Refraktions
//
//  Created by Jason Snell on 11/7/15.
//  Copyright © 2015 Jason J. Snell. All rights reserved.
//

/*
 Audio output / playback
 
 IN
 Sequencer
 
 OUT
 Audio to device's speakers
 
 NODE DESIGN
 
 Each channel has its own audio player and pitch so multiple sounds can play at once, and sounds can be pitched individually
 Each channel leads into its own input on the main mixer
 Main mixer output goes to remoteIO to sends signal to device speakers
 
 channel: player 0 > pitch unit >
 channel: player 1 > pitch unit > mixer > remote io
 channel: player 2 > pitch unit >
 
 v2?
 
 channel: player 0 > pitch unit >       > subgraph 1 > generic output 1 >
 channel: player 1 > pitch unit > mixer > subgraph 2 > generic output 2 > remoteIO
 channel: player 2 > pitch unit >       > subgraph 3 > generic output 3 >
 
 */


import Foundation
import AVFoundation
import AudioToolbox

public class XvAudioSystem{
    
    // MARK: - VARS -
    fileprivate var engine:Engine?
    
    //audio units
    fileprivate var mixerUnit:AudioUnit?
    fileprivate var remoteIoUnit:AudioUnit?
    
    //audio channels
    fileprivate var channels:[Channel] = []
    fileprivate var channelTotal:Int = 1
    
    //blocks output during app interruptions (phone calls, timers)
    internal var interruptionInProgress:Bool = false
    
    fileprivate let debug:Bool = true
    
    //MARK: - PUBLIC API -
    //singleton code
    public static let sharedInstance = XvAudioSystem()
    fileprivate init() {}
    
    public func setup(withChannelTotal:Int) -> AudioUnit? {
        
        if (debug) { print("AUDIO SYS: Init") }
        
        channelTotal = withChannelTotal
        
        //init
        SessionManager.sharedInstance.setup()
        
        //setup engine with channels
        engine = Engine.sharedInstance
        engine!.setup(withChannelTotal: withChannelTotal)
        
        //get array of player / pitch channels
        channels = engine!.getChannels()
        
        //get main mixer
        mixerUnit = engine!.getMixerUnit()
        
        //get remote IO unit
        remoteIoUnit = engine!.getRemoteIoUnit()
    
        //connect all the nodes (design above in header notes)
        engine!.connectNodes()
        
        //start engine
        engine!.start()
        
        return remoteIoUnit
        
    }
    
    //called by app delegate for audiobus fade out / shut down
    public func getRemoteIOAudioUnit() -> AudioUnit? {
        return remoteIoUnit
    }

    
    
    
    //MARK: - PLAYBACK
    public func playSound(name:String, volume:Float, pitch:Float, pan:Float) -> Bool{
        
        var success:Bool = false
        
         //MARK: interruption
         
         //block play if an interruption is ocurring (phone call, timer)
        if (interruptionInProgress){
            if (debug){
                print("AUDIO SYS: Playback blocked. Interruption in progress")
            }
            return false
        }
 
         //MARK: playback
        
        
        
        
         if let channel:Channel = getChannel() {
            
            success = _set(volume: volume, forBus: channel.busNum)
            success = _set(pan: pan, forBus: channel.busNum)
            
            if channel.play(name: name, fileExtension: "wav", pitch:pitch) {
                
                if (debug){
                    print("AUDIO SYS: Play sound \(name), volume:\(volume) pitch:\(pitch) pan:\(pan)")
                }
                
                Utils.postNotification(
                    name: XvAudioConstants.kXvAudioPlaybackSuccess,
                    userInfo: nil)
                
                
                success = true

            } else {
                print("AUDIO SYS: Error playing sound in channel")
            }
            
         } else {
            if (debug){ print("AUDIO SYS: All channels full, note blocked.") }
            success  = false
         }
    
         return success
        
    }
    
    //MARK: - CHANNEL ACCESS
    
    //called by audio system helper during playback success listener
    public func getPercentageOfBusyChannels() -> Int{
        
        //send mixer data to visual output
        
        let numberOfBusyChannels:Int = channelTotal - getNumberOfAvailableChannels()
        let percentageOfBusyChannels:Int = (100 * numberOfBusyChannels) / channelTotal
        
        return percentageOfBusyChannels
        
    }
    
    //queried by Note Creator to see if a new note can be added
    public func isChannelAvailable() -> Bool {
        
        if (debug) {
            print("AUDIO SYS: Query by note creator, any available channels?")
        }
        
        //if getChannel returns a channel, then there is at least 1 available channels
        //if not, they are all busy

        if let _:Channel = getChannel() {
            return true
        } else {
            return false
        }
        
    }
    
    
    
    //MARK: - INTERRUPTIONS
    
    //called by session manager and by app delegate when app becomes active
    public func endInterruption(){
        
        if (debug) { print("AUDIO SYS: End interruption") }
        
        interruptionInProgress = false
        
        //stop + start required to reboot engine
        if (engine != nil){
            
            engine!.stopEngine()
            engine!.startEngine()
            
        } else {
            print("AUDIO SYS: Error starting engine because it is nil")
        }
        
    }
    

    //MARK: - SHUTDOWN
    
    public func shutdown(){
        
        if (debug) { print("AUDIO SYS: shutdown") }
        
        
        //stop engine
        if (engine != nil){
            
            engine!.stopEngine()
            
        } else {
            print("AUDIO SYS: Error shutting down engine because it is nil")
        }
        
        //reset all the channels
        for channel in channels {
            channel.reset()
        }
        
    }
    
    //MARK: - DEBUGGING
    //status output called by Position class each Phrase during debug
    public func outputStatus(){
        
        let numberOfAvailableChannels:Int = getNumberOfAvailableChannels()
        
        print("AUDIO SYS: channels = \(numberOfAvailableChannels) avail / \(channels.count) total")
        
        
    }
    
    
    //MARK: - INTERNAL API -
    
    //MARK: INTERRUPTIONS
    
    //called from session manager
    internal func beginInterruption(){
        
        if (debug) { print("AUDIO SYS: Begin interruption") }
        
        interruptionInProgress = true
        
        //shutdown the audio in the channels, otherwise a crash occurs when the notes try to play
        shutdown()
        
    }
    

    
    //MARK: - PRIVATE API -
    
    //MARK: CHANNELS
    
    //get existing engine or if they are all busy, create new
    fileprivate func getChannel() -> Channel?{
        
        //look through all the channels for an available one
        
        for channel in channels {
            if (channel.isAvailable()){
                return channel
            }
            
        }
        
        //if none found, return nil
        return nil
        
    }
    
    //loop through the channels and tally up available channels
    fileprivate func getNumberOfAvailableChannels() -> Int{
        
        var numberOfAvailableChannels:Int = 0
        for channel in channels {
            if (channel.isAvailable()){
                numberOfAvailableChannels += 1
            }
        }
        
        if (debug) { print("AUDIO SYS: getNumberOfAvailableChannels", numberOfAvailableChannels) }
        
        return numberOfAvailableChannels
        
    }
    
    //MARK: - MAIN MIXER SETTERS
    
    fileprivate func _set(volume:Float, forBus:Int) -> Bool {
        
        let result:OSStatus = AudioUnitSetParameter(
            mixerUnit!,
            kMultiChannelMixerParam_Volume,
            kAudioUnitScope_Input,
            UInt32(forBus),
            volume,
            0
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO SYS: Error setting volume", withStatus: result)
            return false
        }

        return true
        
    }
    
    fileprivate func _set(pan:Float, forBus:Int) -> Bool {
        
        //set pan
        let result:OSStatus = AudioUnitSetParameter(
            mixerUnit!,
            kMultiChannelMixerParam_Pan,
            kAudioUnitScope_Input,
            UInt32(forBus),
            pan,
            0
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO SYS: Error setting pan", withStatus: result)
            return false
        }
        
        return true
        
    }
    
    //MARK: - DEINIT
    deinit {
        engine = nil
        mixerUnit = nil
        remoteIoUnit = nil
        channels = []
    }
    
}




/*
 
 //listeners
 http://hondrouthoughts.blogspot.com/2014/09/more-avaudioplayernode-with-swift-and.html
 
 //effects
 https://github.com/genedelisa/AVFoundationEngineFrobs/blob/master/AvFoundationEngineFrobs/ViewController.swift
 
 https://www.safaribooksonline.com/library/view/ios-swift-game/9781491920794/ch04.html
 
 http://swift4javaguys.blogspot.com/2015/01/udacitys-pitch-perfect-rate-and-pitch.html
 
 http://www.rockhoppertech.com/blog/swift-avfoundation/
 
 https://developer.apple.com/library/ios/documentation/AVFoundation/Reference/AVAudioPlayerClassReference/
 
 http://stackoverflow.com/questions/25704923/using-apples-new-audioengine-to-change-pitch-of-audioplayer-sound
 
 //easy to read
 http://mhorga.org/2015/07/09/audio-processing-with-avfoundation.html
 
 */

