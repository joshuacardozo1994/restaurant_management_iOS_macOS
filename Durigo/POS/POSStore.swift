//
//  POSStore.swift
//  Durigo
//
//  Observable store backing the POS feature. Holds tables + admin-shape menu
//  + an SSE subscription so the tables grid stays live. All requests go
//  through APIClient (cookie auth, 401 handling).
//
//  AdminMenuItem / AdminCategory / AdminVariantTemplate are reused from
//  Menu/MenuEditor.swift — the same shape /api/admin/menu returns.
//

import Foundation
import SwiftUI

// MARK: - Variant pricing helper

extension AdminVariantTemplate {
    /// Effective unit price given a base price. The web stores `priceEquation`
    /// strings like "1.5", "0.5*x", "x+100" — `x` is the base. We try numeric
    /// (multiplier shorthand) first, fall back to NSExpression, fall back to
    /// the explicit `multiplier` field.
    func price(forBase base: Double) -> Double {
        let trimmed = priceEquation.trimmingCharacters(in: .whitespaces)
        if let mult = Double(trimmed) {
            return base * mult
        }
        let substituted = trimmed.replacingOccurrences(of: "x", with: "(\(base))")
        if let val = NSExpression(format: substituted).expressionValue(with: nil, context: nil) as? NSNumber {
            return val.doubleValue
        }
        return base * multiplier
    }
}

// MARK: - Cart line item used by TakeOrderView

struct CartLine: Identifiable {
    let id = UUID()
    let menuItem: AdminMenuItem
    let variant: AdminVariantTemplate?
    var quantity: Int
    var notes: String?

    var unitPrice: Double {
        let base = Double(menuItem.price)
        if let variant {
            return variant.price(forBase: base)
        }
        return base
    }

    var lineTotal: Double { unitPrice * Double(quantity) }
}

// MARK: - Store

@MainActor
@Observable
final class POSStore {
    var tables: [POSTable] = []
    var menu: [AdminMenuItem] = []
    var categories: [AdminCategory] = []
    var waiters: [WaiterRef] = []
    var tableGroups: [POSTableGroup] = []
    /// Upcoming reservations — surfaces the next-arriving party on each
    /// Available table's card. Includes today + tomorrow + further dates.
    var upcomingReservations: [POSReservation] = []
    /// Currently selected waiter for new orders. Persisted across orders
    /// within a session via UserDefaults so the picker remembers the last
    /// choice even if POSStore is recreated.
    var selectedWaiterId: String? {
        didSet { UserDefaults.standard.set(selectedWaiterId, forKey: "POS.selectedWaiterId") }
    }
    var isLoading: Bool = false
    var lastError: String?
    var sseConnected: Bool = false

