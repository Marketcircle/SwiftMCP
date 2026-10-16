//
//  String+ConstantTime.swift
//  SwiftMCP
//
//  Created by Ilyas Yurdaon on 16.10.26.
//

import Foundation

extension String {
    /// Returns whether the strings hold the same UTF-8 bytes, checking every byte.
    func constantTimeEquals(_ other: String) -> Bool {
        let bytes = Array(utf8)
        let otherBytes = Array(other.utf8)
        guard bytes.count == otherBytes.count else { return false }
        var difference: UInt8 = 0
        for index in bytes.indices {
            difference |= bytes[index] ^ otherBytes[index]
        }
        return difference == 0
    }
}
