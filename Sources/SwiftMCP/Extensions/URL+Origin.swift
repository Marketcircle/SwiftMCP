//
//  URL+Origin.swift
//  SwiftMCP
//
//  Created by Ilyas Yurdaon on 16.10.26.
//

import Foundation

extension URL {
    /// Returns whether this URL and the given one share a scheme, host, and port, with a missing port read as the scheme's default.
    func hasSameOrigin(as other: URL) -> Bool {
        guard let host = host?.lowercased(), let otherHost = other.host?.lowercased() else {
            return false
        }
        return scheme?.lowercased() == other.scheme?.lowercased()
            && host == otherHost
            && effectivePort == other.effectivePort
    }

    /// The URL's port, or the default port of its scheme when it names none.
    private var effectivePort: Int? {
        if let port {
            return port
        }
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
