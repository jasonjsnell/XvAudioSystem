//
//  AudioChannel.swift
//  Refraktions
//
//  Created by Jason Snell on 2/17/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

import Foundation
import CoreAudio
import AudioToolbox

//workaround for ScheduledAudioFileRegion init bug


struct PatchedScheduledAudioFileRegion {
    public var mTimeStamp: AudioTimeStamp
    public var mCompletionProc: ScheduledAudioFileRegionCompletionProc?
    public var mCompletionProcUserData: UnsafeMutableRawPointer?
    public var mAudioFile: OpaquePointer?
    public var mLoopCount: UInt32
    public var mStartFrame: Int64
    public var mFramesToPlay: UInt32
}


class Channel {
    
    
    //MARK: - VARS -
    internal var busNum:Int = 0
    
    fileprivate var playerUnit:AudioUnit? = nil
    fileprivate var pitchUnit:AudioUnit? = nil
    
    fileprivate var audioFile:AudioFileID? = nil
    fileprivate var endFrame:UInt32 = 0
    
    fileprivate let debug:Bool = false
    
    //MARK: - INIT -
    init(){
        
        if (debug) { print("AUDIO CHANNEL:",busNum,"Init channel") }

    }
    
    convenience init(withBusNum:Int, withPlayerUnit:AudioUnit, withPitchUnit:AudioUnit){
        
        self.init()
        
        busNum = withBusNum
        playerUnit = withPlayerUnit
        pitchUnit = withPitchUnit
        
    }
    
    //MARK: - AVAILABLE? -
    //called by mixer when looking for an open channel
    internal func isAvailable() -> Bool {
        
        //get the current frame
        let currFrame:UInt32  = _getCurrentFrame()
        
        // if curr and end frames are zero
        // channel has not been used or has been reset
        // and is available
        
        if (currFrame == 0 && endFrame == 0){
            if (debug) { print("AUDIO CHANNEL:", busNum,"At", currFrame,"of", endFrame, "<-- Avail") }
            return true
        
        //if curr frame is beyond the end frame, then sound is done playing
        } else if (currFrame > endFrame){
            
            // try to reset audio player and close the file
            var closeSuccess:Bool = false
            closeSuccess = _resetAudioPlayer()
            closeSuccess = _closeFile()
            if (debug) { print("AUDIO CHANNEL:", busNum,"At", currFrame,"of", endFrame, "?", closeSuccess) }
            if (closeSuccess){
                endFrame = 0
            }
            return closeSuccess
            
        } else {
            //sound is still playing
            if (debug) { print("AUDIO CHANNEL:", busNum,"At", currFrame,"of", endFrame) }
            return false
        }
        
    }
    
   //MARK: - PLAY -
    internal func play(name:String, fileExtension:String, pitch:Float) -> Bool {
        
        var success:Bool = false
        
        //reset player
        success = _resetAudioPlayer()
        if (debug) { print("AUDIO CHANNEL: Reset player before play", success) }
        
        //sets pitch on the sound that's just in this channel
        success =  _set(pitch:pitch)
        if (debug) { print("AUDIO CHANNEL: Set pitch", success) }
        
        //load the file
        audioFile = _load(name:name, fileExtension:fileExtension)
            
        if (audioFile != nil) {
            
            //grab its format
            if let fileAudioFormat:AudioStreamBasicDescription = _getFormat() {
                
                //grab data packets
                if let packets:UInt64 = _getPackets() {
                    
                    //set end frame
                    endFrame = UInt32(packets) * fileAudioFormat.mFramesPerPacket
                    
                    //init and play player
                    if _initPlayer() {
                        
                        success = _startPlayer()
                        if (debug) { print("AUDIO CHANNEL: Start playback", success) }
                    
                    }
                }
                
            }
            
        }
        
        return success
        
    }
    
    //MARK: - HELPER SUB FUNCTIONS -

    
    //MARK: PLAYER
    
