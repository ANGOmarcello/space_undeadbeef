// Created by Angelo Cammalleri on 08.11.2026.
import Foundation

@main enum FolderProgressTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let folder = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = UUID()
        let b = UUID()
        let third = UUID()
        var checks = 0

        func require(_ condition: Bool, _ description: String) {
            checks += 1
            precondition(condition, description)
        }

        func record(_ checkpoint: UInt32, score: UInt32, highScore: UInt32) -> [String: Any] {
            var bytes = Data(repeating: 0, count: 256)
            func word(_ offset: Int, _ value: UInt32) {
                for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
            }
            word(0, 0x30485350)
            word(8, 256)
            word(0x10, 0x3f800000) // local game speed
            bytes[0x14] = 1 // local sound
            bytes[0x80] = 0x7f // unknown/local
            word(0x20, score)
            word(0x24, highScore)
            word(0x2c, checkpoint * 4)
            word(0x30, checkpoint)
            return SDBSaveStore.portableSnapshot(bytes)!
        }

        func file(_ writer: UUID) -> URL {
            folder.appendingPathComponent(GameFolderProgressFiles.prefix + writer.uuidString + ".json")
        }

        func assertRejected(_ reason: String, _ exchange: () throws -> Void) throws {
            let before = try Data(contentsOf: file(a))
            do {
                try exchange()
                preconditionFailure("Accepted \(reason)")
            } catch {
                require(try Data(contentsOf: file(a)) == before, "Rejected \(reason) without replacing a writer")
            }
        }

        let localA = record(1, score: 25, highScore: 200)
        let originalA = localA["saveData"] as! Data
        let sharedA = GameFolderProgressRecord(snapshot: localA)!
        let sharedB = GameFolderProgressRecord(snapshot: record(2, score: 40, highScore: 75))!
        require(sharedA.saveData[0x10..<0x15].allSatisfy { $0 == 0 } && sharedA.saveData[0x80] == 0,
                "Folder export does not expose game speed, sound or unknown bytes")
        require(sharedA.saveData != originalA, "Export leaves the original local snapshot untouched")

        let first = try GameFolderProgressFiles.exchange(in: folder, writer: a, local: sharedA)
        require(first == sharedA, "First installation publishes its validated record")
        let received = try GameFolderProgressFiles.exchange(in: folder, writer: b, local: sharedB)
        let expected = GameFolderProgressRecord(snapshot: record(2, score: 40, highScore: 200))!
        require(received == expected, "Second writer combines the farther checkpoint and highest score")
        require(try GameFolderProgressRecord.decode(Data(contentsOf: file(a))) == sharedA,
                "Publishing never overwrites the other writer")
        let converged = try GameFolderProgressFiles.exchange(in: folder, writer: a, local: sharedA)
        require(converged == expected, "A stale local writer catches up after reconnect")
        let locallyMerged = SDBSaveStore.mergeSnapshots(localA, remote: converged.snapshot)!["saveData"] as! Data
        require(locallyMerged[0x10..<0x15] == originalA[0x10..<0x15] && locallyMerged[0x80] == originalA[0x80],
                "Import uses the same original save merge and preserves local bytes")

        let unrelated = folder.appendingPathComponent("notes.txt")
        let notes = Data("keep this file".utf8)
        try notes.write(to: unrelated)
        let oldDate = Date(timeIntervalSince1970: 946684800)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file(a).path)
        _ = try GameFolderProgressFiles.exchange(in: folder, writer: a, local: sharedA)
        let modified = try file(a).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        require(modified == oldDate, "An unchanged writer is not republished")
        require(try Data(contentsOf: unrelated) == notes, "Unrelated folder contents remain intact")

        for (description, invalid) in [
            ("a truncated document", Data("{".utf8)),
            ("an oversized document", Data(repeating: 1, count: 4097)),
            ("an unsupported schema", Data("{\"schema\":2,\"game\":\"space-deadbeef\",\"saveData\":\"\",\"sha256\":\"\"}".utf8))
        ] {
            try invalid.write(to: file(third))
            try assertRejected(description) { _ = try GameFolderProgressFiles.exchange(in: folder, writer: a, local: sharedA) }
            try FileManager.default.removeItem(at: file(third))
        }
        try FileManager.default.createSymbolicLink(at: file(third), withDestinationURL: unrelated)
        try assertRejected("a symlink") { _ = try GameFolderProgressFiles.exchange(in: folder, writer: a, local: sharedA) }
        require(try Data(contentsOf: unrelated) == notes, "A symlink target is left intact")
        try FileManager.default.removeItem(at: file(third))

        let encoded = try JSONEncoder().encode(sharedB)
        for _ in 0..<62 { try encoded.write(to: file(UUID())) }
        try assertRejected("a new writer in a full folder") {
            _ = try GameFolderProgressFiles.exchange(in: folder, writer: third, local: sharedA)
        }
        require(!FileManager.default.fileExists(atPath: file(third).path), "Count-limit failure does not publish")
        print("Passed \(checks) folder-progress checks using the real PSH0 validator and coordinated file exchange.")
    }
}
