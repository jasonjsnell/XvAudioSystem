//
//  AudioSessionManager.swift
//  Refraktions
//
//  Created by Jason Snell on 2/11/17.
//  Copyright © 2017 Jason J. Snell. All rights reserved.
//

// class to handle setup, vars, and changes with the AVAudioSession

import Foundation
import AVFoundation

class SessionManager:NSObject {

    //MARK: - VARS

    // iobuffer duration
    // default is     23ms @ 44.1kHz = 1024 samples per slice
    // fastest is 0.005 ms @ 44.1kHz = 256  samples per slice
    internal var ioBufferDuration:TimeInterval = 0.005
    
    let debug:Bool = false
    
    //MARK:- INIT -
    
    //singleton code
    static let sharedInstance = SessionManager()
    override init() {}
    
    internal func setup(){
        
        //MARK: Init AVAudioSession
        
        if (debug) { print("AUDIO SESSION: Init") }
        
        //init setssion
        let session:AVAudioSession = AVAudioSession.sharedInstance()
        
        // Request a hardware sample rate. The system may or may not be able to grant the request, depending on other audio activity on the device.
        
        do {
            try session.setPreferredSampleRate(Engine.sharedInstance.getSampleRate())
            
        } catch {
            
            print("AUDIO SESSION: Error setting preferred hardware sample rate.")
            return
        }
        
        // Request the audio session category
        do {
            try session.setCategory(AVAudioSessionCategoryPlayback, with: .mixWithOthers)
            
        } catch {
            
            print("AUDIO SESSION: Could not set session category")
            return
        }
        
        // Request activation of your audio session
        do {
            try session.setActive(true)
            
        } catch {
            
            print("AUDIO SESSION: Could not activate session.")
            return
        }
        
        // Update sample rate var according to the actual sample rate provided by the system and store it for later use in the audio processing graph.
        
        Engine.sharedInstance.set(sampleRate: session.sampleRate)
        
        if (debug) {print("AUDIO SESSION: Hardware sample rate =", session.sampleRate) }
        
        /*
        do {
            try session.setPreferredIOBufferDuration(ioBufferDuration)
            
        } catch {
            
            print("AUDIO SESSION: Could not set preferred IOBuffer")
            return
        }
        */
        
        
        //MARK: Add listeners
        
        // Register interruption handler
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(SessionManager.handleSessionInterruption(notification:)),
            name: NSNotification.Name.AVAudioSessionInterruption,
            object: session)
        
    }
   
    
    //MARK: - LISTENERS -
        
    //MARK: Session interruption
    func handleSessionInterruption(notification: NSNotification) {
        
        if (debug) { print("AUDIO SESSION: Interruption notification") }
        
        //get interruption phase (began or ended) from its type key
        let interruptionType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as! UInt
        
        if (interruptionType == AVAudioSessionInterruptionType.began.rawValue) {
            
            // interruption began
            
            if (debug) { print("AUDIO SESSION: Interruption began notification") }
            
            XvAudioSystem.sharedInstance.beginInterruption()
            
        } else if (interruptionType == AVAudioSessionInterruptionType.ended.rawValue) {
            
            // interruption ended
            
            if (debug) { print("AUDIO SESSION: Interruption ended notification") }
            
            
            let interruptionOption = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as! UInt
            if interruptionOption == AVAudioSessionInterruptionOptions.shouldResume.rawValue {
                
                // resume if needed
                if (debug) { print("AUDIO SESSION: Session should resume") }
                XvAudioSystem.sharedInstance.endInterruption()
                
            }
        }
        
    }
    
        
    
}
