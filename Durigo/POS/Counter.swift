//
//  Counter.swift
//  Durigo
//
//  Takeaways and deliveries (the counter), and every order of a day (the
//  orders ledger): what the floor can't show. Both are pushed from the
//  floor's toolbar. Mirrors the web's /pos/counter and /pos/orders.
//

import SwiftUI

// MARK: - Models (GET /api/pos/counter, GET /api/orders/ledger)

struct CounterOrder: Decodable, Identifiable, Hashable {
    let id: String
    let number: String
    /// TAKEAWAY | DELIVERY
    let type: String
    let status: String
    /// cooking | ready | pay
    let lane: String
    let createdAt: String
    /// The customer's name, else "Takeaway" / "Delivery"
    let name: String
    let phone: String?
    let address: String?
    let note: String?
    let waiter: String?
    let items: String
    let total: Double

    var isDelivery: Bool { type == "DELIVERY" }
    /// What handing it over is called
    var handOverLabel: String { isDelivery ? "Sent out" : "Collected" }
}

struct CounterData: Decodable {
    let orders: [CounterOrder]
    let older: [CounterOrder]
    let doneToday: Int
    let generatedAt: String

    func lane(_ lane: String) -> [CounterOrder] { orders.filter { $0.lane == lane } }
}

struct LedgerOrder: Decodable, Identifiable, Hashable {
    let id: String
    let number: String
    let type: String
    let status: String
    let createdAt: String
    /// "T4", or the customer's name for a takeaway or delivery
    let `where`: String
    let table: Int?
    let waiter: String?
    let items: String
    let itemCount: Double
    let total: Double
    let paid: Bool

    var isOpen: Bool { status != "COMPLETED" && status != "CANCELLED" }
}

struct OrderLedgerData: Decodable {
    struct Counts: Decodable { let open: Int; let done: Int; let cancelled: Int }
    let date: String
    let orders: [LedgerOrder]
    let counts: Counts
    let takings: Double
}

/// An order's status in the words the floor uses
enum OrderStatusText {
    static func label(_ status: String, paid: Bool = false) -> String {
        switch status {
        case "PENDING", "CONFIRMED": "Sent"
        case "PREPARING": "Cooking"
        case "READY": "Ready"
        case "SERVED": paid ? "Paid" : "Served"
        case "COMPLETED": "Paid"
        case "CANCELLED": "Cancelled"
        default: status.capitalized
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "READY": SN.teal
        case "SERVED": SN.amber
        case "COMPLETED": SN.mut
        case "CANCELLED": SN.red
        default: SN.blue
        }
    }
}

// MARK: - Store

@MainActor @Observable final class CounterStore {
    private let api: APIClient
    var counter: CounterData?
    var ledger: OrderLedgerData?
    var errorMessage: String?
    var liveConnected = false
    /// Orders being marked collected / sent out
    var handingOver: Set<String> = []
    private var streamTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    /// What a live event reloads
    private var reload: (() async -> Void)?

    init(session: Session) { self.api = APIClient(session: session) }

