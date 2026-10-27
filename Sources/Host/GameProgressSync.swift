//
//  GameProgressSync.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 27.10.2026.
//

import Foundation

/// One record per installation prevents an offline device from replacing an
/// unseen writer's better progress. Only understood, bounded records are merged.
enum GameProgressExchange {
    static let prefix = "progress.v1."
    static let maximumWriters = 64
    static let maximumRecordBytes = 4096

    static func encode(_ record: [String: Any]) -> Data? {
        guard let bytes = try? PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0),
              bytes.count <= maximumRecordBytes else { return nil }
        return bytes
    }

    static func decode(_ bytes: Data) -> [String: Any]? {
        guard !bytes.isEmpty, bytes.count <= maximumRecordBytes else { return nil }
        return (try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)) as? [String: Any]
    }

    static func merged(local: [String: Any], records: [String: Any],
                       merge: ([String: Any], [String: Any]) -> [String: Any]?) -> [String: Any] {
        var result = local
        for key in records.keys.filter({ $0.hasPrefix(prefix) }).sorted().prefix(maximumWriters) {
            guard let data = records[key] as? Data, let remote = decode(data),
                  let next = merge(result, remote) else { continue }
            result = next
        }
        return result
    }
}

enum GameProgressChange: Equatable, Sendable {
    case recordsChanged
    case accountChanged

    static func notificationReason(_ reason: Int?) -> Self {
        reason == NSUbiquitousKeyValueStoreAccountChange ? .accountChanged : .recordsChanged
    }
}

protocol GameProgressObservation: AnyObject {}

/// An injected transport keeps adapter tests independent of accounts and stores.
@MainActor
protocol GameProgressTransport: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func synchronize() -> Bool
    func set(_ bytes: Data, forKey key: String)
    func observeChanges(_ handler: @escaping @MainActor @Sendable (GameProgressChange) -> Void) -> any GameProgressObservation
}

private final class FoundationGameProgressObservation: GameProgressObservation, @unchecked Sendable {
    let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
private final class FoundationGameProgressTransport: GameProgressTransport {
    private let store = NSUbiquitousKeyValueStore.default

    var dictionaryRepresentation: [String: Any] { store.dictionaryRepresentation }
    func synchronize() -> Bool { store.synchronize() }
    func set(_ bytes: Data, forKey key: String) { store.set(bytes, forKey: key) }

    func observeChanges(_ handler: @escaping @MainActor @Sendable (GameProgressChange) -> Void) -> any GameProgressObservation {
        let token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main) { notification in
                let reason = (notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue
                let change = GameProgressChange.notificationReason(reason)
                MainActor.assumeIsolated { handler(change) }
            }
        return FoundationGameProgressObservation(token: token)
    }
}

/// Foundation key-value storage needs no CloudKit database or schema deployment.
/// Signed iCloud capability/account availability remains a separate requirement.
@MainActor
final class GameProgressSync {
    private var transport: (any GameProgressTransport)?
    private var observation: (any GameProgressObservation)?
    private let isEnabled: @MainActor () -> Bool
    private let writerIdentity: @MainActor () -> String?
    private var writerKey: String?
    private var lastPublished: Data?
    private var serviceAvailable = false
    private(set) var needsExchange = true

    init(transport: (any GameProgressTransport)? = nil,
         enabled: (@MainActor () -> Bool)? = nil,
         writerIdentity: (@MainActor () -> String?)? = nil) {
        self.transport = transport
        isEnabled = enabled ?? Self.productionEnabled
        self.writerIdentity = writerIdentity ?? Self.installationIdentity
    }

    private static func productionEnabled() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "SDBProgressSyncEnabled") as? Bool == true &&
            ProcessInfo.processInfo.environment["SDB_SAVE_DIRECTORY"] == nil &&
            ProcessInfo.processInfo.environment["SDB_UI_TEST"] == nil
    }

    func exchange(with engine: SDBEngine, foreground: Bool = false) {
        guard isEnabled(), engine.failure == nil else { needsExchange = false; return }
        // ubiquityIdentityToken describes iCloud Drive, not KVS. In particular it
        // is nil on Watch/TV; KVS also retains a local cache without an account.
        if transport == nil { transport = FoundationGameProgressTransport() }
        guard let transport else { return }
        if observation == nil {
            observation = transport.observeChanges { [weak self] change in
                guard let self else { return }
                if change == .accountChanged {
                    self.lastPublished = nil
                    self.serviceAvailable = false
                }
                self.needsExchange = true
            }
        }
        if foreground || !serviceAvailable {
            serviceAvailable = transport.synchronize()
            if !serviceAvailable { needsExchange = false; return }
        }
        guard let local = engine.progressPortableSnapshot else { needsExchange = false; return }
        let entries = transport.dictionaryRepresentation
        let merged = GameProgressExchange.merged(local: local, records: entries) {
            SDBEngine.mergeProgress($0, remote: $1)
        }
        // Applying a checkpoint is deferred until the original title screen;
        // paused or ongoing games retain their current session and input.
        if engine.gameMenuType == 1 {
            // A failed disk write must not retry on each title frame. A later
            // foreground, checkpoint or external change can request another try.
            needsExchange = false
            _ = engine.importValidatedProgress(merged)
        } else {
            needsExchange = true
        }
        guard let bytes = GameProgressExchange.encode(merged), let key = installationKey() else { return }
        if entries[key] == nil && entries.keys.filter({ $0.hasPrefix(GameProgressExchange.prefix) }).count >= GameProgressExchange.maximumWriters {
            return // Preserve other writers; never delete somebody else's record.
        }
        // Property-list dictionary order can change its serialized bytes. Only
        // publish when the understood content changed or the account was reset.
        if !matches(lastPublished, record: merged) || !matches(entries[key] as? Data, record: merged) {
            transport.set(bytes, forKey: key)
            lastPublished = bytes
        }
    }

    private func matches(_ bytes: Data?, record: [String: Any]) -> Bool {
        guard let bytes, let decoded = GameProgressExchange.decode(bytes) else { return false }
        return NSDictionary(dictionary: decoded).isEqual(to: record)
    }

    private func installationKey() -> String? {
        if let writerKey { return writerKey }
        guard let value = writerIdentity(), let identifier = UUID(uuidString: value) else { return nil }
        let result = GameProgressExchange.prefix + identifier.uuidString
        writerKey = result
        return result
    }

    private static func installationIdentity() -> String? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundle = Bundle.main.bundleIdentifier else { return nil }
        var folder = base.appendingPathComponent(bundle).appendingPathComponent("ProgressSync", isDirectory: true)
        let file = folder.appendingPathComponent("installation-id")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let identifier: UUID
            if let data = try? Data(contentsOf: file), data.count <= 64,
               let value = String(data: data, encoding: .utf8), let uuid = UUID(uuidString: value) {
                identifier = uuid
            } else {
                identifier = UUID()
                try Data(identifier.uuidString.utf8).write(to: file, options: .atomic)
            }
            return identifier.uuidString
        } catch { return nil }
    }
}
