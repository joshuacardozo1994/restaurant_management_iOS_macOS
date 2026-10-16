//
//  Array+Extensions.swift
//  Durigo
//
//  Created by Joshua Cardozo on 21/01/24.
//

import Foundation

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