    private let api: APIClient
    private var sseTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
        self.selectedWaiterId = UserDefaults.standard.string(forKey: "POS.selectedWaiterId")
    }

    // MARK: Table groups (merge)

    func loadTableGroups() async {
        do {
            let data = try await api.get("/api/tables/groups")
            self.tableGroups = try JSONDecoder().decode([POSTableGroup].self, from: data)
        } catch {
            // Non-fatal: groups are an optional display layer.
        }
    }

    /// Set of table IDs currently inside any merged group — used to render
    /// the merged badge on table cards and gate which tables can be merged.
    var groupedTableIds: Set<String> {
        Set(tableGroups.flatMap { $0.members.map { $0.tableId } })
    }

    @discardableResult
    func mergeTables(name: String?, tableIds: [String], primaryTableId: String) async throws -> POSTableGroup {
        let payload = CreateGroupRequest(name: name, tableIds: tableIds, primaryTableId: primaryTableId)
        let data = try await api.postJSON("/api/tables/groups", payload: payload)
        let group = try JSONDecoder().decode(POSTableGroup.self, from: data)
        tableGroups.append(group)
        return group
    }

    func unmergeGroup(_ groupId: String) async throws {
        _ = try await api.delete("/api/tables/groups/\(groupId)")
        tableGroups.removeAll { $0.id == groupId }
    }

    // MARK: Reservations

    func loadUpcomingReservations() async {
        do {
            let data = try await api.get("/api/reservations/upcoming")
            // The endpoint sometimes returns a bare array, sometimes a
            // wrapped object — handle both shapes defensively.
            if let arr = try? JSONDecoder().decode([POSReservation].self, from: data) {
                self.upcomingReservations = arr
            } else {
                struct Wrapper: Decodable { let reservations: [POSReservation]? }
                self.upcomingReservations = (try? JSONDecoder().decode(Wrapper.self, from: data))?.reservations ?? []
            }
        } catch {
            // Non-fatal — reservation indicator is purely additive UX.
        }
    }

    /// Returns the next reservation for a given table (PENDING / CONFIRMED,
    /// soonest first). Used by TableCardView for the Available-card hint.
    func nextReservation(for tableId: String) -> POSReservation? {
        upcomingReservations
            .filter { $0.tableId == tableId && ["PENDING", "CONFIRMED"].contains($0.status.uppercased()) }
            .sorted { ($0.date, $0.time) < ($1.date, $1.time) }
            .first
    }

    @discardableResult
    func createReservation(tableId: String,
                           guestName: String,
                           guestPhone: String,
                           guestCount: Int,
                           date: String,
                           time: String,
                           duration: Int = 120,
                           notes: String? = nil) async throws -> POSReservation {
        let payload = CreateReservationRequest(
            tableId: tableId,
            guestName: guestName,
            guestPhone: guestPhone,
            guestCount: guestCount,
            date: date,
            time: time,
            duration: duration,
            notes: notes
        )
        let data = try await api.postJSON("/api/reservations", payload: payload)
        return try JSONDecoder().decode(POSReservation.self, from: data)
    }

    func loadWaiters() async {
        do {
            let data = try await api.get("/api/users/waiters")
            self.waiters = try JSONDecoder().decode([WaiterRef].self, from: data)
            // If the previously-selected waiter is no longer active or
            // doesn't exist, drop the selection so the UI prompts for one.
            if let id = selectedWaiterId, !waiters.contains(where: { $0.id == id }) {
                selectedWaiterId = nil
            }
        } catch {
            lastError = "Failed to load waiters: \(error.localizedDescription)"
        }
    }

    // MARK: Tables

    func loadTables() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await api.get("/api/tables")
            let decoded = try JSONDecoder().decode([POSTable].self, from: data)
            self.tables = decoded.sorted { $0.number < $1.number }
        } catch {
            lastError = "Failed to load tables: \(error.localizedDescription)"
        }
    }

    // MARK: Menu (admin shape — real CUIDs)

    func loadMenu() async {
        do {
            async let menuData = api.get("/api/admin/menu")
            async let catData = api.get("/api/admin/categories")
            let decoder = JSONDecoder()
            self.menu = try decoder.decode([AdminMenuItem].self, from: try await menuData)
            self.categories = try decoder.decode([AdminCategory].self, from: try await catData)
        } catch {
            lastError = "Failed to load menu: \(error.localizedDescription)"
        }
    }

    // MARK: Place order

    @discardableResult
    func placeOrder(tableId: String?,
                    type: OrderType,
                    cart: [CartLine],
                    notes: String? = nil,
                    customerName: String? = nil,
                    customerPhone: String? = nil,
                    idempotencyKey: String) async throws -> POSOrder {
        let payload = CreateOrderRequest(
            tableId: tableId,
            type: type.rawValue,
            items: cart.map { line in
                CreateOrderRequest.Item(
                    menuItemId: line.menuItem.id,
                    variantTemplateId: line.variant?.id,
                    quantity: line.quantity,
                    unitPrice: line.unitPrice,
                    notes: line.notes
                )
            },
            notes: notes,
            customerName: customerName,
            customerPhone: customerPhone,
            customerAddress: nil,
            waiterId: selectedWaiterId,
            idempotencyKey: idempotencyKey
        )
        let data = try await api.postJSON("/api/pos/orders", payload: payload)
        let order = try JSONDecoder().decode(POSOrder.self, from: data)

        // Optimistic local update so UI reflects new order before SSE arrives.
        if let tableId, type == .dineIn,
           let idx = tables.firstIndex(where: { $0.id == tableId }) {
            let existing = tables[idx]
            var newOrders = existing.orders ?? []
            newOrders.append(order)
            tables[idx] = POSTable(
                id: existing.id,
                number: existing.number,
                capacity: existing.capacity,
                status: "OCCUPIED",
                orders: newOrders
            )
        }
        return order
    }

    // MARK: Bill request + payment

    /// Mark a table as BILL_REQUESTED — flips the visual state on every
    /// connected device (waiters know to deliver the bill, cashier knows
    /// payment is pending). Mirrors the web's PUT /api/admin/tables/{id}.
    func requestBill(tableId: String) async throws {
        struct Payload: Encodable { let status: String }
        _ = try await api.putJSON("/api/admin/tables/\(tableId)", payload: Payload(status: "BILL_REQUESTED"))
        // Optimistic: flip local state immediately.
        if let idx = tables.firstIndex(where: { $0.id == tableId }) {
            let t = tables[idx]
            tables[idx] = POSTable(id: t.id, number: t.number, capacity: t.capacity,
                                    status: "BILL_REQUESTED", orders: t.orders)
        }
    }

    // MARK: Manage tables

    private struct TableBody: Encodable {
        var number: Int?
        var capacity: Int?
        var status: String?
    }

    func addTable(number: Int, capacity: Int) async throws {
        _ = try await api.postJSON("/api/admin/tables", payload: TableBody(number: number, capacity: capacity))
        await loadTables()
    }

    func updateTable(id: String, number: Int? = nil, capacity: Int? = nil, status: String? = nil) async throws {
        _ = try await api.putJSON("/api/admin/tables/\(id)", payload: TableBody(number: number, capacity: capacity, status: status))
        await loadTables()
    }

    /// Admin only; the server refuses a table that still has open orders
    func deleteTable(id: String) async throws {
        _ = try await api.delete("/api/admin/tables/\(id)")
        await loadTables()
    }

    /// The table's unpaid item value split into its GST part (food, soft
    /// drinks) and VAT part (liquor), by each item's menu category; custom
    /// items fall back to their name. Same rules the server bills by.
    func grossByTax(for table: POSTable) -> (gst: Int, vat: Int) {
        let typeByItem = Dictionary(menu.map { ($0.id, $0.category.type) }, uniquingKeysWith: { a, _ in a })
        var gst = 0.0, vat = 0.0
        for order in table.liveOrders {
            for item in order.items ?? [] where item.status != "CANCELLED" {
                let value = item.unitPrice * Double(item.quantity)
                let type = item.menuItemId.flatMap { typeByItem[$0] }
                switch BillMath.taxClass(categoryType: type, name: item.displayName) {
                case .gst: gst += value
                case .vat: vat += value
                }
            }
        }
        return (Int(gst.rounded()), Int(vat.rounded()))
    }

    /// The rupee value of a discount code against a bill, or the server's
    /// reason it can't be used ("expired", "minimum order ₹500", …)
    func discountCodeValue(code: String, orderTotal: Int) async throws -> Int {
        struct Body: Encodable { let code: String; let orderTotal: Int }
        struct Response: Decodable { let valid: Bool?; let error: String?; let calculatedDiscount: Int? }
        let data = try await api.postJSON("/api/discounts/validate", payload: Body(code: code, orderTotal: orderTotal))
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.valid != false, let value = response.calculatedDiscount else {
            throw DiscountCodeError(message: response.error ?? "Invalid discount code")
        }
        return value
    }

    struct DiscountCodeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One part of a split bill
    struct Tender: Encodable, Equatable {
        let amount: Int
        let method: String
    }

    /// Settle every unpaid order on the table. The server works out the bill
    /// (GST on food, VAT on liquor), records the payments, completes the orders
    /// and frees the table in one transaction; it refuses with 409 if the bill
    /// changed since `expectedTotal` was shown, and never records a payment twice.
    /// A discount (manual or by code) is for cashiers and admins only.
    @discardableResult
    func processPayment(table: POSTable, expectedTotal: Int, method: String,
                        discount: Int? = nil, discountCode: String? = nil,
                        tenders: [Tender]? = nil) async throws -> SettledBill {
        guard let anchor = table.liveOrders.first else { throw APIError.badResponse }
        struct PaymentBody: Encodable {
            let method: String
            let expectedTotal: Int
            let discount: Int?
            let discountCode: String?
            let tenders: [Tender]?
        }
        let body = PaymentBody(method: method, expectedTotal: expectedTotal,
                               discount: discountCode == nil ? discount : nil,
                               discountCode: discountCode, tenders: tenders)
        let data = try await api.postJSON("/api/orders/\(anchor.id)/payment", payload: body)
        struct Response: Decodable { let bill: SettledBill }
        let bill = try JSONDecoder().decode(Response.self, from: data).bill
        await loadTables()
        return bill
    }

    // MARK: SSE

    func startSSE() {
        guard sseTask == nil else { return }
        sseTask = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1_000_000_000 // 1s
            while !Task.isCancelled {
                do {
                    let stream = await self.api.eventStream("/api/events")
                    await MainActor.run { self.sseConnected = true }
                    // Catch up on anything that changed while disconnected
                    await self.loadTables()
                    for try await event in stream {
                        await self.handleSSEEvent(event)
                    }
                } catch {
                    // fall through to backoff/reconnect
                }
                await MainActor.run { self.sseConnected = false }
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 30_000_000_000)
            }
        }
    }

    func stopSSE() {
        sseTask?.cancel()
        sseTask = nil
        sseConnected = false
    }

    private var reloadTask: Task<Void, Never>?

    /// Events carry the changed order or table as their data (the event name
    /// says which). Rather than patch local state and guess each table's status,
    /// reload the grid from the server, coalescing a burst of events into one fetch.
    private func handleSSEEvent(_ event: APIClient.SSEEvent) async {
        switch event.event {
        case "table_status_changed", "order_created", "order_updated", "order_status_changed",
             "payment_completed", "kitchen_update":
            scheduleReload()
        default:
            break
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadTables()
        }
    }
}