    func loadCounter() async {
        do {
            counter = try JSONDecoder().decode(CounterData.self, from: try await api.get("/api/pos/counter"))
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func loadLedger(date: String) async {
        do {
            let data = try await api.get("/api/orders/ledger", query: [URLQueryItem(name: "date", value: date)])
            ledger = try JSONDecoder().decode(OrderLedgerData.self, from: data)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Collected at the counter, or sent out with the rider
    func handOver(_ order: CounterOrder) async {
        handingOver.insert(order.id)
        defer { handingOver.remove(order.id) }
        do {
            let body = try JSONEncoder().encode(["status": "SERVED"])
            try await api.patch("/api/orders/\(order.id)/status", body: body)
            await loadCounter()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Reload on every server event (orders sent, cooked, paid), a burst as one
    func start(reloading: @escaping () async -> Void) {
        reload = reloading
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                do {
                    let stream = self.api.eventStream("/api/events")
                    self.liveConnected = true
                    await self.reload?()
                    for try await ev in stream {
                        if Task.isCancelled { break }
                        if ev.event == "heartbeat" || ev.event == "connection" { continue }
                        self.reloadSoon()
                    }
                    backoff = 1_000_000_000
                } catch is CancellationError {
                    break
                } catch {
                    self.liveConnected = false
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 30_000_000_000)
                }
                self.liveConnected = false
            }
            self.liveConnected = false
        }
    }

    private func reloadSoon() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload?()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        liveConnected = false
    }
}

// MARK: - Counter

/// Today's takeaways and deliveries: ready to hand over first, then to pay,
/// then still cooking
struct CounterView: View {
    @Environment(Session.self) private var session
    @EnvironmentObject private var navigation: Navigation
    /// A new takeaway or delivery (the floor opens the order screen)
    let onNew: (OrderType) -> Void
    @State private var store: CounterStore?

    private var canPay: Bool { NavigationItem.billing.isAllowed(for: session.user?.role) }

    var body: some View {
        let data = store?.counter ?? (store == nil || store?.errorMessage == nil ? CounterData.sample : nil)
        let loading = store?.counter == nil
        List {
            if let msg = store?.errorMessage {
                Section {
                    Label(store?.counter == nil ? "Couldn't load the counter: \(msg)" : "Showing the last list: \(msg)",
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(SN.red)
                }
            }
            if let data {
                lane("Ready", data.lane("ready"), loading: loading)
                lane("To pay", data.lane("pay"), loading: loading)
                lane("Cooking", data.lane("cooking"), loading: loading)
                if !data.older.isEmpty {
                    lane("From an earlier day", data.older, loading: loading)
                }
                Section {
                    NavigationLink {
                        OrdersLedgerView()
                    } label: {
                        LabeledContent("All orders today", value: "\(data.doneToday) done")
                    }
                    .accessibilityIdentifier("counter-all-orders")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if let data, !loading, data.orders.isEmpty, data.older.isEmpty {
                ContentUnavailableView("Nothing at the counter", systemImage: "bag",
                                       description: Text("Takeaways and deliveries show here until they're paid."))
            }
        }
        .navigationTitle("Counter")
        .navigationSubtitleIfAvailable(subtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            LiveBadgeItem(isLive: store?.liveConnected ?? false)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Takeaway", systemImage: "bag") { onNew(.takeaway) }
                    .accessibilityIdentifier("counter-new-takeaway")
                Button("Delivery", systemImage: "bicycle") { onNew(.delivery) }
                    .accessibilityIdentifier("counter-new-delivery")
            }
        }
        .refreshable { await store?.loadCounter() }
        .task {
            if store == nil { store = CounterStore(session: session) }
            await store?.loadCounter()
            store?.start { [weak store] in await store?.loadCounter() }
        }
        .onDisappear { store?.stop() }
    }

    private var subtitle: String {
        guard let c = store?.counter else { return "" }
        let ready = c.lane("ready").count
        return "\(ready) ready · \(c.lane("pay").count) to pay · \(c.lane("cooking").count) cooking"
    }

    @ViewBuilder
    private func lane(_ title: String, _ orders: [CounterOrder], loading: Bool) -> some View {
        if !orders.isEmpty {
            Section {
                ForEach(orders) { order in
                    row(order)
                        .skeleton(loading)
                        .swipeActions(edge: .trailing) { if !loading { actions(order) } }
                        .contextMenu { if !loading { actions(order) } }
                }
            } header: {
                Text("\(title) · \(orders.count)")
            }
        }
    }

    /// Hand over and pay: swipe, long-press, or the row's own button
    @ViewBuilder
    private func actions(_ order: CounterOrder) -> some View {
        if canPay && order.lane != "cooking" {
            Button("Pay", systemImage: "indianrupeesign") { pay(order) }
                .tint(SN.teal)
        }
        if order.lane == "ready" {
            Button(order.handOverLabel, systemImage: "checkmark") {
                Task { await store?.handOver(order) }
            }
            .tint(SN.amber)
        }
        if let phone = order.phone, let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
            Link(destination: url) { Label("Call", systemImage: "phone") }
        }
    }

    private func row(_ order: CounterOrder) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingM) {
            Image(systemName: order.isDelivery ? "bicycle" : "bag")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityLabel(order.isDelivery ? "Delivery" : "Takeaway")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(order.name).font(.headline)
                    Spacer()
                    Text(order.total.rupees).font(.headline).monospacedDigit()
                }
                Text(order.items)
                    .font(.subheadline)
                    .lineLimit(2)
                if let address = order.address {
                    Text("\(Image(systemName: "mappin")) \(address)").font(.subheadline).foregroundStyle(.secondary)
                }
                if let note = order.note {
                    Text(note).font(.subheadline).foregroundStyle(SN.blue)
                }
                Text(meta(order))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if order.lane != "cooking" {
                    rowButton(order).padding(.top, DesignTokens.spacingXS)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("counter-order-\(order.number)")
    }

    /// The next step, in the row: hand over when ready, pay once handed over
    @ViewBuilder
    private func rowButton(_ order: CounterOrder) -> some View {
        if order.lane == "ready" {
            Button(order.handOverLabel) { Task { await store?.handOver(order) } }
                .buttonStyle(.bordered)
                .tint(SN.amber)
                .disabled(store?.handingOver.contains(order.id) ?? true)
                .accessibilityIdentifier("counter-hand-over-\(order.number)")
        } else if canPay {
            Button("Pay \(order.total.rupees)") { pay(order) }
                .buttonStyle(.borderedProminent)
                .tint(SN.teal)
                .accessibilityIdentifier("counter-pay-\(order.number)")
        }
    }

    private func meta(_ order: CounterOrder) -> String {
        var parts = ["#\(order.number)", Fmt.elapsed(order.createdAt, now: .now) + " ago"]
        if let phone = order.phone { parts.append(phone) }
        if let waiter = order.waiter { parts.append(waiter) }
        return parts.joined(separator: " · ")
    }

    /// Billing takes the payment: it opens on this order's bill
    private func pay(_ order: CounterOrder) {
        navigation.payOrderId = order.id
        navigation.selection = .billing
    }
}

// MARK: - Orders ledger

/// Every order of a day, newest first, with what it came to
struct OrdersLedgerView: View {
    enum Show: String, CaseIterable, Identifiable {
        case all = "All", open = "Open", done = "Paid", cancelled = "Cancelled"
        var id: String { rawValue }
    }

    @Environment(Session.self) private var session
    @State private var store: CounterStore?
    @State private var day = Date.now
    @State private var show: Show = .all
    @State private var query = ""

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Fmt.ist
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private var dateString: String { Self.dayFormat.string(from: day) }

    private func shown(_ orders: [LedgerOrder]) -> [LedgerOrder] {
        orders.filter { o in
            switch show {
            case .all: true
            case .open: o.isOpen
            case .done: o.status == "COMPLETED"
            case .cancelled: o.status == "CANCELLED"
            }
        }
        .filter { o in
            query.isEmpty || [o.where, o.items, o.number, o.waiter ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        let loading = store?.ledger?.date != dateString
        let ledger = loading ? (store?.errorMessage == nil ? OrderLedgerData.sample : nil) : store?.ledger
        List {
            Section {
                Picker("Show", selection: $show) {
                    ForEach(Show.allCases) { s in Text(label(s, ledger)).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("orders-filter")
            }
            if let msg = store?.errorMessage {
                Section {
                    Label("Couldn't load the orders: \(msg)", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(SN.red)
                }
            }
            if let ledger {
                Section {
                    ForEach(shown(ledger.orders)) { order in
                        row(order).skeleton(loading)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if let ledger, !loading, shown(ledger.orders).isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No orders", systemImage: "list.bullet.rectangle",
                                           description: Text(show == .all ? "Nothing was ordered on this day." : "None on this day."))
                }
            }
        }
        #if os(iOS)
        .listSectionSpacing(.compact)
        #endif
        .searchable(text: $query, prompt: "Table, customer, dish")
        .navigationTitle("Orders")
        .navigationSubtitleIfAvailable(subtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DatePicker("Day", selection: $day, in: ...Date.now, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityIdentifier("orders-day")
            }
        }
        .refreshable { await store?.loadLedger(date: dateString) }
        .task(id: dateString) {
            if store == nil { store = CounterStore(session: session) }
            await store?.loadLedger(date: dateString)
            // Live: reload whichever day is showing
            store?.start { [weak store] in
                if let store, let date = store.ledger?.date { await store.loadLedger(date: date) }
            }
        }
        .onDisappear { store?.stop() }
    }

    private var subtitle: String {
        guard let l = store?.ledger, l.date == dateString else { return "" }
        return "\(l.orders.count) orders · \(l.takings.rupees) taken"
    }

    private func label(_ s: Show, _ l: OrderLedgerData?) -> String {
        guard let c = l?.counts, store?.ledger?.date == dateString else { return s.rawValue }
        switch s {
        case .all: return s.rawValue
        case .open: return "Open \(c.open)"
        case .done: return "Paid \(c.done)"
        case .cancelled: return "Cancelled \(c.cancelled)"
        }
    }

    private func row(_ order: LedgerOrder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(order.where).font(.headline)
                Text("#\(order.number)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text(order.total.rupees)
                    .font(.headline)
                    .monospacedDigit()
                    .strikethrough(order.status == "CANCELLED")
                    .foregroundStyle(order.status == "CANCELLED" ? .secondary : .primary)
            }
            Text(order.items).font(.subheadline).lineLimit(2)
            HStack(spacing: 6) {
                Text(OrderStatusText.label(order.status, paid: order.paid))
                    .fontWeight(.semibold)
                    .foregroundStyle(order.paid ? SN.mut : OrderStatusText.color(order.status))
                Text([Fmt.weekday(order.createdAt, style: .dateTime.hour().minute()), order.waiter].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orders-row-\(order.number)")
    }
}

// MARK: - Placeholders while loading

extension CounterData {
    static let sample = CounterData(
        orders: [
            CounterOrder(id: "s1", number: "0412", type: "TAKEAWAY", status: "READY", lane: "ready",
                         createdAt: Fmt.iso.string(from: .now.addingTimeInterval(-900)), name: "Takeaway customer",
                         phone: "98220 00000", address: nil, note: nil, waiter: "Waiter",
                         items: "2 Fish curry rice, 1 Lime soda", total: 640),
            CounterOrder(id: "s2", number: "0413", type: "DELIVERY", status: "SERVED", lane: "pay",
                         createdAt: Fmt.iso.string(from: .now.addingTimeInterval(-1800)), name: "Delivery customer",
                         phone: nil, address: "Colva beach road", note: nil, waiter: nil,
                         items: "1 Chicken xacuti, 4 Pao", total: 520),
            CounterOrder(id: "s3", number: "0414", type: "TAKEAWAY", status: "PREPARING", lane: "cooking",
                         createdAt: Fmt.iso.string(from: .now.addingTimeInterval(-300)), name: "Takeaway",
                         phone: nil, address: nil, note: nil, waiter: "Waiter",
                         items: "1 Prawn rava fry", total: 480),
        ],
        older: [], doneToday: 0, generatedAt: Fmt.iso.string(from: .now))
}

extension OrderLedgerData {
    static let sample = OrderLedgerData(
        date: "",
        orders: (0..<8).map { i in
            LedgerOrder(id: "s\(i)", number: String(format: "%04d", 400 + i), type: "DINE_IN",
                        status: i < 3 ? "PREPARING" : "COMPLETED",
                        createdAt: Fmt.iso.string(from: .now.addingTimeInterval(Double(-600 * i))),
                        where: "T\(i + 1)", table: i + 1, waiter: "Waiter",
                        items: "2 Fish curry rice, 1 Lime soda", itemCount: 3, total: 640, paid: i >= 3)
        },
        counts: .init(open: 3, done: 5, cancelled: 0), takings: 3200)
}
