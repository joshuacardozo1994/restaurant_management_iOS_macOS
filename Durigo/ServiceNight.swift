//
//  ServiceNight.swift
//  Durigo
//
//  The admin dashboard ("Service night"): today's takings and their pace, the
//  floor table by table, the kitchen queue, and what needs a decision. Reads
//  GET /api/admin/dashboard/service (the same figures as the web dashboard)
//  and reloads on live events. Light and dark follow the system appearance.
//
//  Layout follows the width it is given, not the device: one column on an
//  iPhone, two on an iPad in portrait or beside the sidebar, three on a wide
//  iPad or the Mac.
//

import SwiftUI
import Charts

// MARK: - Data

struct ServiceNight: Decodable, Equatable {
    struct Takings: Decodable, Equatable {
        let total: Double
        let bills: Int
        let average: Double
        let sameTimeLastWeek: Double
        let hourly: [Hour]
    }
    struct Hour: Decodable, Equatable, Identifiable {
        let hour: Int
        let total: Double
        var id: Int { hour }
    }
    struct Paid: Decodable, Equatable { let method: String; let total: Double }
    struct OrderTypeCount: Decodable, Equatable { let type: String; let count: Int }
    struct Table: Decodable, Equatable, Identifiable {
        let id: String
        let number: Int
        let capacity: Int
        let state: String          // free | seated | bill | reserved | closed
        let seatedSince: String?
        let reservedFor: String?   // HH:MM
    }
    struct Floor: Decodable, Equatable { let tables: [Table]; let seated: Int; let total: Int }
    struct Ticket: Decodable, Equatable {
        struct Item: Decodable, Equatable { let name: String; let quantity: Double; let cooking: Bool }
        let orderNumber: String
        let table: Int?
        let type: String
        let status: String
        let since: String
        let waiter: String?
        /// Cooks assigned to (or working on) its waiting dishes; empty when nobody has it
        let cooks: [String]
        /// Dishes not yet ready
        let items: [Item]
    }
    struct Kitchen: Decodable, Equatable { let todo: Int; let cooking: Int; let ready: Int; let oldest: Ticket? }
    struct Stock: Decodable, Equatable { let name: String; let unit: String; let currentStock: Double; let minimumStock: Double }
    struct Reservation: Decodable, Equatable { let guestName: String; let guestCount: Int; let time: String; let table: Int? }
    struct Dish: Decodable, Equatable { let name: String; let quantity: Double; let revenue: Double }

    let generatedAt: String
    let date: String
    let takings: Takings
    let paidBy: [Paid]
    let orderTypes: [OrderTypeCount]
    let floor: Floor
    let kitchen: Kitchen
    let billRequested: [Int]
    let lowStock: [Stock]
    let reservations: [Reservation]
    let topDishes: [Dish]
}

@MainActor
@Observable
final class ServiceNightStore {
    private let session: Session
    private let api: APIClient
    var data: ServiceNight?
    var errorMessage: String?
    var isLive = false
    private var liveTask: Task<Void, Never>?
    private var pendingReload: Task<Void, Never>?

    init(session: Session) {
        self.session = session
        self.api = APIClient(session: session)
    }

    func load() async {
        do {
            let raw = try await api.get("/api/admin/dashboard/service")
            data = try JSONDecoder().decode(ServiceNight.self, from: raw)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            // Keep the last figures on screen; say why they may be stale
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Orders, tables, payments and stock all move these numbers. A burst of
    /// events (one bill settling several orders) becomes one reload; a reload
    /// each minute also catches anything missed while reconnecting.
    func startLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            guard let self else { return }
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await self?.load()
                }
            }
            defer { ticker.cancel() }
            var backoff: Duration = .seconds(1)
            while !Task.isCancelled {
                do {
                    let stream = api.eventStream("/api/events")
                    isLive = true
                    await load()
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

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await self?.load()
        }
    }
}

// MARK: - Palette

