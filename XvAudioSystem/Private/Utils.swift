//
//  AudioMixerUtils.swift
//  Refraktions
//
//  Created by Jason Snell on 2/11/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

/*
 
 */

import Foundation
import CoreAudio


class Utils {
    
    init(){}
    
    //MARK: - NOTIFICATIONS
    class func postNotification(name:String, userInfo:[AnyHashable : Any]?){
        
        NotificationCenter.default.post(
            name: Notification.Name(name),
            object: nil,
            userInfo: userInfo)
        
    }
    
    //MARK: CHAR CONVERSTION
    class func fourCharCodeFrom(string : String) -> FourCharCode {
        assert(string.count == 4, "String length must be 4")
        var result : FourCharCode = 0
        for char in string.utf16 {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
    
    //MARK: - PRINTING
    class func printErrorMessage(errorString: String, withStatus result: OSStatus) {
        print(errorString, result)
    }
    
    //print desc in readable lines
    class func printASBD(asbd: AudioStreamBasicDescription) {
        
        print("  Format ID:           ",    asbd.mFormatID)
        print("  Format Flags:        ",    asbd.mFormatFlags)
        print("  Bytes per Packet:    ",    asbd.mBytesPerPacket)
        print("  Frames per Packet:   ",    asbd.mFramesPerPacket)
        print("  Bytes per Frame:     ",    asbd.mBytesPerFrame)
        print("  Channels per Frame:  ",    asbd.mChannelsPerFrame)
        print("  Bits per Channel:    ",    asbd.mBitsPerChannel)
        print("  Sample Rate:         ",    asbd.mSampleRate)
    }
}
