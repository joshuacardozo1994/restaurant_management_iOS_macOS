//
//  DurigoApp.swift
//  Durigo
//
//  Created by Joshua Cardozo on 27/10/23.
//

import SwiftUI
import TipKit
import SwiftData

@main
struct DurigoApp: App {
    let container: ModelContainer
    @State private var session = Session()

    init() {
        container = Self.makeContainer()
    }

    /// Opens the bill store. If it can't be opened (say a migration fails),
    /// the app would otherwise crash on every launch; instead the store is
    /// moved aside (kept, not deleted) and a fresh one created. Bills already
    /// uploaded come back from the server.
    private static func makeContainer() -> ModelContainer {
        func open() throws -> ModelContainer {
            try ModelContainer(for: BillHistoryItem.self, migrationPlan: BillHistoryItemsMigrationPlan.self)
        }
        do {
            return try open()
        } catch {
            print("Bill store couldn't be opened (\(error)); moving it aside and starting fresh")
            let store = URL.applicationSupportDirectory.appending(path: "default.store")
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-shm", "-wal"] {
                let file = URL(filePath: store.path() + suffix)
                guard FileManager.default.fileExists(atPath: file.path()) else { continue }
                try? FileManager.default.moveItem(at: file, to: URL(filePath: store.path() + ".unreadable-\(stamp)" + suffix))
            }
            do {
                return try open()
            } catch {
                fatalError("Failed to initialize model container: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isSignedIn {
                    Home()
                } else {
                    LoginView()
                }
            }
            .environment(session)
            // Every form (settings, sheets) as grouped sections, as on iOS; the
            // Mac's default form style right-aligns labels in a narrow column
            .formStyle(.grouped)
            // Text grows up to the largest standard size; beyond that (the
            // accessibility sizes) the table cards, kitchen columns and bill
            // rows split words, so they stop growing there
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .task { await session.attemptDebugAutoSignIn() }
        }
        .modelContainer(container)
    }
}
