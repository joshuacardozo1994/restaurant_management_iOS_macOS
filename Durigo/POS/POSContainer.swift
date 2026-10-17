//
//  POSContainer.swift
//  Durigo
//
//  Top-level POS view: the floor (tables and the selected table's bill),
//  with the Bill Generator in the floor's toolbar, pushed over it.
//
//  This view is what `Home.swift` routes `.pos` to.
//

import SwiftUI

struct POSContainerView: View {
    @Environment(Session.self) private var session
    @EnvironmentObject private var navigation: Navigation
    /// The Bill Generator in place of the floor
    @State private var showingGenerator = false
    @State private var store: POSStore?

    /// Sample tables for the floor's skeleton
    private var placeholder: POSStore { POSStore.placeholder(api: APIClient(session: session)) }

    var body: some View {
        NavigationRoot {
            Group {
                if let store, store.tablesLoaded {
                    TablesGridView(store: store, onOpenBillGenerator: { showingGenerator = true })
                } else {
                    // Loading: the floor with sample tables, as placeholders
                    TablesGridView(store: placeholder, onOpenBillGenerator: {})
                        .skeleton(true)
                        .accessibilityIdentifier("floor-loading")
                }
            }
            // The Bill Generator pushed over the floor: the system back button returns
            .navigationDestination(isPresented: $showingGenerator) { BillGenerator() }
        }
        .onAppear {
            openBillGeneratorIfAsked()
            #if DEBUG
            // `--pos-route=generator` (screenshots)
            if CommandLine.arguments.contains("--pos-route=generator") { showingGenerator = true }
            #endif
        }
        .onChange(of: navigation.showBillGenerator) { openBillGeneratorIfAsked() }
        .task {
            // First time: make the store. Menu and waiters load alongside the
            // floor, not before it: the floor is what the screen is for
            let s: POSStore
            if let store { s = store } else {
                s = POSStore(api: APIClient(session: session))
                store = s
                Task { await s.loadMenu() }
                Task { await s.loadWaiters() }
            }
            // Every appearance: the live data (tables, groups, bookings) can
            // have changed on another tab and SSE doesn't replay missed events,
            // so read it again before listening
            async let tables: Void = s.loadTables()
            async let groups: Void = s.loadTableGroups()
            async let reservations: Void = s.loadUpcomingReservations()
            _ = await (tables, groups, reservations)
            s.startSSE()
        }
        .onDisappear {
            store?.stopSSE()
        }
    }
}

extension POSContainerView {
    /// A regenerated bill was just loaded into the Bill Generator: show it
    fileprivate func openBillGeneratorIfAsked() {
        guard navigation.showBillGenerator else { return }
        navigation.showBillGenerator = false
        showingGenerator = true
    }
}