    fileprivate func _initPlayer() -> Bool {
        
        if var _audioFile:AudioFileID = audioFile {
            
            //load file into player
            var result:OSStatus = AudioUnitSetProperty(
                playerUnit!,
                kAudioUnitProperty_ScheduledFileIDs,
                kAudioUnitScope_Global,
                0,
                &_audioFile,
                UInt32(MemoryLayout.size(ofValue: _audioFile))
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO CHANNEL: Error setting audio file scheduled IDs", withStatus: result)
                return false
            }
            
            //get time stamp zero
            var regionTimeStamp:AudioTimeStamp = AudioTimeStamp()
            regionTimeStamp.mFlags = AudioTimeStampFlags.sampleTimeValid
            regionTimeStamp.mSampleTime = 0
            
            //init region zero
            var region = PatchedScheduledAudioFileRegion(
                mTimeStamp: regionTimeStamp,
                mCompletionProc: nil,
                mCompletionProcUserData: nil,
                mAudioFile: audioFile,
                mLoopCount: 0,
                mStartFrame: 0,
                mFramesToPlay: endFrame
            )
            
            //set the region
            result = AudioUnitSetProperty(
                playerUnit!,
                kAudioUnitProperty_ScheduledFileRegion,
                kAudioUnitScope_Global,
                0,
                &region,
                UInt32(MemoryLayout.size(ofValue: region))
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO CHANNEL: Error setting file region", withStatus: result)
                return false
            }
            
            // set prime to zero
            var defaultVal:UInt32 = 0
            
            result = AudioUnitSetProperty(
                playerUnit!,
                kAudioUnitProperty_ScheduledFilePrime,
                kAudioUnitScope_Global,
                0,
                &defaultVal,
                UInt32(MemoryLayout.size(ofValue: defaultVal))
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(errorString: "AUDIO CHANNEL: Error setting file prime", withStatus: result)
                return false
            }
            
            return true
            
        } else {
            print("AUDIO CHANNEL:",busNum,"Error invalid file init player")
            return false
        }
        
        
        
    }
    
    /*
    ABSendPortSend
     * @param senderPort        Sender port.
     * @param audio             Audio buffer list to send, in the @link clientFormat client format @endlink.
     * @param lengthInFrames    Length of the audio, in frames.
     * @param timestamp         The timestamp of the audio.
     
     */
    
    fileprivate func _startPlayer() -> Bool{
        
        // tell player when to start playing (-1 sample time means next render cycle)
        
        var startTime:AudioTimeStamp = AudioTimeStamp()
        startTime.mFlags = AudioTimeStampFlags.sampleTimeValid
        startTime.mSampleTime = -1
        
        let result:OSStatus = AudioUnitSetProperty(
            playerUnit!,
            kAudioUnitProperty_ScheduleStartTimeStamp,
            kAudioUnitScope_Global,
            0,
            &startTime,
            UInt32(MemoryLayout.size(ofValue: startTime))
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO CHANNEL: Error setting scheduled file prime", withStatus: result)
            return false
        }
        
        return true
        
    }

    
    
    
    
    fileprivate func _resetAudioPlayer() -> Bool {
        
        let result = AudioUnitReset(playerUnit!, kAudioUnitScope_Global, 0)
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO CHANNEL: Error resetting audio player", withStatus: result)
            return false //audio player experienced error during reset
        }
        
        if (debug) { print("AUDIO CHANNEL:",busNum,"Reset successful, is available") }
        
