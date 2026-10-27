#!/usr/bin/env bash
# Created by Angelo Cammalleri on 27.10.2026.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-progress-sync.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
# This fixture supplies the engine boundary only. Original PSH0 validation and
# merge semantics are exercised by test_save_store.sh and test_menu_actions.sh.
cat > "$task_temp/SDBEngine.swift" <<'SWIFT'
// Created by Angelo Cammalleri on 27.10.2026.
import Foundation
@MainActor final class SDBEngine {
    var failure: String?
    var gameMenuType = 1
    var progressPortableSnapshot: [String: Any]?
    var acceptsImport = true
    private(set) var imports: [[String: Any]] = []
    init(progress: [String: Any]) { progressPortableSnapshot = progress }
    static func mergeProgress(_ local: [String: Any], remote: [String: Any]) -> [String: Any]? {
        guard local["schema"] as? Int == 1, remote["schema"] as? Int == 1,
              let a = local["value"] as? Int, let b = remote["value"] as? Int else { return nil }
        return ["schema": 1, "value": max(a, b)]
    }
    func importValidatedProgress(_ snapshot: [String: Any]) -> Bool {
        imports.append(snapshot)
        guard acceptsImport else { return false }
        progressPortableSnapshot = snapshot
        return true
    }
}
SWIFT
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -module-cache-path "$task_temp/module-cache" "$project_root/Sources/Host/GameProgressSync.swift" \
  "$task_temp/SDBEngine.swift" \
  "$project_root/Tests/ProgressSyncTests.swift" -o "$task_temp/ProgressSyncTests"
SDB_SAVE_DIRECTORY="$task_temp/save" SDB_UI_TEST=1 SDB_MUTE_AUDIO=1 "$task_temp/ProgressSyncTests"
