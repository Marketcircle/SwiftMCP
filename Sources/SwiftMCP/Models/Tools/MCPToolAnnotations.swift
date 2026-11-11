//
//  MCPToolAnnotations.swift
//  SwiftMCP
//
//  Created by Orbit on 02.02.26.
//

import Foundation

/// Annotations for MCP tools providing hints about tool behavior (per MCP spec).
///
/// These annotations are optional hints that help clients understand tool behavior.
/// Use the OptionSet-based API for cleaner syntax, and the Boolean initializer
/// to set a hint to false, such as `MCPToolAnnotations(openWorldHint: false)`.
///
/// Example usage:
/// ```swift
/// @MCPTool(hints: [.readOnly])
/// func search(query: String) -> [Result]
///
/// @MCPTool(hints: [.destructive, .openWorld])
/// func deleteAccount(id: String) -> Bool
/// ```
public struct MCPToolAnnotations: Sendable, Equatable, Codable {
    /// A Boolean value indicating whether the tool only reads its environment, or nil when unset.
    public let readOnlyHint: Bool?

    /// A Boolean value indicating whether the tool may perform destructive updates, or nil when unset.
    public let destructiveHint: Bool?

    /// A Boolean value indicating whether repeat calls with the same arguments have no further effect, or nil when unset.
    public let idempotentHint: Bool?

    /// A Boolean value indicating whether the tool may interact with external entities, or nil when unset.
    public let openWorldHint: Bool?

    /// Creates annotations from an OptionSet of hints, with a Boolean for each hint the set leaves out.
    public init(
        hints: MCPToolHints,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.init(
            readOnlyHint: hints.contains(.readOnly) ? true : readOnlyHint,
            destructiveHint: hints.contains(.destructive) ? true : destructiveHint,
            idempotentHint: hints.contains(.idempotent) ? true : idempotentHint,
            openWorldHint: hints.contains(.openWorld) ? true : openWorldHint
        )
    }

    /// Creates annotations from one optional Boolean per hint.
    public init(
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    /// The hints set to true.
    public var hints: MCPToolHints {
        var hints = MCPToolHints()
        if readOnlyHint == true { hints.insert(.readOnly) }
        if destructiveHint == true { hints.insert(.destructive) }
        if idempotentHint == true { hints.insert(.idempotent) }
        if openWorldHint == true { hints.insert(.openWorld) }
        return hints
    }

    /// Returns true if no hints are set
    public var isEmpty: Bool {
        readOnlyHint == nil && destructiveHint == nil && idempotentHint == nil && openWorldHint == nil
    }
}

// MARK: - Factory Methods

extension MCPToolAnnotations {
    /// Creates annotations for a read-only tool
    public static var readOnly: MCPToolAnnotations {
        MCPToolAnnotations(hints: [.readOnly])
    }

    /// Creates annotations for a destructive tool
    public static var destructive: MCPToolAnnotations {
        MCPToolAnnotations(hints: [.destructive])
    }
}
