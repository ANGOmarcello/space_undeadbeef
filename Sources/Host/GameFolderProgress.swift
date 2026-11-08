//
//  GameFolderProgress.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 08.11.2026.
//

#if os(iOS) || os(macOS)
import Darwin
import Foundation

/// A separate, game-specific wire format. The validated PSH0 bytes contain
/// only the known progression fields; local settings and unused bytes are zero.
struct GameFolderProgressRecord: Codable, Equatable, Sendable {
    let schema: Int
    let game: String
    let saveData: Data
    let sha256: String

    init?(snapshot: [String: Any]) {
        guard let shared = SDBSaveStore.sharedProgress(snapshot),
              let bytes = shared["saveData"] as? Data, let digest = shared["sha256"] as? String else { return nil }
        schema = 1
        game = "space-deadbeef"
        saveData = bytes
        sha256 = digest
    }

    var snapshot: [String: Any] { ["schema": schema, "saveData": saveData, "sha256": sha256] }

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= GameFolderProgressFiles.maximumRecordBytes,
              let record = try? JSONDecoder().decode(Self.self, from: bytes),
              let verified = Self(snapshot: record.snapshot), verified == record else {
            throw GameFolderProgressError.invalidRecord
        }
        return record
    }

    func merged(with remote: Self) throws -> Self {
        guard let merged = SDBSaveStore.mergeSnapshots(snapshot, remote: remote.snapshot),
              let record = Self(snapshot: merged) else { throw GameFolderProgressError.invalidRecord }
        return record
    }
}

struct GameFolderSelection: Codable, Sendable {
    static let maximumBookmarkBytes = 64 * 1024
    let name: String
    let bookmark: Data
}

enum GameFolderProgressError: LocalizedError {
    case chooseICloud, accessDenied, downloading, invalidRecord, tooManyRecords, unavailable

    var errorDescription: String? {
        switch self {
        case .chooseICloud: "Choose a folder in iCloud Drive."
        case .accessDenied: "The folder can’t be opened. Choose it again in Files."
        case .downloading: "Progress files are downloading from iCloud Drive. Try again shortly."
        case .invalidRecord: "A progress file is damaged or uses an unsupported format. Nothing was merged."
        case .tooManyRecords: "This folder contains too many progress files. Choose a dedicated folder."
        case .unavailable: "The folder isn’t available right now. Try again when iCloud Drive is available."
        }
    }
}

enum GameFolderProgressFiles {
    static let prefix = "SpaceDeadbeef-Save-"
    static let maximumRecordBytes = 4096
    private static let maximumFiles = 64
    // Include unrelated directory entries and unresolved versions in the limits.
    private static let maximumDirectoryEntries = 4096
    private static let maximumReads = maximumFiles * 2 + 1

    static func choose(_ url: URL) throws -> GameFolderSelection {
        guard url.startAccessingSecurityScopedResource() else { throw GameFolderProgressError.accessDenied }
        defer { url.stopAccessingSecurityScopedResource() }
        return try FolderCoordination().perform { coordinator in
            try coordinator.read(url) { folder in
                try requireFolder(folder, iCloud: true)
                return try bookmark(for: url)
            }
        }
    }

