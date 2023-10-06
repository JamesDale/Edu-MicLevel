//
//  CapturedAudioLevel.swift
//  MicLevel
//
//  Created by James Dale on 6/10/2023.
//

import Foundation

struct CapturedAudioLevel: Identifiable {
    
    var id: Date {
        timestamp
    }
    
    var timestamp: Date
    var level: Float
    
}
