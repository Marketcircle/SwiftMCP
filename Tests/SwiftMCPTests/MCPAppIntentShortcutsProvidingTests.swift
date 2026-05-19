#if canImport(AppIntents)
import AppIntents
import Testing
@testable import SwiftMCP

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct PublicShortcutIntent: AppIntent, MCPAppIntentTool {
    static let title: LocalizedStringResource = "Public Shortcut"

    static let mcpToolMetadata = MCPToolMetadata(
        name: "publicShortcut",
        parameters: []
    )

    static func mcpPerform(arguments: JSONDictionary) async throws -> (Encodable & Sendable) {
        "public"
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct MCPOnlyShortcutIntent: AppIntent, MCPAppIntentTool {
    static let title: LocalizedStringResource = "MCP Only Shortcut"

    static let mcpToolMetadata = MCPToolMetadata(
        name: "mcpOnlyShortcut",
        parameters: []
    )

    static func mcpPerform(arguments: JSONDictionary) async throws -> (Encodable & Sendable) {
        "mcp"
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct TestShortcutsProvider: AppShortcutsProvider, MCPAppIntentShortcutsProviding {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PublicShortcutIntent(),
            phrases: ["Run public shortcut in \(.applicationName)"],
            shortTitle: "Public",
            systemImageName: "square"
        )
    }

    static var mcpAppShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: MCPOnlyShortcutIntent(),
                phrases: ["Run MCP only shortcut in \(.applicationName)"],
                shortTitle: "MCP Only",
                systemImageName: "circle"
            ),
        ]
    }
}

struct MCPAppIntentShortcutsProvidingTests {
    @Test func mcpSpecificShortcutsOverrideSystemAppShortcuts() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TestShortcutsProvider.self)
        let names = metadata.map(\.name)

        #expect(names == ["mcpOnlyShortcut"])
    }
}
#endif
