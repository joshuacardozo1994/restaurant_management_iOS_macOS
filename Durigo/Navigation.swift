//
//  Navigation.swift
//  Durigo
//
//  iOS navigation structure mirroring the web's sidebar groups:
//  Overview / Operations / Management / Analytics + a top-level Settings.
//
//  iPhone uses the first 4 entries as bottom tabs and a "More" tab for the
//  rest; iPad shows the full grouped list in the sidebar.
//

import SwiftUI

enum NavigationItem: Hashable, CaseIterable, Identifiable {
    case dashboard
    case pos
    case kitchen
    case billing
    case reservations
    case menu
    case modifiers
    case discounts
    case inventory
    case users
    case reports
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard:    "Dashboard"
        case .pos:          "POS"
        case .kitchen:      "Kitchen"
        case .billing:      "Billing"
        case .reservations: "Reservations"
        case .menu:         "Menu"
        case .modifiers:    "Modifiers"
        case .discounts:    "Discounts"
        case .inventory:    "Inventory"
        case .users:        "Users"
        case .reports:      "Reports"
        case .settings:     "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:    "square.grid.2x2"
        case .pos:          "cart"
        case .kitchen:      "fork.knife"
        case .billing:      "doc.text"
        case .reservations: "calendar"
        case .menu:         "book"
        case .modifiers:    "tag"
        case .discounts:    "ticket"
        case .inventory:    "shippingbox"
        case .users:        "person.2"
        case .reports:      "chart.bar.doc.horizontal"
        case .settings:     "gearshape"
        }
    }
}

enum NavigationSection: CaseIterable, Identifiable {
    case overview
    case operations
    case management
    case analytics

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:   "Overview"
        case .operations: "Operations"
        case .management: "Management"
        case .analytics:  "Analytics"
        }
    }

    var items: [NavigationItem] {
        switch self {
        case .overview:   [.dashboard]
        case .operations: [.pos, .kitchen, .billing, .reservations]
        case .management: [.menu, .modifiers, .discounts, .inventory, .users]
        case .analytics:  [.reports]
        }
    }
}

// MARK: - Who sees what

extension NavigationItem {
    /// The roles that can open this screen. Mirrors the web app's page access
    /// (proxy.ts), with one difference: waiters also get Billing, which on iOS
    /// is the Bill Generator's bill history they print and settle from. The
    /// server still checks every request, so this only hides what a role
    /// couldn't use anyway.
    var allowedRoles: Set<String> {
        switch self {
        case .dashboard:                                  ["ADMIN"]
        case .pos, .reservations:                         ["ADMIN", "WAITER", "CASHIER"]
        case .kitchen:                                    ["ADMIN", "KITCHEN"]
        case .billing:                                    ["ADMIN", "CASHIER", "WAITER"]
        case .reports:                                    ["ADMIN", "CASHIER"]
        case .menu, .modifiers, .discounts, .inventory, .users: ["ADMIN"]
        case .settings:                                   ["ADMIN", "WAITER", "KITCHEN", "CASHIER"]
        }
    }

    func isAllowed(for role: String?) -> Bool {
        guard let role else { return false }
        return allowedRoles.contains(role.uppercased())
    }
}

/// Bottom tabs on iPhone (compact): the first four of these the role can use.
/// Everything else the role can use lives behind the "More" tab.
func iPhoneRootTabs(for role: String?) -> [NavigationItem] {
    // Admins keep the original Dashboard/POS/Billing/Reports tabs; Kitchen comes
    // last so it's only a tab for roles with room for it (kitchen staff)
    Array([NavigationItem.dashboard, .pos, .billing, .reports, .kitchen]
        .filter { $0.isAllowed(for: role) }
        .prefix(4))
}

/// The screen a role starts on: the requested one if allowed, else the
/// first screen that role works in (as the web sends each role home)
func startingItem(for role: String?, requested: NavigationItem) -> NavigationItem {
    if requested.isAllowed(for: role) { return requested }
    return [NavigationItem.pos, .kitchen, .billing, .dashboard].first { $0.isAllowed(for: role) } ?? .settings
}

@Observable class Navigation: ObservableObject {
    /// Resolved from `--start-tab=` launch args. Used as both the initial
    /// `selection` and (on iPhone) the deep-link target for the More tab's
    /// NavigationStack — exposing this as a static lets Home compute its
    /// initial morePath synchronously at @State init time.
    static func argDerivedSelection() -> NavigationItem {
        let args = CommandLine.arguments
        if args.contains("--start-tab=dashboard")     { return .dashboard }
        if args.contains("--start-tab=pos")           { return .pos }
        if args.contains("--start-tab=kitchen")       { return .kitchen }
        if args.contains("--start-tab=billing")       { return .billing }
        if args.contains("--start-tab=history")       { return .billing }      // back-compat
        if args.contains("--start-tab=reservations")  { return .reservations }
        if args.contains("--start-tab=menu")          { return .menu }
        if args.contains("--start-tab=modifiers")     { return .modifiers }
        if args.contains("--start-tab=discounts")     { return .discounts }
        if args.contains("--start-tab=inventory")     { return .inventory }
        if args.contains("--start-tab=users")         { return .users }
        if args.contains("--start-tab=reports")       { return .reports }
        if args.contains("--start-tab=stats")         { return .dashboard }    // back-compat
        if args.contains("--start-tab=settings")      { return .settings }
        return .pos
    }

    var selection: NavigationItem = Navigation.argDerivedSelection()
}
