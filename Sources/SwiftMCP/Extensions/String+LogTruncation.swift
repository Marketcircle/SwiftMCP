//
//  String+LogTruncation.swift
//  SwiftMCP
//
//  Created by Ilyas Yurdaon on 16.10.26.
//

import Foundation

extension String {
    /// The most characters of a message payload that a log line shows.
    static let loggedPayloadLimit = 200

    /// The string cut to ``loggedPayloadLimit`` characters, followed by the number of characters left out.
    var truncatedForLog: String {
        guard count > Self.loggedPayloadLimit else { return self }
        return "\(prefix(Self.loggedPayloadLimit))… (\(count - Self.loggedPayloadLimit) more characters)"
    }
}
