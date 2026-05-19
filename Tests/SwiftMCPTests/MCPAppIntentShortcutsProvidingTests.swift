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
        var shortcuts: [AppShortcut] = [
            AppShortcut(
                intent: MCPOnlyShortcutIntent(),
                phrases: ["Run MCP only shortcut in \(.applicationName)"],
                shortTitle: "MCP Only",
                systemImageName: "circle"
            ),
        ]

        if includeMCPOnlyShortcut == false {
            shortcuts = []
        }

        return shortcuts
    }

    private static var includeMCPOnlyShortcut: Bool {
        ProcessInfo.processInfo.environment["SWIFTMCP_INCLUDE_TEST_APP_INTENT_SHORTCUT"] != "0"
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

    @Test func mcpSpecificShortcutsSupportRuntimeConditions() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TestShortcutsProvider.self)

        #expect(metadata.map(\.name) == ["mcpOnlyShortcut"])
    }
}
#endif
