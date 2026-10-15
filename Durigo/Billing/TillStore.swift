//
//  TillStore.swift
//  Durigo
//
//  Billing's data: the Till (every table and takeaway waiting to be paid, from
//  GET /api/billing/till) and the Bills ledger (GET /api/billing/ledger for a
//  range of dates). Both reload on live events, a burst of events becoming one
//  reload, the way the dashboard's ServiceNightStore does.
//

import Foundation
import SwiftUI

// MARK: - Till

/// What one table (or one takeaway) owes, as the server groups it
struct TillBill: Decodable, Identifiable, Equatable {
    struct Line: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let quantity: Double
        let unitPrice: Double
        let status: String
        let notes: String?
        /// "GST" (food, soft drinks) or "VAT" (liquor)
        let taxClass: String
    }
    struct Customer: Decodable, Equatable {
        let name: String
        let phone: String?
    }

    let key: String
    /// Paying this order settles the whole bill
    let anchorOrderId: String
    let orderIds: [String]
    let orderNumbers: [String]
    let tableId: String?
    let tableNumber: Int?
    /// DINE_IN | TAKEAWAY | DELIVERY
    let type: String
    /// bill: asked for the bill · served: everything served · cooking: dishes still with the kitchen
    let state: String
    let waiter: String?
    let customer: Customer?
    let since: String
    let billAskedAt: String?
    let lines: [Line]

    var id: String { key }

    /// "Table 12", "Takeaway", "Delivery"
    var title: String {
        if let tableNumber { return "Table \(tableNumber)" }
        return type == "DELIVERY" ? "Delivery" : "Takeaway"
    }

    /// What goes on the tile: the table number, or P (parcel) / D (delivery)
    var tileText: String {
        if let tableNumber { return String(tableNumber) }
        return type == "DELIVERY" ? "D" : "P"
    }

    var billNumber: String? { orderNumbers.first }

    /// Food & soft drinks (GST) and liquor (VAT), in whole rupees
    var gross: (gst: Int, vat: Int) {
        var gst = 0.0, vat = 0.0
        for line in lines {
            let value = line.unitPrice * line.quantity
            if line.taxClass == "VAT" { vat += value } else { gst += value }
        }
        return (Int(gst.rounded()), Int(vat.rounded()))
    }

    /// Dishes not yet served
    var cookingCount: Int { lines.filter { DishStage(itemStatus: $0.status) != .served }.count }

    var sinceDate: Date? { POSTime.date(since) }
    var askedDate: Date? { POSTime.date(billAskedAt) }

    /// Seated (blue) or asked for the bill (amber), as on the floor
    var tileStatus: TableStatus { state == "bill" ? .billRequested : .occupied }

    /// "Pedro · asked 6m ago", "all served · 52m", "2 dishes cooking"
    func subtitle(now: Date) -> String {
        var parts: [String] = []
        if let waiter, !waiter.isEmpty { parts.append(waiter) }
        else if let customer { parts.append(customer.name) }
        switch state {
        case "bill":
            let asked = (askedDate ?? sinceDate).map { POSTime.elapsed(since: $0, now: now) }
            parts.append(asked.map { $0 == "0m" ? "just asked" : "asked \($0) ago" } ?? "asked for the bill")
        case "served":
            parts.append("all served" + (sinceDate.map { " · \(POSTime.elapsed(since: $0, now: now))" } ?? ""))
        default:
            let n = cookingCount
            parts.append("\(n) dish\(n == 1 ? "" : "es") cooking")
        }
        return parts.joined(separator: " · ")
    }

    /// The lines as Bill Generator items, for the printed receipt
    var receiptItems: [MenuItem] {
        lines.map { MenuItem(id: UUID(), name: $0.name, quantity: $0.quantity, price: $0.unitPrice) }
    }
}

// MARK: - Ledger

struct LedgerTender: Decodable, Equatable, Hashable {
    let method: String
    let amount: Int
}

/// One bill on the Bills screen: a settled table or order, or an unpaid
/// Bill Generator bill
struct LedgerBill: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let billNo: String
    let orderIds: [String]
    let at: String
    let `where`: String
    let tableNumber: Int?
    let waiter: String?
    let customer: String?
    let paid: Bool
    /// Made in the app's Bill Generator
    let fromApp: Bool
    let tenders: [LedgerTender]
    let items: Int
    let dishes: String
    let gross: Int
    let discount: Int
    let gstTax: Int
    let vatTax: Int
    let total: Int

    var date: Date? { POSTime.date(at) }
    var tax: Int { gstTax + vatTax }

    /// The bill as the receipt renderer takes it
    var amounts: BillAmounts {
        BillAmounts(gross: gross, discount: discount, subtotal: total - tax, tax: tax,
                    gstTax: gstTax, vatTax: vatTax, total: total)
    }

    /// "₹513 cash, ₹513 UPI", "UPI", or nil while unpaid
    var paidBy: String? {
        guard paid, !tenders.isEmpty else { return nil }
        if tenders.count == 1 { return PayMethod.spoken(tenders[0].method) }
        return tenders.map { "\($0.amount.rupees) \(PayMethod.spoken($0.method))" }.joined(separator: ", ")
    }

    /// Search over bill number, where, waiter, customer and dishes
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let needle = q.hasPrefix("#") ? String(q.dropFirst()) : q
        return [billNo, `where`, waiter ?? "", customer ?? "", dishes]
            .contains { $0.lowercased().contains(needle) }
    }
}

