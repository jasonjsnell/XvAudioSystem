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
    
    //MARK: MUSICAL NOTATION
    class func midiNoteNumber(from note: String) -> Int? {
        let noteMap: [String: Int] = [
            "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3,
            "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8,
            "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11
        ]
        
        var letterPart = ""
        var octavePart = ""
        for char in note {
            if char.isLetter || char == "#" || char == "b" {
                letterPart.append(char)
            } else if char.isNumber {
                octavePart.append(char)
            }
        }
        
        guard let semitone = noteMap[letterPart], let octave = Int(octavePart) else {
            return nil
        }
        
        return (octave + 1) * 12 + semitone
    }
    
    //use with AVAudioUnitTimePitch
    class func pitchShiftCents(target: String, base: String = "C3") -> Float? {
        guard let targetMidi = midiNoteNumber(from: target),
              let baseMidi = midiNoteNumber(from: base) else {
            return nil
        }
        return Float(targetMidi - baseMidi) * 100.0
    }
    
    //use with AVAudioUnitVarispeed
    class func varispeedRate(target: String, base: String = "C3") -> Float? {
        guard let targetMidi = midiNoteNumber(from: target),
              let baseMidi = midiNoteNumber(from: base) else {
            return nil
        }
        return pow(2.0, Float(targetMidi - baseMidi) / 12.0)
    }

}
