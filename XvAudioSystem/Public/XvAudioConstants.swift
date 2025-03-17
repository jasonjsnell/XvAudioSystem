//
//  XvAudioConstants.swift
//  XvAudioSystem
//
//  Created by Jason Snell on 3/7/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

import Foundation

public class XvAudioConstants {
    public static let kXvAudioPlaybackSuccess:String = "kXvAudioPlaybackSuccess"
    //public static let kXvAudioGraphRender:String = "kXvAudioGraphRender" //system is using a timer for rendering, not this
    
    //transport notifications from host application like AUM
    public static let kXvAudioHostPlayButtonPressed:String = "kXvAudioHostPlayButtonPressed"
    public static let kXvAudioHostPauseButtonPressed:String = "kXvAudioHostPauseButtonPressed"
    
    public static let kXvPitchModeTimePitch:String = "kXvPitchModeTimePitch"
    public static let kXvPitchModeVarispeed:String = "kXvPitchModeVarispeed"
    
}