struct LedgerSummary: Decodable, Equatable {
    let bills: Int
    let takings: Int
    let byMethod: [LedgerTender]
    let gstTax: Int
    let vatTax: Int
    let discount: Int
    let unpaid: Int

    func amount(for method: String) -> Int { byMethod.first { $0.method == method }?.amount ?? 0 }
    static let empty = LedgerSummary(bills: 0, takings: 0, byMethod: [], gstTax: 0, vatTax: 0, discount: 0, unpaid: 0)
}

/// Which days the Bills screen shows
enum LedgerRange: Hashable {
    case today, yesterday
    case custom(from: Date, to: Date)

    private static var ist: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = ist
        f.timeZone = ist.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// IST calendar dates, as the server expects them
    var query: (from: String, to: String) {
        switch self {
        case .today:
            let d = Self.day(Date())
            return (d, d)
        case .yesterday:
            let d = Self.day(Self.ist.date(byAdding: .day, value: -1, to: Date())!)
            return (d, d)
        case .custom(let from, let to):
            let a = Self.day(min(from, to)), b = Self.day(max(from, to))
            return (a, b)
        }
    }

    /// The local window, for the bills still on this device
    var window: ClosedRange<Date> {
        let cal = Self.ist
        switch self {
        case .today:
            let start = cal.startOfDay(for: Date())
            return start...cal.date(byAdding: .day, value: 1, to: start)!
        case .yesterday:
            let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
            return start...cal.startOfDay(for: Date())
        case .custom(let from, let to):
            let start = cal.startOfDay(for: min(from, to))
            return start...cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to)))!
        }
    }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .custom(let from, let to):
            from == to || Calendar.current.isDate(from, inSameDayAs: to)
                ? from.formatted(.dateTime.day().month(.abbreviated))
                : "\(min(from, to).formatted(.dateTime.day().month(.abbreviated))) – \(max(from, to).formatted(.dateTime.day().month(.abbreviated)))"
        }
    }
}

// MARK: - Payment methods

enum PayMethod {
    static let main = ["CASH", "UPI", "CARD"]
    static let more = ["WALLET"]
    static let correctable = ["CASH", "UPI", "CARD", "WALLET"]

    static func name(_ method: String) -> String {
        switch method {
        case "CASH": "Cash"
        case "UPI": "UPI"
        case "CARD": "Card"
        case "WALLET": "Wallet"
        case "BANK_TRANSFER": "Bank"
        case "SPLIT": "Split"
        default: method.capitalized
        }
    }

    /// As said on the receipt: "cash", "UPI", "card"
    static func spoken(_ method: String) -> String { method == "UPI" ? "UPI" : name(method).lowercased() }

    static func icon(_ method: String) -> String {
        switch method {
        case "CASH": "banknote"
        case "CARD": "creditcard"
        case "UPI": "qrcode"
        case "WALLET": "wallet.pass"
        default: "circle"
        }
    }

    static func color(_ method: String) -> Color {
        switch method {
        case "UPI": SN.teal
        case "CASH": SN.blue
        case "CARD": SN.amber
        default: SN.mut
        }
    }

    /// The Bill Generator's status for a server method (it knows cash, UPI and card)
    static func appStatus(_ method: String) -> BillHistoryItemStatus? {
        switch method {
        case "CASH": .paidByCash
        case "UPI": .paidByUPI
        case "CARD": .paidByCard
        default: nil
        }
    }

    static func from(appStatus: BillHistoryItemStatus) -> String? {
        switch appStatus {
        case .paidByCash: "CASH"
        case .paidByUPI: "UPI"
        case .paidByCard: "CARD"
        case .pending: nil
        }
    }
}

// MARK: - Store

@MainActor
@Observable
final class TillStore {
    private let api: APIClient

    var till: [TillBill] = []
    var tillLoaded = false
    var tillError: String?

    var range: LedgerRange = .today
    var ledger: [LedgerBill] = []
    var summary: LedgerSummary = .empty
    var ledgerLoaded = false
    var ledgerError: String?
    /// Set while the Bills screen is showing, so live events reload it too
    var watchingLedger = false

    var config: BillingConfig?
    var isLive = false

    private var liveTask: Task<Void, Never>?
    private var pendingReload: Task<Void, Never>?

