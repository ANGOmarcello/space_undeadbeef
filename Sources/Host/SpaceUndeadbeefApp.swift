//
//  SpaceUndeadbeefApp.swift
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

import SwiftUI

@main
struct SpaceUndeadbeefApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("SPACE UNDEADBEEF", id: "game") {
            GameView()
                .preferredColorScheme(.dark)
                .frame(minWidth: GameLayout.width, minHeight: GameLayout.height)
        }
        .defaultSize(width: GameLayout.width * 2, height: GameLayout.height * 2)
        .windowStyle(.hiddenTitleBar)
        #else
        WindowGroup {
            #if os(watchOS)
            NavigationStack {
                GameView()
                    .preferredColorScheme(.dark)
            }
            .environment(\.layoutDirection, .leftToRight)
            #else
            GameView()
                .preferredColorScheme(.dark)
            #endif
        }
        #endif
    }
}