        return true // audio player successfully reset
    }
    
    
    fileprivate func _getCurrentFrame() -> UInt32 {
        
        //get the current timestamp
        var currTimeStamp:AudioTimeStamp = AudioTimeStamp()
        var currTimeStampSize = UInt32(MemoryLayout.stride(ofValue: currTimeStamp))
        
        let result = AudioUnitGetProperty(
            playerUnit!,
            kAudioUnitProperty_CurrentPlayTime,
            kAudioUnitScope_Global,
            0,
            &currTimeStamp,
            &currTimeStampSize
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO CHANNEL: Error getting curr time stamp", withStatus: result)
            return 0
        }
        
        var frame:UInt32 = 0
        if (currTimeStamp.mSampleTime > 0){
            frame = UInt32(currTimeStamp.mSampleTime)
        }
        
        return frame
        
    }
    
    
    
    //MARK: AUDIO FILE
    
    fileprivate func _load(name:String, fileExtension:String) -> AudioFileID? {
        
        var _audioFile:AudioFileID? = nil
        
        if let fileUrl:URL = Bundle.main.url(
            forResource: name,
            withExtension: fileExtension) {
            
            let fileNsUrl:NSURL = fileUrl as NSURL
            
            // Open an audio file and associate it with the extended audio file object.
            let result:OSStatus = AudioFileOpenURL(
                fileNsUrl,
                AudioFilePermissions.readPermission,
                0, //kAudioFileWAVEType
                &_audioFile)
            
            
            guard result == noErr else {
                Utils.printErrorMessage(
                    errorString: "AUDIO CHANNEL: Error during AudioFileOpenURL for \(name).\(fileExtension)",
                    withStatus: result)
                return nil
            }
            
        } else {
            print("AUDIO CHANNEL:", busNum, "Invalid URL for sound file \(name).\(fileExtension)")
            return nil
        }
        
        return _audioFile
        
    }

    fileprivate func _closeFile() -> Bool {
        
        if (debug) { print("AUDIO CHANNEL:",busNum,"Closeing file") }
        
        if let _audioFile:AudioFileID = audioFile {
            
            let result:OSStatus = AudioFileClose(_audioFile)
                
            guard result == noErr else {
                Utils.printErrorMessage(
                    errorString: "AUDIO CHANNEL: Error during AudioFileClose", withStatus: result)
                return false
            }
            
            audioFile = nil

            return true
            
        } else {
            if (debug) { print("AUDIO CHANNEL:",busNum,"File already nil when trying to close file") }
            return false
        }
        
    }

    
    fileprivate func _getFormat() -> AudioStreamBasicDescription? {
        
        if let _audioFile:AudioFileID = audioFile {
            
            var fileAudioFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
            var fileAudioFormatSize = UInt32(MemoryLayout.stride(ofValue: fileAudioFormat))
            
            let result:OSStatus = AudioFileGetProperty(
                _audioFile,
                kAudioFilePropertyDataFormat,
                &fileAudioFormatSize,
                &fileAudioFormat
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(
                    errorString: "AUDIO CHANNEL: Error getting file audio format", withStatus: result)
                return nil
            }
            
            return fileAudioFormat
            
        } else {
            print("AUDIO CHANNEL:",busNum,"Error invalid file when getting file format")
            return nil
        }
        
    }
    
    fileprivate func _getPackets() -> UInt64? {
        
        if let _audioFile:AudioFileID = audioFile {
            
            var packets: UInt64 = 0
            var packetsSize = UInt32(MemoryLayout.stride(ofValue: packets))
            
            let result:OSStatus = AudioFileGetProperty(
                _audioFile,
                kAudioFilePropertyAudioDataPacketCount,
                &packetsSize,
                &packets
            )
            
            guard result == noErr else {
                Utils.printErrorMessage(
                    errorString: "AUDIO CHANNEL: Error getting data packet count", withStatus: result)
                return nil
            }
            
            return packets
            
        } else {
            print("AUDIO CHANNEL:",busNum,"Error invalid file when getting packets")
            return nil
        }
        
    }
    
    //MARK: PITCH
    
    fileprivate func _set(pitch:Float) -> Bool{
        
        let result:OSStatus = AudioUnitSetParameter(
            pitchUnit!,
            kNewTimePitchParam_Pitch,
            kAudioUnitScope_Global,
            0,
            pitch,
            0
        )
        
        guard result == noErr else {
            Utils.printErrorMessage(errorString: "AUDIO CHANNEL: Error setting pitch", withStatus: result)
            return false
        }
        
        return true
        
    }

    
    
    //MARK: DEINIT
    
    internal func reset(){
        let _:Bool = _resetAudioPlayer()
        let _:Bool = _closeFile()
        endFrame = 0
    }
    
    deinit {
        let _:Bool = _resetAudioPlayer()
        endFrame = 0
        playerUnit = nil
        pitchUnit = nil
    }
    
}