/// The dashboard's own accents, resolved per appearance. The light accents are
/// darker so small labels stay above 4.5:1 on white.
enum SN {
    static let panel  = Color(light: 0xFFFFFF, dark: 0x141C20)
    static let panel2 = Color(light: 0xF1F4F3, dark: 0x1A242A)
    static let line   = Color(light: 0xDDE3E1, dark: 0x25323A)
    static let ink    = Color(light: 0x12201E, dark: 0xE6EEF0)
    static let mut    = Color(light: 0x5A6967, dark: 0x8A9BA3)
    static let page   = Color(light: 0xF3F5F4, dark: 0x0D1316)
    static let teal   = Color(light: 0x077361, dark: 0x3FD1B4)
    static let amber  = Color(light: 0x985407, dark: 0xF2A541)
    static let red    = Color(light: 0xC23B2B, dark: 0xEF5B4C)
    static let blue   = Color(light: 0x2A64C9, dark: 0x6AA8FF)
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        func parts(_ hex: UInt32) -> (Double, Double, Double) {
            (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        let l = parts(light), d = parts(dark)
        #if os(iOS)
        self.init(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}

// MARK: - Formatting

private enum Fmt {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let ist = TimeZone(identifier: "Asia/Kolkata")!

    static func date(_ s: String) -> Date? { iso.date(from: s) }

    /// "7m", "1h 4m", "3d"
    static func elapsed(_ since: String, now: Date) -> String {
        guard let d = date(since) else { return "" }
        let mins = max(0, Int(now.timeIntervalSince(d) / 60))
        if mins < 60 { return "\(mins)m" }
        if mins < 24 * 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins / (24 * 60))d"
    }

    /// "20:30" → "8:30"
    static func clock(_ hhmm: String) -> String {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return hhmm }
        return "\(p[0] % 12 == 0 ? 12 : p[0] % 12):\(String(format: "%02d", p[1]))"
    }

    static func hour(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "am" : "pm")" }

    static func qty(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
    }

    static func weekday(_ s: String, style: Date.FormatStyle) -> String {
        guard let d = date(s) else { return "" }
        var f = style
        f.timeZone = ist
        return d.formatted(f)
    }

    static let methodLabels = ["UPI": "UPI", "CASH": "Cash", "CARD": "Card", "WALLET": "Wallet", "BANK_TRANSFER": "Bank", "OTHER": "Other"]
    static let typeLabels = ["DINE_IN": "Dine in", "TAKEAWAY": "Takeaway", "DELIVERY": "Delivery"]
    static func methodColor(_ m: String) -> Color {
        switch m {
        case "UPI": SN.teal
        case "CASH": SN.blue
        case "CARD": SN.amber
        default: SN.mut
        }
    }
}

// MARK: - Screen

struct ServiceNightDashboard: View {
    @Environment(Session.self) private var session
    @State private var store: ServiceNightStore?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    content(width: geo.size.width)
                        .padding(DesignTokens.spacingL)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable { await store?.load() }
            }
            .background(SN.page)
            .foregroundStyle(SN.ink)
            .navigationTitle("Today")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { LiveBadge(isLive: store?.isLive ?? false) }
            }
            .task {
                if store == nil { store = ServiceNightStore(session: session) }
                await store?.load()
                store?.startLive()
            }
            .onDisappear { store?.stopLive() }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let d = store?.data {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let msg = store?.errorMessage {
                    Label("Showing the last figures: \(msg)", systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(SN.red)
                }
                Text(Fmt.weekday(d.generatedAt, style: .dateTime.weekday(.wide).day().month(.abbreviated)))
                    .font(.subheadline)
                    .foregroundStyle(SN.mut)
                // The ticking times (seated for, oldest ticket) redraw every 30s
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    layout(d, now: tl.date, width: width - DesignTokens.spacingL * 2)
                }
            }
        } else if let msg = store?.errorMessage {
            ContentUnavailableView("Couldn't load the dashboard", systemImage: "wifi.exclamationmark", description: Text(msg))
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    @ViewBuilder
    private func layout(_ d: ServiceNight, now: Date, width: CGFloat) -> some View {
        let gap = DesignTokens.spacingL
        if width >= 900 {
            VStack(spacing: gap) {
                HStack(alignment: .top, spacing: gap) {
                    TakingsPanel(d: d).frame(width: (width - gap) * 0.385)
                    FloorPanel(d: d, now: now, compact: false)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: gap) {
                    KitchenPanel(k: d.kitchen, now: now)
                    NeedsPanel(d: d)
                    DishesPanel(dishes: d.topDishes)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if width >= 600 {
            VStack(spacing: gap) {
                HStack(alignment: .top, spacing: gap) {
                    TakingsPanel(d: d)
                    KitchenPanel(k: d.kitchen, now: now)
                }
                .fixedSize(horizontal: false, vertical: true)
                FloorPanel(d: d, now: now, compact: false)
                HStack(alignment: .top, spacing: gap) {
                    NeedsPanel(d: d)
                    DishesPanel(dishes: d.topDishes)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: DesignTokens.spacingM) {
                TakingsPanel(d: d)
                FloorPanel(d: d, now: now, compact: true)
                KitchenPanel(k: d.kitchen, now: now)
                NeedsPanel(d: d)
                DishesPanel(dishes: d.topDishes)
            }
        }
    }
}

// MARK: - Pieces

struct LiveBadge: View {
    let isLive: Bool
    var body: some View {
        HStack(spacing: 6) {
            // The ring is part of the layout, so a toolbar's glass capsule doesn't clip it
            ZStack {
                Circle().fill(SN.teal.opacity(isLive ? 0.18 : 0)).frame(width: 16, height: 16)
                Circle().fill(isLive ? SN.teal : SN.mut).frame(width: 8, height: 8)
            }
            Text(isLive ? "LIVE" : "RECONNECTING")
                .font(.caption.monospaced().weight(.medium))
                .tracking(0.8)
                .lineLimit(1)
        }
        // Room inside the toolbar's capsule on iOS 26 and macOS 26
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .fixedSize()
        .foregroundStyle(isLive ? SN.teal : SN.mut)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLive ? "Live" : "Reconnecting")
    }
}

/// A panel: label in small mono capitals, then its content. Fills the height
/// its row gives it so side-by-side panels line up.
private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            PanelLabel(text: title).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(DesignTokens.spacingL + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).fill(SN.panel))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).stroke(SN.line, lineWidth: 1))
    }
}

