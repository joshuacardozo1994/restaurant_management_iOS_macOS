//
//  POSContainer.swift
//  Durigo
//
//  Top-level POS view. Hosts a 2-tab segmented switcher between the new
//  POS (table grid + take order) and the existing Bill Generator.
//
//  This view is what `Home.swift` routes `.pos` to.
//

import SwiftUI

enum POSTab: String, CaseIterable, Identifiable {
    case pos = "POS"
    case billGenerator = "Bill Generator"

    var id: String { rawValue }
}

struct POSContainerView: View {
    @Environment(Session.self) private var session
    @EnvironmentObject private var navigation: Navigation
    @State private var tab: POSTab = .pos
    @State private var store: POSStore?

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(POSTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.top, DesignTokens.spacingM)
            .padding(.bottom, DesignTokens.spacingS)

            Divider().opacity(0.4)
                .onAppear { openBillGeneratorIfAsked() }
                .onChange(of: navigation.showBillGenerator) { openBillGeneratorIfAsked() }

            Group {
                switch tab {
                case .pos:
                    if let store {
                        TablesGridView(store: store)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .billGenerator:
                    BillGenerator()
                }
            }
        }
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
        tab = .billGenerator
    }
}
