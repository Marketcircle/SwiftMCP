//
//  MCPAppShortcutsProvider.swift
//  SwiftMCP
//
//  Created by Oliver Drobnik on 19.03.25.
//

#if canImport(AppIntents)
import AppIntents

/// Typealias used by macros to avoid requiring AppIntents imports at expansion sites.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public typealias MCPAppShortcutsProvider = AppShortcutsProvider

/// Optional protocol for providing MCP-specific App Shortcuts.
///
/// Types that conform to both `AppShortcutsProvider` and this protocol can keep
/// system-facing `appShortcuts` separate from the shortcuts SwiftMCP exposes as
/// MCP tools.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public protocol MCPAppIntentShortcutsProviding {
    static var mcpAppShortcuts: [AppShortcut] { get }
}
#else
/// Stub protocol for platforms without AppIntents support.
public protocol MCPAppShortcutsProvider {}

/// Stub protocol for platforms without AppIntents support.
public protocol MCPAppIntentShortcutsProviding {}
#endif