struct PanelLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.monospaced().weight(.medium))
            .tracking(1.1)
            .foregroundStyle(SN.mut)
    }
}

private struct TakingsPanel: View {
    let d: ServiceNight
    @ScaledMetric(relativeTo: .largeTitle) private var bigSize: CGFloat = 46

    var body: some View {
        let t = d.takings
        let change: Int? = t.sameTimeLastWeek > 0
            ? Int(((t.total - t.sameTimeLastWeek) / t.sameTimeLastWeek * 100).rounded()) : nil
        let paidTotal = d.paidBy.reduce(0) { $0 + $1.total }
        Panel(title: "Takings today") {
            Text(t.total.rupees)
                .font(.system(size: bigSize, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Facts {
                Fact(value: "\(t.bills)", label: "bills")
                Fact(label: "avg", value: t.average.rupees)
                if let change {
                    Text("\(change >= 0 ? "▲" : "▼") \(abs(change))% vs last \(Fmt.weekday(d.generatedAt, style: .dateTime.weekday(.abbreviated)))")
                        .foregroundStyle(change >= 0 ? SN.teal : SN.red)
                }
            }
            if t.hourly.count >= 2 { PaceChart(hours: t.hourly) }

            Divider().overlay(SN.line)
            PanelLabel(text: "Paid by")
            if paidTotal > 0 {
                PaidBar(paid: d.paidBy, total: paidTotal)
                Facts {
                    ForEach(d.paidBy, id: \.method) { p in
                        Fact(value: "\(Int((p.total / paidTotal * 100).rounded()))%", label: Fmt.methodLabels[p.method] ?? p.method)
                    }
                }
            } else {
                Text("No bills paid yet today").font(.subheadline).foregroundStyle(SN.mut)
            }
            Facts {
                ForEach(d.orderTypes, id: \.type) { o in
                    Fact(label: Fmt.typeLabels[o.type] ?? o.type, value: "\(o.count)")
                }
            }
        }
    }
}

/// Wrapping row of small "**63** bills" facts
private struct Facts<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        FlowLayout(spacing: 14, lineSpacing: 4) { content() }
            .font(.subheadline)
            .foregroundStyle(SN.mut)
    }
}

private struct Fact: View {
    var label: String? = nil
    let value: String
    var trailing: String? = nil