    init(session: Session) {
        self.api = APIClient(session: session)
    }

    func loadTill() async {
        struct Response: Decodable { let bills: [TillBill]; let billing: BillingConfig? }
        do {
            let data = try await api.get("/api/billing/till")
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            till = decoded.bills
            if let billing = decoded.billing { config = billing }
            tillError = nil
        } catch is CancellationError {
        } catch {
            tillError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        tillLoaded = true
    }

    func loadLedger() async {
        struct Response: Decodable { let bills: [LedgerBill]; let summary: LedgerSummary }
        let q = range.query
        do {
            let data = try await api.get("/api/billing/ledger", query: [
                URLQueryItem(name: "from", value: q.from), URLQueryItem(name: "to", value: q.to),
            ])
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            // A slow reply for dates no longer shown is dropped
            guard range.query == q else { return }
            ledger = decoded.bills
            summary = decoded.summary
            ledgerError = nil
        } catch is CancellationError {
        } catch {
            ledgerError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        ledgerLoaded = true
    }

    func bill(key: String) -> TillBill? { till.first { $0.key == key } }

    // MARK: Paying

    struct PaymentBody: Encodable {
        let method: String
        let expectedTotal: Int
        let discount: Int?
        let discountCode: String?
        let tenders: [POSStore.Tender]?
    }

    /// Settle the whole bill (every order on the table, or the one takeaway).
    /// The server refuses with 409 if the bill changed since `expectedTotal`.
    func pay(_ bill: TillBill, _ body: PaymentBody) async throws -> SettledBill {
        let data = try await api.postJSON("/api/orders/\(bill.anchorOrderId)/payment", payload: body)
        struct Response: Decodable { let bill: SettledBill }
        let settled = try JSONDecoder().decode(Response.self, from: data).bill
        till.removeAll { $0.key == bill.key }
        Task { await loadTill() }
        return settled
    }

    func discountCodeValue(code: String, orderTotal: Int) async throws -> Int {
        struct Body: Encodable { let code: String; let orderTotal: Int }
        struct Response: Decodable { let valid: Bool?; let error: String?; let calculatedDiscount: Int? }
        let data = try await api.postJSON("/api/discounts/validate", payload: Body(code: code, orderTotal: orderTotal))
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.valid != false, let value = response.calculatedDiscount else {
            throw POSStore.DiscountCodeError(message: response.error ?? "Invalid discount code")
        }
        return value
    }

    // MARK: Bills

    /// Correct how a paid bill was paid; the server refuses a split bill (409)
    func changeMethod(of bill: LedgerBill, to method: String) async throws {
        struct Body: Encodable { let method: String }
        _ = try await api.patch("/api/billing/settlements/\(bill.id)", body: try JSONEncoder().encode(Body(method: method)))
        await loadLedger()
    }

    /// One order as the server has it, for the receipt
    struct OrderDetail: Decodable {
        struct Item: Decodable {
            let quantity: Double
            let unitPrice: Double
            let status: String
            let itemName: String?
            let servingSizeName: String?
            let menuItem: POSOrderItem.NamedRef?
            let variantTemplate: POSOrderItem.NamedRef?
        }
        let id: String
        let externalId: String?
        let items: [Item]?
    }

    func orders(_ ids: [String]) async throws -> [OrderDetail] {
        var result: [OrderDetail] = []
        for id in ids {
            let data = try await api.get("/api/orders/\(id)")
            result.append(try JSONDecoder().decode(OrderDetail.self, from: data))
        }
        return result
    }

    /// The bill's dishes as receipt lines
    func receiptItems(for bill: LedgerBill) async throws -> [MenuItem] {
        try await orders(bill.orderIds).flatMap { order in
            (order.items ?? []).filter { $0.status != "CANCELLED" }.map { item in
                let name = item.itemName ?? item.menuItem?.name ?? "Item"
                let variant = item.servingSizeName ?? item.variantTemplate?.name
                return MenuItem(id: UUID(), name: variant.map { "\(name) (\($0))" } ?? name,
                                quantity: item.quantity, price: item.unitPrice)
            }
        }
    }

    // MARK: Live

    func startLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            guard let self else { return }
            var backoff: Duration = .seconds(1)
            while !Task.isCancelled {
                do {
                    let stream = api.eventStream("/api/events")
                    isLive = true
                    // Catch up on anything missed while disconnected
                    await reloadAll()
                    for try await ev in stream {
                        if ev.event == "heartbeat" || ev.event == "connected" { continue }
                        scheduleReload()
                    }
                    backoff = .seconds(1)
                } catch is CancellationError {
                    break
                } catch {
                    isLive = false
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(30))
                }
                isLive = false
            }
            isLive = false
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        pendingReload?.cancel()
        isLive = false
    }

    private func reloadAll() async {
        await loadTill()
        if watchingLedger { await loadLedger() }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await self?.reloadAll()
        }
    }
}
