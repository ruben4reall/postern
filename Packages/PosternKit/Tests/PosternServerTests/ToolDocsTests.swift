import Foundation
import Testing
import PosternModel

/// The tool reference is written by hand; this keeps it from missing a tool.
@Suite struct ToolDocsTests {
    @Test func everyToolIsInTheReference() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = try String(contentsOf: repository.appendingPathComponent("docs/tools.md"), encoding: .utf8)
        for tool in ToolID.allCases {
            #expect(reference.contains("| `\(tool.rawValue)` |"), "\(tool.rawValue) is missing from docs/tools.md")
        }
    }
}
