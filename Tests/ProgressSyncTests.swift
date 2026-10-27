// Created by Angelo Cammalleri on 27.10.2026.
import Foundation

private final class FakeProgressObservation: GameProgressObservation {}

@MainActor
private final class FakeProgressTransport: GameProgressTransport {
    var records: [String: Any] = [:]
    var synchronizationResults: [Bool] = []
    private(set) var synchronizations = 0
    private(set) var reads = 0
    private(set) var observations = 0
    private(set) var writes: [(key: String, bytes: Data)] = []
    private var handlers: [@MainActor @Sendable (GameProgressChange) -> Void] = []

    var dictionaryRepresentation: [String: Any] { reads += 1; return records }
    func synchronize() -> Bool {
        synchronizations += 1
        return synchronizationResults.isEmpty ? true : synchronizationResults.removeFirst()
    }
    func set(_ bytes: Data, forKey key: String) {
        writes.append((key, bytes)); records[key] = bytes
    }
    func observeChanges(_ handler: @escaping @MainActor @Sendable (GameProgressChange) -> Void) -> any GameProgressObservation {
        observations += 1; handlers.append(handler)
        return FakeProgressObservation()
    }
    func notify(_ change: GameProgressChange) { handlers.forEach { $0(change) } }
}

@main @MainActor enum ProgressSyncTests {
    static func main() {
        var checks = 0
        func require(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let local: [String: Any] = ["schema": 1, "value": 3]
        let merge: ([String: Any], [String: Any]) -> [String: Any]? = { local, remote in
            guard remote["schema"] as? Int == 1, let a = local["value"] as? Int,
                  let b = remote["value"] as? Int else { return nil }
            return ["schema": 1, "value": max(a, b)]
        }
        let older = GameProgressExchange.encode(["schema": 1, "value": 1])!
        let newer = GameProgressExchange.encode(["schema": 1, "value": 9])!
        let unknown = GameProgressExchange.encode(["schema": 2, "value": 99])!
        require(GameProgressExchange.decode(Data()) == nil, "Empty remote record is rejected")
        require(GameProgressExchange.decode(Data(repeating: 0, count: 4097)) == nil, "Oversized remote record is rejected before parsing")
        require(GameProgressExchange.decode(Data("garbage".utf8)) == nil, "Malformed remote data is rejected")
        require(GameProgressExchange.encode(["blob": Data(repeating: 1, count: 4097)]) == nil, "Outgoing data is bounded")
        let entries: [String: Any] = ["progress.v1.a": older, "progress.v1.b": newer, "progress.v1.c": unknown,
                                     "unrelated": GameProgressExchange.encode(["schema": 1, "value": 999])!,
                                     "progress.v1.d": "not data"]
        let result = GameProgressExchange.merged(local: local, records: entries, merge: merge)
        require(result["value"] as? Int == 9, "Valid writer records merge while malformed, unknown and unrelated values are ignored")
        let reversed = Dictionary(uniqueKeysWithValues: entries.reversed())
        require(GameProgressExchange.merged(local: local, records: reversed, merge: merge)["value"] as? Int == 9,
                "Unordered cloud enumeration gives the same result")
        require(GameProgressExchange.merged(local: result, records: entries, merge: merge)["value"] as? Int == 9,
                "Repeated incoming changes are idempotent")
        var many: [String: Any] = [:]
        for index in 0..<100 { many[String(format: "progress.v1.%03d", index)] = newer }
        var visited = 0
        _ = GameProgressExchange.merged(local: local, records: many) { a, b in visited += 1; return merge(a, b) }
        require(visited == 64, "Incoming writer count is bounded")
        require(GameProgressExchange.merged(local: local, records: [:], merge: merge)["value"] as? Int == 3,
                "Missing cloud data retains local progress")

        let writerA = "00000000-0000-0000-0000-000000000001"
        let writerB = "00000000-0000-0000-0000-000000000002"
        let keyA = GameProgressExchange.prefix + writerA
        let keyB = GameProgressExchange.prefix + writerB
        func adapter(_ transport: FakeProgressTransport, writer: String = writerA) -> GameProgressSync {
            GameProgressSync(transport: transport, enabled: { true }, writerIdentity: { writer })
        }
        func value(_ bytes: Any?) -> Int? {
            guard let bytes = bytes as? Data else { return nil }
            return GameProgressExchange.decode(bytes)?["value"] as? Int
        }

        // The disposable engine fixture models only this adapter's boundary.
        // Real PSH0 validation/merge and running-session behavior have separate
        // native engine tests; these checks exercise the production adapter.
        let cache = FakeProgressTransport()
        let title = SDBEngine(progress: local)
        let sync = adapter(cache)
        sync.exchange(with: title)
        require(cache.synchronizations == 1 && cache.observations == 1,
                "A working KVS transport is sufficient without an iCloud Drive identity")
        require(title.imports.count == 1 && !sync.needsExchange,
                "Title progress is imported and the pending exchange clears")
        require(value(cache.records[keyA]) == 3 && cache.writes.count == 1,
                "The adapter publishes its installation record to the local KVS cache")
        sync.exchange(with: title)
        require(cache.synchronizations == 1 && cache.observations == 1 && cache.writes.count == 1,
                "Unchanged records do not register another observer, synchronize or write")
        cache.records[keyA] = Data("<plist version=\"1.0\"><dict><key>value</key><integer>3</integer><key>schema</key><integer>1</integer></dict></plist>".utf8)
        sync.exchange(with: title)
        require(cache.writes.count == 1, "Equivalent property-list serialization never republishes unchanged progress")

        cache.records[keyB] = newer
        cache.notify(.recordsChanged)
        require(sync.needsExchange, "An external record notification requests an exchange")
        sync.exchange(with: title)
        require(title.progressPortableSnapshot?["value"] as? Int == 9 && !sync.needsExchange,
                "An external record is applied at the original title screen")
        require(value(cache.records[keyA]) == 9 && value(cache.records[keyB]) == 9,
                "Import republishes the merged result without replacing another writer")

        let syncsBeforeAccountChange = cache.synchronizations
        let writesBeforeAccountChange = cache.writes.count
        cache.notify(GameProgressChange.notificationReason(NSUbiquitousKeyValueStoreAccountChange))
        require(sync.needsExchange, "An account change requests reconciliation")
        sync.exchange(with: title)
        require(cache.synchronizations == syncsBeforeAccountChange + 1,
                "Account changes invalidate service state and synchronize again")
        require(cache.writes.count == writesBeforeAccountChange + 1,
                "Account changes invalidate publication state even if the cached bytes match")
        cache.records = [:]
        cache.notify(.accountChanged)
        sync.exchange(with: title)
        require(value(cache.records[keyA]) == 9 && title.progressPortableSnapshot?["value"] as? Int == 9,
                "An empty replacement account cache cannot erase local progress")
        require(GameProgressChange.notificationReason(NSUbiquitousKeyValueStoreServerChange) == .recordsChanged &&
                GameProgressChange.notificationReason(NSUbiquitousKeyValueStoreInitialSyncChange) == .recordsChanged &&
                GameProgressChange.notificationReason(NSUbiquitousKeyValueStoreQuotaViolationChange) == .recordsChanged &&
                GameProgressChange.notificationReason(nil) == .recordsChanged,
                "Foundation change reasons use the public account-change constant")

        let unavailable = FakeProgressTransport()
        unavailable.records[keyB] = newer
        unavailable.synchronizationResults = [false, true]
        let offlineTitle = SDBEngine(progress: local)
        let offlineSync = adapter(unavailable)
        offlineSync.exchange(with: offlineTitle)
        require(offlineTitle.imports.isEmpty && offlineTitle.progressPortableSnapshot?["value"] as? Int == 3,
                "A synchronization error leaves local game progress untouched")
        require(unavailable.reads == 0 && unavailable.writes.isEmpty && !offlineSync.needsExchange,
                "An unavailable service does not publish or retry on every title frame")
        offlineSync.exchange(with: offlineTitle, foreground: true)
        require(unavailable.synchronizations == 2 && offlineTitle.progressPortableSnapshot?["value"] as? Int == 9,
                "The next foreground exchange retries a failed synchronization")
        unavailable.synchronizationResults = [false, true]
        offlineSync.exchange(with: offlineTitle, foreground: true)
        unavailable.notify(.recordsChanged)
        require(offlineSync.needsExchange, "An external notification can wake a failed service")
        offlineSync.exchange(with: offlineTitle)
        require(unavailable.synchronizations == 4 && !offlineSync.needsExchange,
                "External change retries the service before using its records")

        let deferredCache = FakeProgressTransport()
        let playing = SDBEngine(progress: local)
        let deferredSync = adapter(deferredCache)
        deferredSync.exchange(with: playing)
        require(!deferredSync.needsExchange, "A completed title exchange starts with no pending import")
        let importsBeforePlaying = playing.imports.count
        deferredCache.records[keyB] = newer
        playing.gameMenuType = 0
        deferredSync.exchange(with: playing)
        require(playing.imports.count == importsBeforePlaying && playing.progressPortableSnapshot?["value"] as? Int == 3,
                "An ongoing game never imports remote progress")
        require(value(deferredCache.records[keyA]) == 9 && deferredSync.needsExchange,
                "Merged progress is published while its local import stays deferred")
        playing.gameMenuType = 2
        deferredSync.exchange(with: playing)
        require(playing.imports.count == importsBeforePlaying && deferredCache.writes.count == 2,
                "The original pause menu retains the live session and avoids duplicate publication")
        playing.gameMenuType = 1
        deferredSync.exchange(with: playing)
        require(playing.imports.count == importsBeforePlaying + 1 && playing.progressPortableSnapshot?["value"] as? Int == 9 && !deferredSync.needsExchange,
                "Returning to the title applies the deferred progress")

        let rejectedCache = FakeProgressTransport()
        rejectedCache.records[keyB] = newer
        let rejectedTitle = SDBEngine(progress: local)
        rejectedTitle.acceptsImport = false
        let rejectedSync = adapter(rejectedCache)
        rejectedSync.exchange(with: rejectedTitle)
        require(!rejectedSync.needsExchange && rejectedTitle.progressPortableSnapshot?["value"] as? Int == 3,
                "A rejected title import consumes the attempt and preserves local progress")
        let readsAfterRejection = rejectedCache.reads
        for _ in 0..<120 {
            if rejectedSync.needsExchange { rejectedSync.exchange(with: rejectedTitle) }
        }
        require(rejectedTitle.imports.count == 1 && rejectedCache.reads == readsAfterRejection,
                "The host's next 120 title frames do not retry a failed import")
        rejectedTitle.acceptsImport = true
        rejectedSync.exchange(with: rejectedTitle, foreground: true)
        require(rejectedTitle.imports.count == 2 && rejectedTitle.progressPortableSnapshot?["value"] as? Int == 9 && !rejectedSync.needsExchange,
                "A foreground exchange can retry and apply a previously rejected import")
        rejectedTitle.acceptsImport = false
        rejectedCache.records[keyB] = GameProgressExchange.encode(["schema": 1, "value": 12])!
        rejectedCache.notify(.recordsChanged)
        if rejectedSync.needsExchange { rejectedSync.exchange(with: rejectedTitle) }
        require(rejectedTitle.imports.count == 3 && !rejectedSync.needsExchange,
                "An external change schedules one new import attempt")
        rejectedTitle.acceptsImport = true
        rejectedSync.exchange(with: rejectedTitle)
        require(rejectedTitle.imports.count == 4 && rejectedTitle.progressPortableSnapshot?["value"] as? Int == 12,
                "An explicit checkpoint exchange can retry without another notification")

        let missingCache = FakeProgressTransport()
        let missingTitle = SDBEngine(progress: local)
        missingTitle.progressPortableSnapshot = nil
        let missingSync = adapter(missingCache)
        missingSync.exchange(with: missingTitle)
        let synchronizationsAfterMissingSnapshot = missingCache.synchronizations
        for _ in 0..<120 {
            if missingSync.needsExchange { missingSync.exchange(with: missingTitle) }
        }
        require(!missingSync.needsExchange && missingTitle.imports.isEmpty && missingCache.reads == 0 &&
                missingCache.synchronizations == synchronizationsAfterMissingSnapshot,
                "A missing local snapshot also avoids repeated work on each title frame")
        missingTitle.progressPortableSnapshot = local
        missingSync.exchange(with: missingTitle, foreground: true)
        require(missingTitle.imports.count == 1 && value(missingCache.records[keyA]) == 3,
                "A later foreground retries once a local snapshot is available")

        let sharedCache = FakeProgressTransport()
        let first = SDBEngine(progress: ["schema": 1, "value": 1])
        let second = SDBEngine(progress: ["schema": 1, "value": 6])
        let firstSync = adapter(sharedCache)
        let secondSync = adapter(sharedCache, writer: writerB)
        firstSync.exchange(with: first); secondSync.exchange(with: second)
        firstSync.exchange(with: first)
        require(sharedCache.records.count == 2 && value(sharedCache.records[keyA]) == 6 && value(sharedCache.records[keyB]) == 6,
                "Separate installations retain independent writer records and converge")
        require(first.progressPortableSnapshot?["value"] as? Int == 6 && second.progressPortableSnapshot?["value"] as? Int == 6,
                "Both title sessions receive the best understood progress")

        let full = FakeProgressTransport()
        for index in 0..<GameProgressExchange.maximumWriters {
            full.records[GameProgressExchange.prefix + String(format: "10000000-0000-0000-0000-%012d", index)] = older
        }
        let bounded = adapter(full)
        bounded.exchange(with: SDBEngine(progress: local))
        require(full.records.count == 64 && full.writes.isEmpty && full.records[keyA] == nil,
                "A 65th writer is not added and existing records are never evicted")
        full.records.removeValue(forKey: full.records.keys.first!)
        full.records[keyA] = older
        bounded.exchange(with: SDBEngine(progress: ["schema": 1, "value": 7]))
        require(full.records.count == 64 && full.writes.count == 1 && value(full.records[keyA]) == 7,
                "An existing writer can update its record at the writer limit")
        let oversizedCache = FakeProgressTransport()
        adapter(oversizedCache).exchange(with: SDBEngine(progress: ["schema": 1, "value": 3, "blob": Data(repeating: 1, count: 4097)]))
        require(oversizedCache.writes.isEmpty, "The actual adapter never publishes an oversized outgoing record")

        let disabledCache = FakeProgressTransport()
        var identitiesRead = 0
        let disabled = GameProgressSync(transport: disabledCache, writerIdentity: { identitiesRead += 1; return writerA })
        disabled.exchange(with: SDBEngine(progress: local), foreground: true)
        require(disabledCache.observations == 0 && disabledCache.synchronizations == 0 && disabledCache.reads == 0 && identitiesRead == 0,
                "The real production enable policy disables all service/identity access in test environments")
        let failedCache = FakeProgressTransport()
        let failedEngine = SDBEngine(progress: local)
        failedEngine.failure = "Fixture runtime failure"
        adapter(failedCache).exchange(with: failedEngine, foreground: true)
        require(failedCache.observations == 0 && failedCache.synchronizations == 0 && failedCache.writes.isEmpty,
                "An unhealthy engine never starts cloud exchange")
        print("PASS: \(checks) bounded progress exchange and production adapter checks; fake KVS/engine only, no account or cloud service accessed")
    }
}
