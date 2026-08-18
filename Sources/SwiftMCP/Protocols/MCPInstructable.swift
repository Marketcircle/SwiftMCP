import Foundation

/// Protocol for servers that provide usage instructions to clients.
///
/// The instructions are carried on the `initialize` response, where clients such as
/// Claude Desktop inject them into the model's system prompt. Use them for guidance
/// that spans tools and has no home on any single tool description.
public protocol MCPInstructable {
    /// Usage guidance for the client, or `nil` to omit the field from the handshake.
    var mcpServerInstructions: String? { get }
}
