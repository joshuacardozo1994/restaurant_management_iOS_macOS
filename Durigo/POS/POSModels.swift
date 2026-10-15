//
//  POSModels.swift
//  Durigo
//
//  DTOs for the POS feature, mirroring the web's Prisma types as exposed by
//  /api/tables, /api/pos/orders, /api/menu/full and the SSE event stream.
//
//  These are decode-only structs (Decodable). For request bodies we use
//  small ad-hoc Encodable structs in POSStore so we don't drift between
//  what the server returns and what we send.
//

import Foundation

// MARK: - Enums (mirror web Prisma enums, lowercased status strings allowed)

enum TableStatus: String, Codable, Hashable {
    case available = "AVAILABLE"
    case occupied = "OCCUPIED"
    case reserved = "RESERVED"
    case maintenance = "MAINTENANCE"
    case billRequested = "BILL_REQUESTED"

    static func from(_ raw: String) -> TableStatus {
        TableStatus(rawValue: raw.uppercased()) ?? .available
    }
}

enum OrderStatus: String, Codable, Hashable {
    case pending = "PENDING"
    case confirmed = "CONFIRMED"
    case preparing = "PREPARING"
    case ready = "READY"
    case served = "SERVED"
    case completed = "COMPLETED"
    case cancelled = "CANCELLED"
}

enum OrderItemStatus: String, Codable, Hashable {
    case pending = "PENDING"
    case preparing = "PREPARING"
    case ready = "READY"
    case served = "SERVED"
    case cancelled = "CANCELLED"
}

enum OrderType: String, Codable, Hashable {
    case dineIn = "DINE_IN"
    case takeaway = "TAKEAWAY"
    case delivery = "DELIVERY"
}

// MARK: - Table + Order DTOs

struct POSTable: Decodable, Identifiable, Hashable {
    let id: String
    let number: Int
    let capacity: Int
    let status: String
    let orders: [POSOrder]?
    /// Part of the floor ("Inside", "Garden"); the floor groups tiles by it
    var section: String? = nil

    var statusEnum: TableStatus { TableStatus.from(status) }

    /// Active (non-completed/cancelled) orders that still have at least one
    /// non-cancelled item — matches the web's "live order" filter on
    /// /pos page (RealtimeTablesGrid.tsx).
    var liveOrders: [POSOrder] {
        (orders ?? []).filter { order in
            !["COMPLETED", "CANCELLED"].contains(order.status) &&
            (order.items?.contains(where: { $0.status != "CANCELLED" }) ?? false)
        }
    }

    var unpaidTotal: Double {
        liveOrders.reduce(0) { sum, order in
            sum + (order.items ?? [])
                .filter { $0.status != "CANCELLED" }
                .reduce(0) { $0 + ($1.unitPrice * Double($1.quantity)) }
        }
    }

    /// Effective status: if DB says OCCUPIED but no live orders remain,
    /// treat as AVAILABLE (mirrors web logic).
    var effectiveStatus: TableStatus {
        let db = statusEnum
        if (db == .occupied || db == .billRequested) && liveOrders.isEmpty {
            return .available
        }
        return db
    }
}

/// Active waiter on a table = the waiter on the most recent live order.
/// Returns nil if there are no live orders or none have a waiter joined.
/// Used by TableCardView to show "served by X" on occupied cards.
extension POSTable {
    var activeWaiterName: String? {
        liveOrders.last?.waiter?.name
    }
}

struct POSOrder: Decodable, Identifiable, Hashable {
    let id: String
    let orderNumber: String?
    let tableId: String?
    let type: String?
    let status: String
    let items: [POSOrderItem]?
    let createdAt: String?
    let waiterId: String?
    let notes: String?
    /// Nested waiter joined by the server (`include: { waiter: true }` in
    /// fetchActiveOrders). Used for the table-card waiter line.
    let waiter: WaiterMini?

    struct WaiterMini: Decodable, Hashable {
        let id: String?
        let name: String?
    }
}

struct POSOrderItem: Decodable, Identifiable, Hashable {
    let id: String
    let menuItemId: String?
    let variantTemplateId: String?
    let quantity: Int
    let unitPrice: Double
    let status: String
    let notes: String?
    /// Snapshot fields kept on the OrderItem itself by the server so the
    /// historical name is preserved even if the menu item is later renamed.
    let itemName: String?
    let servingSizeName: String?
    /// Nested menu item / variant — live source of truth for naming.
    /// Preferred over the snapshot fields when present.
    let menuItem: NamedRef?
    let variantTemplate: NamedRef?
    /// Extras chosen when ordering ("Extra cheese"). Their price is already
    /// in `unitPrice`; these are for display.
    var modifiers: [OrderItemModifier]? = nil

    struct NamedRef: Decodable, Hashable {
        let id: String?
        let name: String?
        let description: String?
    }

    // The names saved on the line when it was ordered come first, so a
    // bill doesn't change if the menu item is renamed or the variant deleted
    var displayName: String {
        itemName ?? menuItem?.name ?? "Item"
    }

    var displayVariant: String? {
        servingSizeName ?? variantTemplate?.name
    }
}

// MARK: - Floor helpers

/// Where a dish is on its way to the table, as the floor and the bill show it
enum DishStage: Int, CaseIterable, Identifiable {
    case todo, cooking, ready, served

    var id: Int { rawValue }

