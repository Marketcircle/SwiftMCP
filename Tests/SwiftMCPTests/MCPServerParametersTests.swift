import Testing
import SwiftMCP
import Foundation

@MCPServer(name: "CustomCalculator", version: "2.0")
final class CustomNameCalculator: MCPServer {
    @MCPTool(description: "Simple addition")
    func add(a: Int, b: Int) -> Int {
        return a + b
    }
}

@MCPServer
final class DefaultNameCalculator: MCPServer {
    @MCPTool(description: "Simple addition")
    func add(a: Int, b: Int) -> Int {
        return a + b
    }
}

@MCPServer(name: "InstructedCalculator")
final class InstructedCalculator: MCPServer, MCPInstructable {
    var mcpServerInstructions: String? { "Prefer add over manual arithmetic." }

    @MCPTool(description: "Simple addition")
    func add(a: Int, b: Int) -> Int {
        return a + b
    }
}

@Suite("MCP Server Parameters Tests", .tags(.unit, .fast))
struct MCPServerParametersTests {
    
    @Test("Custom server name and version are reflected in initialize response")
    func customServerNameAndVersion() async throws {
        let customCalculator = CustomNameCalculator()
        
        let request = JSONRPCMessage.request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": .object([
                    "experimental": .object([:]),
                    "resources": .object(["listChanged": false]),
                    "tools": .object(["listChanged": false])
                ]),
                "clientInfo": .object([
                    "name": "TestClient",
                    "version": "1.0"
                ])
            ]
        )
        
        let message = try #require(await customCalculator.handleMessage(request))
        
        guard case .response(let response) = message else {
            throw TestError("Expected response case")
        }
        
        let result = try #require(response.result)
        let serverInfoDict = try #require(result["serverInfo"]?.value as? [String: Any])
        let name = try #require(serverInfoDict["name"] as? String)
        let version = try #require(serverInfoDict["version"] as? String)
        
        #expect(name == "CustomCalculator")
        #expect(version == "2.0")
    }
    
    @Test("Default server uses class name for server info")  
    func defaultServerNameUsesClassName() async throws {
        let defaultCalculator = DefaultNameCalculator()
        
        let request = JSONRPCMessage.request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": .object([
                    "experimental": .object([:]),
                    "resources": .object(["listChanged": false]),
                    "tools": .object(["listChanged": false])
                ]),
                "clientInfo": .object([
                    "name": "TestClient",
                    "version": "1.0"
                ])
            ]
        )
        
        let message = try #require(await defaultCalculator.handleMessage(request))
        
        guard case .response(let response) = message else {
            throw TestError("Expected response case")
        }
        
        let result = try #require(response.result)
        let serverInfoDict = try #require(result["serverInfo"]?.value as? [String: Any])
        let name = try #require(serverInfoDict["name"] as? String)
        let version = try #require(serverInfoDict["version"] as? String)
        
        #expect(name == "DefaultNameCalculator")
        #expect(version == "1.0")
    }

    @Test("Instructable server carries instructions in initialize response")
    func instructableServerCarriesInstructions() async throws {
        let calculator = InstructedCalculator()

        let response = calculator.createInitializeResponse(id: .int(1))

        guard case .response(let responseData) = response else {
            throw TestError("Expected response case")
        }

        let result = try #require(responseData.result)
        let instructions = try #require(result["instructions"]?.value as? String)

        #expect(instructions == "Prefer add over manual arithmetic.")
    }

    @Test("Non-instructable server omits instructions from initialize response")
    func nonInstructableServerOmitsInstructions() async throws {
        let calculator = DefaultNameCalculator()

        let response = calculator.createInitializeResponse(id: .int(1))

        guard case .response(let responseData) = response else {
            throw TestError("Expected response case")
        }

        let result = try #require(responseData.result)

        #expect(result["instructions"] == nil)
    }
}

// MARK: - Test Tags Extension
extension Tag {
    @Tag static var unit: Self
    @Tag static var fast: Self
}