    static func exchange(selection: GameFolderSelection, local: GameFolderProgressRecord, identityDirectory: URL)
        throws -> (progress: GameFolderProgressRecord, renewed: GameFolderSelection?) {
        guard selection.bookmark.count <= GameFolderSelection.maximumBookmarkBytes else {
            throw GameFolderProgressError.accessDenied
        }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: selection.bookmark, options: .withoutUI,
                                    relativeTo: nil, bookmarkDataIsStale: &stale),
              folder.startAccessingSecurityScopedResource() else { throw GameFolderProgressError.accessDenied }
        defer { folder.stopAccessingSecurityScopedResource() }
        try requireFolder(folder, iCloud: true)
        let renewed = stale ? try bookmark(for: folder) : nil
        let writer = try installationIdentity(in: identityDirectory)
        return (try exchange(in: folder, writer: writer, local: local), renewed)
    }

    // Called only while the caller owns access. Also exercised with two writers
    // in an isolated local directory, independently of an Apple Account.
    static func exchange(in folder: URL, writer: UUID, local: GameFolderProgressRecord) throws -> GameFolderProgressRecord {
        try FolderCoordination().perform { coordinator in
            let files = try coordinator.read(folder) { try progressFiles(in: $0) }
            let target = folder.appendingPathComponent(prefix + writer.uuidString + ".json")
            guard files.count < maximumFiles || files.contains(where: { $0.lastPathComponent == target.lastPathComponent }) else {
                throw GameFolderProgressError.tooManyRecords
            }
            var remainingReads = maximumReads
            var merged = local
            for file in files {
                try Task.checkCancellation()
                try requireDownloaded(file)
                try coordinator.read(file) { url in
                    guard let current = try readRecord(url, budget: &remainingReads) else {
                        throw GameFolderProgressError.unavailable
                    }
                    merged = try merged.merged(with: current)
                    try mergeConflicts(at: url, into: &merged, budget: &remainingReads)
                }
            }
            return try coordinator.write(target) { url in
                // Re-read our own writer under the write claim. A provider may
                // have delivered a newer version since the directory scan.
                let previous = try readRecord(url, budget: &remainingReads)
                if let previous {
                    merged = try merged.merged(with: previous)
                    try mergeConflicts(at: url, into: &merged, budget: &remainingReads)
                }
                try Task.checkCancellation()
                if previous != merged {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let bytes = try encoder.encode(merged)
                    guard bytes.count <= maximumRecordBytes else { throw GameFolderProgressError.invalidRecord }
                    try bytes.write(to: url, options: .atomic)
                }
                return merged
            }
        }
    }

    private static func bookmark(for folder: URL) throws -> GameFolderSelection {
        let bytes = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bytes.count <= GameFolderSelection.maximumBookmarkBytes else { throw GameFolderProgressError.accessDenied }
        return GameFolderSelection(name: String(folder.lastPathComponent.prefix(128)), bookmark: bytes)
    }

    private static func requireFolder(_ folder: URL, iCloud: Bool) throws {
        guard folder.isFileURL else { throw GameFolderProgressError.chooseICloud }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isUbiquitousItemKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              !iCloud || values.isUbiquitousItem == true else { throw GameFolderProgressError.chooseICloud }
    }

    private static func progressFiles(in folder: URL) throws -> [URL] {
        try requireFolder(folder, iCloud: false)
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                  options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                  errorHandler: { _, error in enumerationError = error; return false }) else {
            throw GameFolderProgressError.unavailable
        }
        var matches: [URL] = []
        for (index, entry) in entries.enumerated() {
            guard index < maximumDirectoryEntries else { throw GameFolderProgressError.tooManyRecords }
            guard let url = entry as? URL, url.lastPathComponent.hasPrefix(prefix), url.pathExtension == "json" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)
            guard UUID(uuidString: String(stem)) != nil else { throw GameFolderProgressError.invalidRecord }
            guard matches.count < maximumFiles else { throw GameFolderProgressError.tooManyRecords }
            matches.append(url)
        }
        if let enumerationError { throw enumerationError }
        return matches.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func mergeConflicts(at url: URL, into merged: inout GameFolderProgressRecord, budget: inout Int) throws {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard versions.count <= budget else { throw GameFolderProgressError.tooManyRecords }
        for version in versions {
            guard let record = try readRecord(version.url, budget: &budget) else {
                throw GameFolderProgressError.unavailable
            }
            merged = try merged.merged(with: record)
        }
    }

    private static func requireDownloaded(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw GameFolderProgressError.downloading
        }
    }

    private static func readRecord(_ url: URL, budget: inout Int) throws -> GameFolderProgressRecord? {
        guard budget > 0 else { throw GameFolderProgressError.tooManyRecords }
        try requireDownloaded(url)
        guard let bytes = try readBytes(at: url, limit: maximumRecordBytes) else { return nil }
        budget -= 1
        return try GameFolderProgressRecord.decode(bytes)
    }

    private static func readBytes(at url: URL, limit: Int) throws -> Data? {
        // O_NOFOLLOW also rejects dangling symlinks. O_NONBLOCK prevents an
        // unexpected FIFO from blocking before its type can be checked.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw GameFolderProgressError.invalidRecord }
            throw GameFolderProgressError.unavailable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw GameFolderProgressError.invalidRecord }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw GameFolderProgressError.invalidRecord }
        return bytes
    }

    private static func installationIdentity(in directory: URL) throws -> UUID {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let file = folder.appendingPathComponent("writer-id")
        if let bytes = try readBytes(at: file, limit: 64), let value = String(data: bytes, encoding: .utf8),
           let id = UUID(uuidString: value) { return id }
        let id = UUID()
        try Data(id.uuidString.utf8).write(to: file, options: .atomic)
        return id
    }
}