    init(itemStatus: String) {
        switch itemStatus.uppercased() {
        case "PREPARING": self = .cooking
        case "READY": self = .ready
        case "SERVED", "COMPLETED": self = .served
        default: self = .todo   // PENDING, CONFIRMED
        }
    }

    var title: String {
        switch self {
        case .todo: "To do"
        case .cooking: "Cooking"
        case .ready: "Ready"
        case .served: "Served"
        }
    }
}

enum POSTime {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return fractional.date(from: iso) ?? plain.date(from: iso)
    }

    /// "7m", "1h 4m", "3d"
    static func elapsed(since: Date, now: Date) -> String {
        let mins = max(0, Int(now.timeIntervalSince(since) / 60))
        if mins < 60 { return "\(mins)m" }
        if mins < 24 * 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins / (24 * 60))d"
    }

    /// "20:30" → "8:30"
    static func clock(_ hhmm: String) -> String {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count >= 2 else { return hhmm }
        return "\(p[0] % 12 == 0 ? 12 : p[0] % 12):\(String(format: "%02d", p[1]))"
    }

    /// Today's date in the restaurant's time zone, "2026-10-15"
    static var todayIST: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return f.string(from: Date())
    }
}

extension POSTable {
    /// Every dish still on the table's bill (not cancelled), oldest order first
    var liveItems: [POSOrderItem] {
        liveOrders.flatMap { ($0.items ?? []).filter { $0.status != "CANCELLED" } }
    }

    /// When the table's oldest unpaid order was placed
    var seatedSince: Date? {
        liveOrders.compactMap { POSTime.date($0.createdAt) }.min()
    }

    /// Seated or waiting for the bill
    var isSeated: Bool { effectiveStatus == .occupied || effectiveStatus == .billRequested }

    /// One entry per dish line, in order, for the tile's progress line
    var dishStages: [DishStage] { liveItems.map { DishStage(itemStatus: $0.status) } }
}

// MARK: - Menu DTO (POS uses /api/menu/full which is the same shape as
// MenuLoader's `Category` already in the codebase, so we reuse that.)

// MARK: - Encodable request bodies (used by POSStore)

struct CreateOrderRequest: Encodable {
    let tableId: String?
    let type: String   // "DINE_IN" / "TAKEAWAY" / "DELIVERY"
    let items: [Item]
    let notes: String?
    let customerName: String?
    let customerPhone: String?
    let customerAddress: String?
    let waiterId: String?   // optional override; server falls back to JWT user
    /// Same key on a retry of the same order, so a resend after a dropped
    /// connection returns the order already placed instead of a duplicate
    let idempotencyKey: String?

    struct Item: Encodable {
        let menuItemId: String
        let variantTemplateId: String?
        let quantity: Int
        let unitPrice: Double
        let notes: String?
        /// The server prices these and adds them to the line
        let modifierIds: [String]
    }
}

/// A modifier recorded on an order line, with its price when ordered
struct OrderItemModifier: Codable, Hashable {
    let price: Int
    let modifier: Ref

    struct Ref: Codable, Hashable {
        let id: String
        let name: String
    }
}

extension Array where Element == OrderItemModifier {
    /// "+ Extra cheese, No onion", or nil when there are none
    var summary: String? {
        isEmpty ? nil : "+ " + map(\.modifier.name).joined(separator: ", ")
    }
}

// MARK: - Waiter directory (returned by GET /api/users/waiters)

struct WaiterRef: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String

    /// A name found on bills that isn't a current staff member (a former
    /// waiter, "Unknown"). Its id is "name:<name>" since it has no user.
    static let otherRole = "OTHER"
    static func other(named name: String) -> WaiterRef {
        WaiterRef(id: "name:\(name)", name: name, role: otherRole)
    }
}

// MARK: - Table groups (merge feature)

struct POSTableGroup: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let primaryTableId: String
    let totalCapacity: Int
    let active: Bool
    let members: [Member]

    struct Member: Decodable, Identifiable, Hashable {
        let id: String
        let tableId: String
        let table: TableMini

        struct TableMini: Decodable, Hashable {
            let id: String
            let number: Int
            let capacity: Int
            let status: String?
        }
    }

    /// Friendly label for display when `name` is not set.
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return "Tables \(members.map { String($0.table.number) }.sorted().joined(separator: ", "))"
    }
}

struct CreateGroupRequest: Encodable {
    let name: String?
    let tableIds: [String]
    let primaryTableId: String
}

// MARK: - Reservations

struct POSReservation: Decodable, Identifiable, Hashable {
    let id: String
    let tableId: String
    let guestName: String
    let guestPhone: String
    let guestCount: Int
    let date: String
    let time: String
    let duration: Int
    let status: String
    let notes: String?
}

struct CreateReservationRequest: Encodable {
    let tableId: String
    let guestName: String
    let guestPhone: String
    let guestCount: Int
    let date: String   // YYYY-MM-DD
    let time: String   // HH:MM
    let duration: Int  // minutes
    let notes: String?
}

// MARK: - Settled bill (returned by POST /api/orders/:id/payment)

/// What the server recorded for a table's payment, in whole rupees
struct SettledBill: Decodable, Equatable {
    let gross: Int
    let discount: Int
    let subtotal: Int
    let tax: Int
    let gstTax: Int
    let vatTax: Int
    let total: Int
}
