import Foundation
import Testing
@testable import PosternAudit

final class MemoryHead: HeadStore, @unchecked Sendable {
    var value: String?
    func load() -> String? { value }
    func save(_ hash: String) { value = hash }
}

@Suite struct ActivityLogTests {
    func makeLog() -> (ActivityLog, URL, MemoryHead) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString).jsonl")
        let head = MemoryHead()
        return (ActivityLog(fileURL: url, head: head), url, head)
    }

    func fill(_ log: ActivityLog, _ count: Int) throws {
        for index in 0..<count {
            try log.append(client: "claude", tool: "get_message", outcome: index % 2 == 0 ? "ok" : "policy_disabled", items: 1)
        }
    }

    @Test func emptyLogIsIntact() throws {
        let (log, _, _) = makeLog()
        #expect(try log.verify() == .intact(count: 0))
    }

    @Test func appendedRecordsVerifyAndReadNewestFirst() throws {
        let (log, _, _) = makeLog()
        try fill(log, 5)
        #expect(try log.verify() == .intact(count: 5))
        let records = try log.records(limit: 2)
        #expect(records.count == 2)
        #expect(records[0].date >= records[1].date)
        #expect(records[0].outcome == "ok")
    }

    @Test func detectsAnEditedLine() throws {
        let (log, url, _) = makeLog()
        try fill(log, 4)
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[1] = lines[1].replacingOccurrences(of: "policy_disabled", with: "ok")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(try log.verify() == .broken(line: 3))
    }

    @Test func detectsADeletedLastLine() throws {
        let (log, url, _) = makeLog()
        try fill(log, 3)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropLast()
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(try log.verify() == .headMismatch)
    }

    @Test func detectsADeletedFile() throws {
        let (log, url, _) = makeLog()
        try fill(log, 2)
        try FileManager.default.removeItem(at: url)
        #expect(try log.verify() == .headMismatch)
    }

    @Test func pruningKeepsTheChainVerifiable() throws {
        let (log, url, _) = makeLog()
        try fill(log, 3)
        try log.prune(olderThan: Date().addingTimeInterval(3600))
        #expect(try log.verify() == .intact(count: 0))
        _ = url
        try fill(log, 2)
        #expect(try log.verify() == .intact(count: 2))
    }
}
