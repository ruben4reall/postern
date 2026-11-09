import Foundation
import MCP
import PosternModel
import PosternPolicy
import Testing
@testable import PosternServer

/// Every tool must load in every client and model: Claude, OpenAI's, Gemini's. These are the rules they share.
@Suite struct PortableSchemaTests {
    static let allowed: Set<String> = [
        "type", "properties", "required", "items", "description", "enum", "minimum", "maximum", "minItems", "maxItems",
    ]

    func check(_ schema: Value, path: String, depth: Int, issues: inout [String]) {
        guard case .object(let fields) = schema else { issues.append("\(path) is not an object"); return }
        for key in fields.keys where !Self.allowed.contains(key) { issues.append("\(path) uses \(key)") }
        if case .array(let values)? = fields["enum"], values.contains(where: { if case .string = $0 { false } else { true } }) {
            issues.append("\(path) has a non-string enum")
        }
        switch fields["type"] {
        case .string("object")?:
            guard case .object(let properties)? = fields["properties"] else { issues.append("\(path) has no properties"); return }
            if depth > 4 { issues.append("\(path) nests too deep") }
            for (name, property) in properties { check(property, path: path + "." + name, depth: depth + 1, issues: &issues) }
        case .string("array")?:
            guard let items = fields["items"] else { issues.append("\(path) has no items"); return }
            check(items, path: path + "[]", depth: depth + 1, issues: &issues)
        case .string?:
            break
        default:
            issues.append("\(path) has no single type")
        }
    }

    @Test func everySchemaStaysInTheSubsetEveryClientAccepts() {
        var issues: [String] = []
        for id in ToolID.allCases {
            let tool = ToolCatalog.definition(id)
            #expect(tool.name.wholeMatch(of: #/[a-z][a-z0-9_]{0,40}/#) != nil && "postern".count + tool.name.count <= 60, "\(tool.name)")
            #expect(tool.description?.count ?? 0 <= 1000, "\(tool.name) has a long description")
            check(tool.inputSchema, path: tool.name, depth: 0, issues: &issues)
        }
        #expect(issues.isEmpty, "\(issues)")
    }

    @Test func theWholeListStaysSmall() throws {
        let tools = ToolCatalog.tools(for: Policy(enabledTools: Set(ToolID.allCases)))
        let bytes = try JSONEncoder().encode(tools).count
        // About four characters a token: every tool on costs about 8,500 tokens, read once per session.
        #expect(bytes < 34_500, "\(bytes) bytes")
        let instructions = ServerInstructions.text(for: Policy(enabledTools: Set(ToolID.allCases)))
        #expect(instructions.count < 1600 && ServerInstructions.text(for: .initial).count < 900)
    }
}
