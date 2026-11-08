//
//  GameFolderProgressControls.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 08.11.2026.
//

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Only the public iPhone/iPad build offers Files access. The original Options
/// menu still owns all of its original controls and game settings.
struct GameFolderProgressControls: View {
    let session: GameSession
    let safeArea: CGRect
    @State private var showingProgress = false
    @State private var choosingFolder = false

    private var sync: GameFolderProgressSync { session.folderProgress }

    var body: some View {
        Group {
            if session.gameMenuType == 5 && session.isActive && session.persistenceError == nil {
                Button {
                    session.setProgressControlsOpen(true)
                    showingProgress = true
                } label: {
                    Label("iCloud Progress", systemImage: "icloud")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("icloud-progress")
                .padding(.horizontal)
                .padding(.top)
            }
        }
        .frame(width: safeArea.width, height: safeArea.height, alignment: .topTrailing)
        .position(x: safeArea.midX, y: safeArea.midY)
        .sheet(isPresented: $showingProgress, onDismiss: { session.setProgressControlsOpen(false) }) {
            NavigationStack {
                Form {
                    Section {
                        if let name = sync.folderName { LabeledContent("Folder", value: name) }
                        Button(sync.folderName == nil ? "Choose iCloud Drive Folder" : "Change Folder") {
                            choosingFolder = true
                        }
                        .accessibilityIdentifier("choose-progress-folder")
                        .disabled(sync.isChecking)

                        if sync.folderName != nil {
                            Button("Sync Now") { session.checkFolderProgress() }
                                .disabled(sync.isChecking)
                            Button("Disconnect", role: .destructive) { sync.disconnect() }
                                .disabled(sync.isChecking)
                        }
                    } footer: {
                        Text("Choose the same folder in iCloud Drive on each device. The furthest checkpoint and highest score are combined. Incoming progress takes effect at the title screen.")
                    }

                    if sync.isChecking || sync.lastChecked != nil || sync.problem != nil {
                        Section("Sync status") {
                            if sync.isChecking { ProgressView("Checking folder…") }
                            else if let problem = sync.problem { Text(problem) }
                            else if let checked = sync.lastChecked {
                                LabeledContent("Last checked", value: checked.formatted(date: .omitted, time: .shortened))
                            }
                        }
                    }
                }
                .navigationTitle("iCloud Progress")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingProgress = false }
                            .accessibilityIdentifier("close-progress-settings")
                    }
                }
                .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                    switch result {
                    case .success(let folder):
                        Task { @MainActor in
                            if await sync.choose(folder) { session.checkFolderProgress() }
                        }
                    case .failure(let error):
                        if (error as NSError).code != NSUserCancelledError { sync.show(error) }
                    }
                }
            }
        }
    }
}
#endif
