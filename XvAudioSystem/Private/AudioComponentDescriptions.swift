//
//  AudioComponentDescriptions.swift
//  Refraktions
//
//  Created by Jason Snell on 2/16/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

import Foundation
import AudioToolbox

class AudioComponentDescriptions {
    
    class func getPlayerDescription() -> AudioComponentDescription {
        
        return AudioComponentDescription(
            componentType: kAudioUnitType_Generator,
            componentSubType: kAudioUnitSubType_AudioFilePlayer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        
    }
    
    class func getMixerDescription() -> AudioComponentDescription {
    
        return AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_MultiChannelMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
    
    }
    
    class func getPitchFxDescription() -> AudioComponentDescription {
        
        return AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter,
            componentSubType: kAudioUnitSubType_Varispeed,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        
    }
    
    class func getRemoteIoDescription() -> AudioComponentDescription {
        
        return AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
    }
    
    class func getGenericOutputDescription() -> AudioComponentDescription {
        
        return AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_GenericOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
    }
    
}