    /// "**63** bills"
    init(value: String, label: String) { self.value = value; self.trailing = label }
    /// "avg **₹772**"
    init(label: String, value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack(spacing: 4) {
            if let label { Text(label) }
            Text(value).fontWeight(.semibold).foregroundStyle(SN.ink).monospacedDigit()
            if let trailing { Text(trailing) }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PaceChart: View {
    let hours: [ServiceNight.Hour]
    var body: some View {
        Chart(hours) { h in
            AreaMark(x: .value("Hour", h.hour), y: .value("Takings", h.total))
                .foregroundStyle(SN.teal.opacity(0.14))
                .interpolationMethod(.linear)
            LineMark(x: .value("Hour", h.hour), y: .value("Takings", h.total))
                .foregroundStyle(SN.teal)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
            if h.hour == hours.last?.hour {
                PointMark(x: .value("Hour", h.hour), y: .value("Takings", h.total))
                    .foregroundStyle(SN.teal)
                    .symbolSize(30)
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartXScale(domain: hours.first!.hour...hours.last!.hour)
        .frame(height: 58)
        // First and last hour under the ends of the line (axis labels clip at the edges)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            HStack {
                Text(Fmt.hour(hours.first!.hour))
                Spacer()
                Text(Fmt.hour(hours.last!.hour))
            }
            .font(.caption2.monospaced())
            .foregroundStyle(SN.mut)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Takings by hour from \(Fmt.hour(hours.first!.hour)) to \(Fmt.hour(hours.last!.hour))")
    }
}

private struct PaidBar: View {
    let paid: [ServiceNight.Paid]
    let total: Double
    var body: some View {
        GeometryReader { geo in
            let gaps = CGFloat(max(0, paid.count - 1)) * 3
            HStack(spacing: 3) {
                ForEach(paid, id: \.method) { p in
                    Rectangle()
                        .fill(Fmt.methodColor(p.method))
                        .frame(width: max(2, (geo.size.width - gaps) * p.total / total))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct FloorPanel: View {
    let d: ServiceNight
    let now: Date
    let compact: Bool

    var body: some View {
        Panel(title: "Floor · \(d.floor.seated) of \(d.floor.total) tables seated") {
            LazyVGrid(columns: compact
                      ? Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)
                      : [GridItem(.adaptive(minimum: 68), spacing: 8)],
                      spacing: compact ? 6 : 8) {
                ForEach(d.floor.tables) { FloorTile(table: $0, now: now, compact: compact) }
            }
            FlowLayout(spacing: 14, lineSpacing: 4) {
                LegendItem(fill: SN.blue.opacity(0.5), label: "Seated")
                LegendItem(fill: SN.amber.opacity(0.7), label: "Bill asked")
                LegendItem(dashed: true, label: "Reserved")
                LegendItem(fill: SN.panel2, stroke: SN.line, label: "Free")
            }
            .font(.caption)
            .foregroundStyle(SN.mut)
        }
    }
}

private struct FloorTile: View {
    let table: ServiceNight.Table
    let now: Date
    let compact: Bool

    var body: some View {
        let note = table.seatedSince.map { Fmt.elapsed($0, now: now) } ?? table.reservedFor.map(Fmt.clock)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(fill)
            shape.strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: table.state == "reserved" ? [3, 2] : []))
            Text(verbatim: String(table.number))
                .font((compact ? Font.footnote : Font.callout).monospaced().weight(.semibold))
                .foregroundStyle(table.state == "reserved" || table.state == "closed" ? SN.mut : SN.ink)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            if !compact, let note {
                VStack {
                    Spacer()
                    Text(note).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(SN.mut)
                        .padding(.bottom, 3)
                }
            }
        }
        .aspectRatio(compact ? 1.1 : 1.55, contentMode: .fit)
        .opacity(table.state == "closed" ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(note: note))
    }

    private var fill: Color {
        switch table.state {
        case "seated": SN.blue.opacity(0.12)
        case "bill": SN.amber.opacity(0.16)
        default: SN.panel2
        }
    }
    private var stroke: Color {
        switch table.state {
        case "seated": SN.blue.opacity(0.55)
        case "bill": SN.amber.opacity(0.7)
        case "reserved": SN.mut
        default: SN.line
        }
    }
    private func accessibility(note: String?) -> String {
        let state = ["seated": "seated", "bill": "bill asked", "reserved": "reserved", "closed": "closed"][table.state] ?? "free"
        var s = "Table \(table.number), \(state)"
        if table.seatedSince != nil, let note { s += " for \(note)" }
        if let r = table.reservedFor { s += ", reserved for \(Fmt.clock(r))" }
        return s
    }
}

private struct LegendItem: View {
    var fill: Color = .clear
    var stroke: Color = .clear
    var dashed = false
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(dashed ? SN.mut : stroke, style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 1.5] : [])))
                .frame(width: 10, height: 10)
            Text(label)
        }
    }
}

private struct KitchenPanel: View {
    let k: ServiceNight.Kitchen
    let now: Date
    var body: some View {
        Panel(title: "Kitchen") {
            HStack(spacing: 10) {
                Lane(label: "To do", value: k.todo, color: SN.amber)
                Lane(label: "Cooking", value: k.cooking, color: SN.blue)
                Lane(label: "Ready", value: k.ready, color: SN.teal)
            }
            OldestTicketCard(ticket: k.oldest, now: now)
        }
    }
}

/// The ticket that has waited longest: where it's going, what's still to come, and who has it
private struct OldestTicketCard: View {
    let ticket: ServiceNight.Ticket?
    let now: Date

