//
//  Item.swift
//  Savior
//
//  Created by Benji on 2026-10-15.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
