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

@MCPAppIntentTool(title: "Get Daylite task", description: "Retrieve a Daylite task by ID")
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct TitledShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Titled Shortcut"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "titled")
    }
}

@MCPAppIntentTool(description: "Uses the AppIntent title")
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct DefaultTitledShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Default AppIntent Title"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "default titled")
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

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct TitledShortcutsProvider: AppShortcutsProvider, MCPAppIntentShortcutsProviding {
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
                intent: TitledShortcutIntent(),
                phrases: ["Run titled shortcut in \(.applicationName)"],
                shortTitle: "Titled",
                systemImageName: "textformat"
            ),
            AppShortcut(
                intent: DefaultTitledShortcutIntent(),
                phrases: ["Run default titled shortcut in \(.applicationName)"],
                shortTitle: "Default Titled",
                systemImageName: "textformat"
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

    @Test func mcpSpecificShortcutsSupportRuntimeConditions() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TestShortcutsProvider.self)

        #expect(metadata.map(\.name) == ["mcpOnlyShortcut"])
    }

    @Test func appIntentToolTitleIsExposedInMetadata() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TitledShortcutsProvider.self)
        let tool = try! #require(metadata.first { $0.name == "TitledShortcutIntent" })

        #expect(tool.name == "TitledShortcutIntent")
        #expect(tool.title == "Get Daylite task")
        #expect(tool.description == "Retrieve a Daylite task by ID")
    }

    @Test func appIntentToolTitleIsExposedOnMCPTool() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TitledShortcutsProvider.self)
        let tools = metadata.convertedToTools()
        let tool = try! #require(tools.first { $0.name == "TitledShortcutIntent" })

        #expect(tool.name == "TitledShortcutIntent")
        #expect(tool.title == "Get Daylite task")
        #expect(tool.description == "Retrieve a Daylite task by ID")
    }

    @Test func appIntentToolTitleDefaultsToAppIntentTitle() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TitledShortcutsProvider.self)
        let tool = try! #require(metadata.first { $0.name == "DefaultTitledShortcutIntent" })

        #expect(tool.name == "DefaultTitledShortcutIntent")
        #expect(tool.title == "Default AppIntent Title")
        #expect(tool.description == "Uses the AppIntent title")
    }
}
#endif