/// All coordination is confined to one background operation. Only Foundation's
/// cancellation method is called from the timer queue to unblock a provider.
private final class FolderCoordination: @unchecked Sendable {
    private let coordinator = NSFileCoordinator(filePresenter: nil)

    func perform<T>(_ work: (FolderCoordination) throws -> T) rethrows -> T {
        let cancellation = DispatchWorkItem { [coordinator = self] in coordinator.coordinator.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(25), execute: cancellation)
        defer { cancellation.cancel() }
        return try work(self)
    }

    func read<T>(_ url: URL, _ work: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try work(coordinated) }
        }
        if let error { throw error }
        guard let result else { throw GameFolderProgressError.unavailable }
        return try result.get()
    }

    func write<T>(_ url: URL, _ work: (URL) throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try work(coordinated) }
        }
        if let error { throw error }
        guard let result else { throw GameFolderProgressError.unavailable }
        return try result.get()
    }
}
#endif

#if os(iOS)
import Observation

@MainActor @Observable
final class GameFolderProgressSync {
    private static let selectionKey = "progress.files.v1.selection"
    private var selection: GameFolderSelection?
    @ObservationIgnored private var pending: GameFolderProgressRecord?
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    private(set) var problem: String?

    var folderName: String? { selection?.name }

    init() {
        guard GameProgressBuild.usesFolder, GameProgressBuild.allowsLiveStorage,
              let bytes = UserDefaults.standard.data(forKey: Self.selectionKey),
              bytes.count <= GameFolderSelection.maximumBookmarkBytes * 2 else { return }
        selection = try? JSONDecoder().decode(GameFolderSelection.self, from: bytes)
    }

    func choose(_ folder: URL) async -> Bool {
        guard GameProgressBuild.usesFolder, GameProgressBuild.allowsLiveStorage, !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }
        do {
            let chosen = try await Task.detached(priority: .utility) { try GameFolderProgressFiles.choose(folder) }.value
            try remember(chosen)
            pending = nil
            lastChecked = nil
            problem = nil
            return true
        } catch {
            show(error)
            return false
        }
    }

    func disconnect() {
        guard GameProgressBuild.allowsLiveStorage, !isChecking, selection != nil else { return }
        UserDefaults.standard.removeObject(forKey: Self.selectionKey)
        selection = nil
        pending = nil
        lastChecked = nil
        problem = nil
    }

    func check(with engine: SDBEngine) {
        guard GameProgressBuild.usesFolder, GameProgressBuild.allowsLiveStorage, !isChecking,
              let selection, let snapshot = engine.progressPortableSnapshot,
              let progress = GameFolderProgressRecord(snapshot: snapshot),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundle = Bundle.main.bundleIdentifier else { return }
        let identity = support.appendingPathComponent(bundle).appendingPathComponent("FolderProgressSync", isDirectory: true)
        isChecking = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try GameFolderProgressFiles.exchange(selection: selection, local: progress, identityDirectory: identity) }
            }.value
            guard let self else { return }
            defer { self.isChecking = false }
            do {
                let receipt = try result.get()
                if let renewed = receipt.renewed { try self.remember(renewed) }
                if receipt.progress != progress { self.pending = receipt.progress }
                self.lastChecked = Date()
                self.problem = nil
            } catch { self.show(error) }
        }
    }

    func applyPending(to engine: SDBEngine) {
        guard engine.gameMenuType == 1, let pending else { return }
        self.pending = nil
        if !engine.importValidatedProgress(pending.snapshot) {
            problem = "The shared progress couldn’t be saved. Try Sync Now again from Options."
        }
    }

    func show(_ error: Error) {
        problem = (error as? GameFolderProgressError ?? .unavailable).localizedDescription
    }

    private func remember(_ selection: GameFolderSelection) throws {
        let bytes = try JSONEncoder().encode(selection)
        UserDefaults.standard.set(bytes, forKey: Self.selectionKey)
        self.selection = selection
    }
}
#endif
