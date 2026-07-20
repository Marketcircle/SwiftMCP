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

@MCPAppIntentTool(name: "custom_tool_name", title: "Named Shortcut", description: "Uses an explicit name override")
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
private struct NamedShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Named Shortcut"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "named")
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
            AppShortcut(
                intent: NamedShortcutIntent(),
                phrases: ["Run named shortcut in \(.applicationName)"],
                shortTitle: "Named",
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
        let tool = try! #require(metadata.first { $0.title == "Get Daylite task" })

        // The name is derived from the resolved title, not the Swift type name.
        #expect(tool.name == "get-daylite-task")
        #expect(tool.title == "Get Daylite task")
        #expect(tool.description == "Retrieve a Daylite task by ID")
    }

    @Test func appIntentToolTitleIsExposedOnMCPTool() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TitledShortcutsProvider.self)
        let tools = metadata.convertedToTools()
        let tool = try! #require(tools.first { $0.title == "Get Daylite task" })

        #expect(tool.name == "get-daylite-task")
        #expect(tool.title == "Get Daylite task")
        #expect(tool.description == "Retrieve a Daylite task by ID")
    }

    @Test func appIntentToolTitleDefaultsToAppIntentTitle() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TitledShortcutsProvider.self)
        let tool = try! #require(metadata.first { $0.title == "Default AppIntent Title" })

        // Falls back to the AppIntent's own title, and the name is derived from it.
        #expect(tool.name == "default-appintent-title")
        #expect(tool.title == "Default AppIntent Title")
        #expect(tool.description == "Uses the AppIntent title")
    }

    @Test func appIntentToolNameCanBeOverridden() {
        guard #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) else {
            return
        }

        let metadata = MCPAppIntentTools.toolMetadata(for: TitledShortcutsProvider.self)
        let tool = try! #require(metadata.first { $0.title == "Named Shortcut" })

        // An explicit `name:` override always wins over the title-derived name.
        #expect(tool.name == "custom_tool_name")
        #expect(tool.title == "Named Shortcut")
        #expect(tool.description == "Uses an explicit name override")
    }
}
#endif
