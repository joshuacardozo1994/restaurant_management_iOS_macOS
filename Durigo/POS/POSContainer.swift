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
            // First-time setup: build the store + load the static-ish
            // data (menu, waiters) that won't change during a service.
            // Both fetches fire in parallel — they hit different endpoints
            // and don't depend on each other.
            if store == nil {
                let api = APIClient(session: session)
                let s = POSStore(api: api)
                store = s
                async let menu: Void = s.loadMenu()
                async let waiters: Void = s.loadWaiters()
                _ = await (menu, waiters)
            }
            // Every appearance: refresh the LIVE data — tables, table
            // groups, and upcoming reservations can all change while we
            // were on another tab, and SSE doesn't replay missed events.
            // Without this catch-up, the wifi reconnects but the grid
            // shows stale order counts / table statuses until the next
            // event arrives. Done before startSSE so an in-flight event
            // can't be overwritten by a slower load completing later.
            // Three fetches, three endpoints, no inter-dependency — fire
            // them concurrently so total wait = slowest, not sum.
            if let s = store {
                async let tables: Void = s.loadTables()
                async let groups: Void = s.loadTableGroups()
                async let reservations: Void = s.loadUpcomingReservations()
                _ = await (tables, groups, reservations)
                s.startSSE()
            }
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