    var body: some View {
        if let t = ticket {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    PanelLabel(text: "Oldest ticket")
                    Spacer(minLength: 8)
                    Text("waiting \(Fmt.elapsed(t.since, now: now))")
                        .font(.subheadline.monospaced().weight(.medium))
                        .foregroundStyle(SN.amber)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t.table.map { "Table \($0)" } ?? Fmt.typeLabels[t.type] ?? t.type)
                        .font(.headline)
                    Text("#\(t.orderNumber)").font(.caption.monospaced()).foregroundStyle(SN.mut)
                }
                if !t.items.isEmpty {
                    Text(dishes(t.items))
                        .font(.subheadline)
                        .foregroundStyle(SN.mut)
                        .lineLimit(2)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow {
                        Text("Cook").foregroundStyle(SN.mut)
                        if t.cooks.isEmpty {
                            Text("Not assigned").fontWeight(.medium).foregroundStyle(SN.amber)
                        } else {
                            Text(t.cooks.joined(separator: ", "))
                        }
                    }
                    GridRow {
                        Text("Waiter").foregroundStyle(SN.mut)
                        Text(t.waiter ?? "—")
                    }
                }
                .font(.subheadline)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SN.line, lineWidth: 1))
            .accessibilityElement(children: .combine)
        } else {
            Text("No ticket waiting").font(.subheadline).foregroundStyle(SN.mut)
        }
    }

    /// "2× Fish Curry Rice, Prawn Balchão +2 more"
    private func dishes(_ items: [ServiceNight.Ticket.Item]) -> String {
        let shown = items.prefix(3).map { ($0.quantity == 1 ? "" : "\(Fmt.qty($0.quantity))× ") + $0.name }
        let more = items.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? " +\(more) more" : "")
    }
}

private struct Lane: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.caption2.monospaced().weight(.medium)).tracking(1)
            Text("\(value)").font(.system(.largeTitle, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SN.panel2))
        .accessibilityElement(children: .combine)
    }
}

private struct NeedsPanel: View {
    let d: ServiceNight

    private struct Row: Identifiable { let id: String; let tone: Color; let text: String; let detail: String }

    private var rows: [Row] {
        var rows: [Row] = []
        let bills = d.billRequested
        if !bills.isEmpty {
            rows.append(Row(id: "bills", tone: SN.amber,
                            text: bills.count == 1 ? "1 table waiting for the bill" : "\(bills.count) tables waiting for the bill",
                            detail: bills.prefix(4).map { "T\($0)" }.joined(separator: " · ") + (bills.count > 4 ? " …" : "")))
        }
        for i in d.lowStock.prefix(3) {
            rows.append(Row(id: "stock-\(i.name)", tone: SN.red,
                            text: "\(i.name) low · \(Fmt.qty(max(0, i.currentStock))) \(i.unit) left",
                            detail: "min \(Fmt.qty(i.minimumStock)) \(i.unit)"))
        }
        if d.lowStock.count > 3 {
            rows.append(Row(id: "stock-more", tone: SN.red, text: "\(d.lowStock.count - 3) more items low on stock", detail: "Inventory"))
        }
        for r in d.reservations.prefix(3) {
            rows.append(Row(id: "res-\(r.time)-\(r.guestName)", tone: SN.blue,
                            text: "Reservation \(Fmt.clock(r.time)) · \(r.guestName) ×\(r.guestCount)",
                            detail: r.table.map { "T\($0)" } ?? "no table"))
        }
        return rows
    }

    var body: some View {
        Panel(title: "Needs you") {
            if rows.isEmpty {
                Text("Nothing needs you right now").font(.subheadline).foregroundStyle(SN.mut)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { r in
                        HStack(spacing: 12) {
                            Circle().fill(r.tone).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(r.text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            Text(r.detail).font(.caption.monospaced().weight(.medium)).foregroundStyle(SN.mut)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SN.panel2))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct DishesPanel: View {
    let dishes: [ServiceNight.Dish]
    var body: some View {
        Panel(title: "Top dishes today") {
            if let top = dishes.first?.revenue, top > 0 {
                VStack(spacing: 10) {
                    ForEach(dishes, id: \.name) { dish in
                        VStack(spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(dish.name).font(.subheadline).lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(Fmt.qty(dish.quantity)) · \(dish.revenue.rupees)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(SN.mut)
                                    .monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(SN.line)
                                    Capsule().fill(SN.teal).frame(width: geo.size.width * dish.revenue / top)
                                }
                            }
                            .frame(height: 4)
                            .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Text("Nothing sold yet today").font(.subheadline).foregroundStyle(SN.mut)
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when they run out of room
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
