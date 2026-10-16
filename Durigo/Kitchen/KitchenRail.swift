//
//  KitchenRail.swift
//  Durigo
//
//  The kitchen as a rail, as on the web's /kitchen: tickets oldest first,
//  flowing down and then across so a rush fits one screen; the newest wait
//  off to the right so the oldest never scroll away. Tap a dish to move it
//  on; Send when a station's dishes are ready. Drinks go to a bar strip, or
//  a device set to Bar only. Data from /api/kitchen/board.
//

import SwiftUI

// MARK: - Model

struct KitchenBoard: Decodable {
    struct Line: Decodable, Identifiable, Hashable {
        let id: String
        let quantity: Int
        let name: String
        var status: String
        let station: String
        let notes: String?
        let extras: [String]
        let cook: String?
        let assigned: Bool
    }
    struct Ticket: Decodable, Identifiable, Hashable {
        let id: String
        let number: String
        let `where`: String
        let createdAt: String
        let waiter: String?
        let note: String?
        var lines: [Line]
        let sentAt: String?
    }
    struct Category: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let type: String
    }
    var tickets: [Ticket]
    let recent: [Ticket]
    let barCategoryIds: [String]?
    let categories: [Category]
    let generatedAt: String
}

enum KitchenView: String, CaseIterable, Identifiable {
    case both, kitchen, bar
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private enum Rail {
    /// Past this many tickets a zone goes compact
    static let compactAfter = 8
    static let corner: CGFloat = 3

    static func next(_ status: String) -> String {
        switch status {
        case "PENDING": "PREPARING"
        case "PREPARING": "READY"
        default: "PREPARING" // a ready dish tapped again goes back to cooking
        }
    }
    static func word(_ status: String) -> String {
        switch status {
        case "PENDING": "to do"
        case "PREPARING": "cooking"
        case "READY": "ready"
        case "CANCELLED": "cancelled"
        default: "sent"
        }
    }
    static func isAlert(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.range(of: "allerg|nut|gluten|shellfish|vegan|jain", options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// 7m, 1h 4m, 3d
    static func waited(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / (24 * 60))d"
    }
    static func minutes(_ iso: String, now: Date) -> Int {
        guard let d = Fmt.date(iso) else { return 0 }
        return max(0, Int(now.timeIntervalSince(d) / 60))
    }
}

// MARK: - Store

@MainActor @Observable final class KitchenRailStore {
    private let api: APIClient
    var board: KitchenBoard?
    var errorMessage: String?
    var liveConnected = false
    var staff: [KitchenOrder.WaiterRef] = []
    /// A new order arrived (its id): the view chimes and prints
    var onNewOrder: ((String) -> Void)?
    private var streamTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        do {
            board = try JSONDecoder().decode(KitchenBoard.self, from: try await api.get("/api/kitchen/board"))
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A burst of events (a ticket sent, a bill paid) becomes one reload
    private func reloadSoon() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func start() {
        guard streamTask == nil else { return }
        Task { [weak self] in await self?.loadStaff() }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                do {
                    let stream = self.api.eventStream("/api/events")
                    self.liveConnected = true
                    await self.load()
                    for try await ev in stream {
                        if Task.isCancelled { break }
                        switch ev.event {
                        case "heartbeat", "connection": break
                        case "order_created":
                            struct Created: Decodable { let id: String }
                            if let id = try? JSONDecoder().decode(Created.self, from: Data(ev.data.utf8)).id { self.onNewOrder?(id) }
                            self.reloadSoon()
                        default:
                            self.reloadSoon()
                        }
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

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        liveConnected = false
    }

    private func loadStaff() async {
        if let data = try? await api.get("/api/users/kitchen-staff") {
            staff = (try? JSONDecoder().decode([KitchenOrder.WaiterRef].self, from: data)) ?? []
        }
    }

    private func fail(_ error: Error, _ fallback: String) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? fallback
    }

    /// Change the screen at once, then check with the server
    func move(_ ticket: KitchenBoard.Ticket, _ line: KitchenBoard.Line, to status: String) async {
        if var b = board {
            b.tickets = b.tickets.compactMap { t in
                var t = t
                if status == "CANCELLED" { t.lines.removeAll { $0.id == line.id } }
                else if let i = t.lines.firstIndex(where: { $0.id == line.id }) { t.lines[i].status = status }
                return t.lines.isEmpty ? nil : t
            }
            board = b
        }
        do {
            _ = try await api.patch("/api/orders/\(ticket.id)/items/\(line.id)/status", body: try JSONEncoder().encode(["status": status]))
        } catch {
            fail(error, "Couldn't mark \(line.name) \(Rail.word(status)). Showing its current state.")
        }
        await load()
    }

    func send(_ ticket: KitchenBoard.Ticket, _ lines: [KitchenBoard.Line]) async {
        let ids = lines.map(\.id)
        if var b = board {
            b.tickets = b.tickets.compactMap { t in
                guard t.id == ticket.id else { return t }
                var t = t
                t.lines.removeAll { ids.contains($0.id) }
                return t.lines.isEmpty ? nil : t
            }
            board = b
        }
        struct Body: Encodable { let orderId: String; let itemIds: [String] }
        do {
            _ = try await api.postJSON("/api/kitchen/send", payload: Body(orderId: ticket.id, itemIds: ids))
        } catch {
            fail(error, "Couldn't send \(ticket.where). Showing the current tickets.")
        }
        await load()
    }

    func assign(_ ticket: KitchenBoard.Ticket, _ line: KitchenBoard.Line, to userId: String?) async {
        struct Body: Encodable { let assignedToId: String? }
        do {
            _ = try await api.patch("/api/orders/\(ticket.id)/items/\(line.id)/assign", body: try JSONEncoder().encode(Body(assignedToId: userId)))
        } catch {
            fail(error, "Couldn't change who's cooking \(line.name)")
        }
        await load()
    }

    func cancelOrder(_ ticket: KitchenBoard.Ticket, reason: String?) async -> Bool {
        var payload = ["status": "CANCELLED"]
        if let reason, !reason.isEmpty { payload["reason"] = reason }
        defer { Task { await load() } }
        do {
            _ = try await api.patch("/api/orders/\(ticket.id)/status", body: try JSONEncoder().encode(payload))
            return true
        } catch {
            fail(error, "Couldn't cancel the order")
            return false
        }
    }

    /// An admin puts a sent ticket back on the rail
    func putBack(_ ticket: KitchenBoard.Ticket) async {
        for line in ticket.lines {
            do {
                _ = try await api.patch("/api/orders/\(ticket.id)/items/\(line.id)/status", body: try JSONEncoder().encode(["status": "READY"]))
            } catch {
                fail(error, "Couldn't put all of \(ticket.where) back")
            }
        }
        await load()
    }

    func saveBar(_ ids: [String]) async -> Bool {
        struct Body: Encodable { let barCategoryIds: [String] }
        defer { Task { await load() } }
        do {
            _ = try await api.putJSON("/api/kitchen/stations", payload: Body(barCategoryIds: ids))
            return true
        } catch {
            fail(error, "Couldn't save the bar's categories")
            return false
        }
    }

    /// The full order, for printing its ticket
    func order(_ id: String) async -> KitchenOrder? {
        guard let data = try? await api.get("/api/kitchen/orders"),
              let orders = try? JSONDecoder().decode([KitchenOrder].self, from: data) else { return nil }
        return orders.first { $0.id == id }
    }
}

// MARK: - Screen

struct KitchenRailView: View {
    @Environment(Session.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var store: KitchenRailStore?
    @State private var now = Date()
    @AppStorage("kitchen.view") private var viewRaw = KitchenView.both.rawValue
    @AppStorage("kitchen.chime") private var chime = true
    @AppStorage("kitchen.autoPrint") private var autoPrint = false
    @State private var open: KitchenBoard.Ticket?
    @State private var recallOpen = false
    @State private var barOpen = false
    @State private var printError: String?
    private static let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var view: KitchenView { KitchenView(rawValue: viewRaw) ?? .both }
    private var isAdmin: Bool { session.user?.role.uppercased() == "ADMIN" }
    private var phone: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        NavigationRoot {
            Group {
                if let board = store?.board {
                    content(board, live: true)
                } else {
                    content(.sample, live: false).skeleton(true).accessibilityIdentifier("kitchen-loading")
                }
            }
            .background(SN.page)
            .foregroundStyle(SN.ink)
            .navigationTitle("Kitchen")
            .navigationSubtitleIfAvailable(kitchenSubtitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                LiveBadgeItem(isLive: store?.liveConnected ?? false)
                ToolbarItem(placement: .primaryAction) {
                    Button("Recall", systemImage: "arrow.uturn.backward") { recallOpen = true }
                        .accessibilityIdentifier("kitchen-recall")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Chime for new orders", isOn: $chime)
                        Toggle("Auto-print tickets", isOn: $autoPrint)
                        #if os(iOS)
                        Button {
                            KitchenPrinter.choosePrinter()
                        } label: {
                            Label(KitchenPrinter.savedPrinterName.map { "Printer: \($0)" } ?? "Choose printer…", systemImage: "printer")
                        }
                        #endif
                        if isAdmin {
                            Divider()
                            Button("Bar dishes…") { barOpen = true }
                        }
                    } label: {
                        Image(systemName: autoPrint ? "printer.fill" : chime ? "bell.fill" : "bell.slash")
                    }
                    .accessibilityLabel("Kitchen settings")
                    .accessibilityIdentifier("kitchen-alert-settings")
                }
            }
            .task {
                if store == nil { store = KitchenRailStore(session: session) }
                store?.onNewOrder = { id in
                    if chime { KitchenChime.play() }
                    if autoPrint { printTicket(id, automatic: true) }
                }
                await store?.load()
                store?.start()
            }
            .onDisappear { store?.stop() }
            .onReceive(Self.tick) { now = $0 }
            .sheet(item: $open) { t in
                if let store {
                    TicketSheet(ticket: store.board?.tickets.first { $0.id == t.id } ?? t, store: store, onPrint: { printTicket(t.id, automatic: false) })
                }
            }
            .sheet(isPresented: $recallOpen) {
                if let store { RecallSheet(store: store, isAdmin: isAdmin, now: now) }
            }
            .sheet(isPresented: $barOpen) {
                if let store, let board = store.board { BarSheet(store: store, board: board) }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { store?.errorMessage != nil && store?.board != nil }, set: { if !$0 { store?.errorMessage = nil } }
            )) {
                Button("OK") { store?.errorMessage = nil }
            } message: { Text(store?.errorMessage ?? "") }
            .alert("Couldn't print the ticket", isPresented: Binding(get: { printError != nil }, set: { if !$0 { printError = nil } })) {
                Button("OK") { printError = nil }
            } message: { Text(printError ?? "") }
        }
    }

    private func printTicket(_ orderId: String, automatic: Bool) {
        Task { @MainActor in
            guard let order = await store?.order(orderId) else { return }
            do { try await KitchenPrinter.print(order, interactive: !automatic) } catch { printError = error.localizedDescription }
        }
    }

    private func minutes(_ t: KitchenBoard.Ticket, live: Bool) -> Int { live ? Rail.minutes(t.createdAt, now: now) : 3 }

    @ViewBuilder
    private func content(_ board: KitchenBoard, live: Bool) -> some View {
        let station = { (s: String) in
            board.tickets.compactMap { t -> KitchenBoard.Ticket? in
                var t = t
                t.lines = t.lines.filter { $0.station == s }
                return t.lines.isEmpty ? nil : t
            }
        }
        let kitchen = station("kitchen"), bar = station("bar")
        let main = view == .bar ? bar : kitchen
        let mainStation = view == .bar ? "bar" : "kitchen"
        VStack(spacing: 0) {
            header(board: board, kitchen: kitchen.count, bar: bar.count, main: main, live: live)
            if phone {
                // A phone: one list, oldest first; the bar's tickets follow the kitchen's
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(main) { t in ticket(t, station: mainStation, compact: false, live: live) }
                        if view == .both && !bar.isEmpty {
                            PanelLabel(text: "Bar · \(bar.count)", small: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            ForEach(bar) { t in ticket(t, station: "bar", compact: true, live: live) }
                        }
                        if main.isEmpty && (view != .both || bar.isEmpty) { empty }
                    }
                    .padding(DesignTokens.spacingL)
                }
                .refreshable { await store?.load() }
            } else {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        if main.isEmpty { empty.frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else {
                            RailZone(tickets: main, height: geo.size.height * (view == .both && !bar.isEmpty ? 0.64 : 1) - 12) { t, compact in
                                ticket(t, station: mainStation, compact: compact, live: live)
                            }
                        }
                        if view == .both && !bar.isEmpty {
                            barStrip(bar, live: live).frame(height: geo.size.height * 0.36)
                        }
                    }
                }
            }
        }
    }

    private var empty: some View {
        Text(view == .bar ? "No drinks waiting." : "Nothing to cook. New orders appear here, oldest first.")
            .foregroundStyle(SN.mut).padding(40)
    }

    private func header(board: KitchenBoard, kitchen: Int, bar: Int, main: [KitchenBoard.Ticket], live: Bool) -> some View {
        var counts: [String: Int] = [:]
        for t in main { for l in t.lines where l.status != "READY" { counts[l.name, default: 0] += l.quantity } }
        let toMake = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }

        return VStack(alignment: .leading, spacing: 8) {
            Picker("This screen shows", selection: $viewRaw) {
                ForEach(KitchenView.allCases) { v in
                    Text("\(v.label) \(v == .both ? board.tickets.count : v == .kitchen ? kitchen : bar)").tag(v.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            if !toMake.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        PanelLabel(text: "To make")
                        ForEach(toMake, id: \.key) { name, n in
                            HStack(spacing: 4) { Text("\(n)").font(.subheadline.monospaced().weight(.bold)); Text(name).font(.subheadline) }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: Rail.corner).fill(SN.panel))
                                .overlay(RoundedRectangle(cornerRadius: Rail.corner).stroke(SN.line))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.spacingL).padding(.vertical, 10)
        .background(SN.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(SN.line).frame(height: 1) }
    }

    /// "8 tickets · oldest 12m", for the navigation bar's subtitle
    private var kitchenSubtitle: String {
        guard let board = store?.board else { return "" }
        let shown = view == .both ? board.tickets : board.tickets.filter { $0.lines.contains { $0.station == (view == .bar ? "bar" : "kitchen") } }
        let oldest = shown.map { Rail.minutes($0.createdAt, now: now) }.max() ?? 0
        return "\(shown.count) ticket\(shown.count == 1 ? "" : "s")\(shown.isEmpty ? "" : " · oldest \(Rail.waited(oldest))")"
    }

    private func barStrip(_ bar: [KitchenBoard.Ticket], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Bar · \(bar.count) ticket\(bar.count == 1 ? "" : "s")")
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(bar) { t in ticket(t, station: "bar", compact: true, live: live).frame(width: 236) }
                }
            }
        }
        .padding(.horizontal, DesignTokens.spacingL).padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SN.panel)
        .overlay(alignment: .top) { Rectangle().fill(SN.line).frame(height: 1) }
    }

    private func ticket(_ t: KitchenBoard.Ticket, station: String, compact: Bool, live: Bool) -> some View {
        TicketCard(ticket: t, station: station, minutes: minutes(t, live: live), compact: compact,
                   onTap: { line in Task { await store?.move(t, line, to: Rail.next(line.status)) } },
                   onSend: { lines in Task { await store?.send(t, lines) } },
                   onMore: { open = t })
            .allowsHitTesting(live)
    }
}

// MARK: - The rail's layout

/// Tickets flow down a column to the zone's height, then into the next,
/// oldest top-left, like newspaper columns. The newest wait off to the
/// right behind "+N newer".
private struct RailZone<Card: View>: View {
    let tickets: [KitchenBoard.Ticket]
    let height: CGFloat
    @ViewBuilder let card: (KitchenBoard.Ticket, Bool) -> Card
    @State private var lefts: [String: CGFloat] = [:]

    var body: some View {
        let compact = tickets.count > Rail.compactAfter
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    ColumnFlow(columnWidth: compact ? 236 : 260, spacing: 10, height: max(200, height)) {
                        ForEach(tickets) { t in
                            card(t, compact)
                                .id(t.id)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: TicketLeft.self, value: [t.id: g.frame(in: .named("zone")).minX])
                                })
                        }
                    }
                    .padding(.horizontal, DesignTokens.spacingL)
                    .padding(.top, 12)
                }
                .coordinateSpace(name: "zone")
                .onPreferenceChange(TicketLeft.self) { lefts = $0 }
                .overlay(alignment: .trailing) {
                    let hidden = tickets.filter { (lefts[$0.id] ?? 0) >= geo.size.width - 8 }
                    if let first = hidden.first {
                        Button {
                            withAnimation { proxy.scrollTo(first.id, anchor: .leading) }
                        } label: {
                            Label("+\(hidden.count) newer", systemImage: "chevron.right").labelStyle(TrailingIconLabel())
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(SN.panel)
                                .background(RoundedRectangle(cornerRadius: Rail.corner).fill(SN.ink))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                        .accessibilityIdentifier("kitchen-newer")
                    }
                }
            }
        }
        .frame(height: max(200, height) + 12)
    }
}

private struct TicketLeft: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Fills a column to `height`, then starts the next one to the right
private struct ColumnFlow: Layout {
    let columnWidth: CGFloat
    let spacing: CGFloat
    let height: CGFloat

    private func place(_ subviews: Subviews) -> (points: [CGPoint], columns: Int) {
        var points: [CGPoint] = []
        var col = 0
        var y: CGFloat = 0
        for view in subviews {
            let h = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            if y > 0 && y + h > height { col += 1; y = 0 }
            points.append(CGPoint(x: CGFloat(col) * (columnWidth + spacing), y: y))
            y += h + spacing
        }
        return (points, subviews.isEmpty ? 0 : col + 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cols = place(subviews).columns
        return CGSize(width: max(0, CGFloat(cols) * (columnWidth + spacing) - spacing), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = place(subviews).points
        for (view, p) in zip(subviews, points) {
            view.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: ProposedViewSize(width: columnWidth, height: nil))
        }
    }
}

private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}

// MARK: - A ticket

private struct TicketCard: View {
    let ticket: KitchenBoard.Ticket
    let station: String
    let minutes: Int
    let compact: Bool
    let onTap: (KitchenBoard.Line) -> Void
    let onSend: ([KitchenBoard.Line]) -> Void
    let onMore: () -> Void

    var body: some View {
        let lines = ticket.lines.filter { $0.station == station }
        let ready = lines.filter { $0.status == "READY" }
        let late = minutes >= 20, warn = minutes >= 10 && !late
        VStack(alignment: .leading, spacing: 0) {
            // The header's colour is the ticket's age: plain, amber at 10 minutes, red at 20
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ticket.where).font(compact ? .headline.weight(.bold) : .title2.weight(.bold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Rail.waited(minutes)).font((compact ? Font.subheadline : .body).monospaced().weight(.semibold))
                    .foregroundStyle(late ? .white : warn ? SN.amber : SN.ink)
                    .lineLimit(1).fixedSize()
                Button(action: onMore) { Image(systemName: "ellipsis").padding(4) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More for \(ticket.where)")
                    .accessibilityIdentifier("kitchen-more-\(ticket.id)")
            }
            .foregroundStyle(late ? .white : SN.ink)
            .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
            .background(late ? SN.red : warn ? SN.amber.opacity(0.2) : SN.panel2)

            Text("#\(ticket.number)\(ticket.waiter.map { " · \($0)" } ?? "")")
                .font(.caption).foregroundStyle(SN.mut).lineLimit(1)
                .padding(.horizontal, compact ? 10 : 12).padding(.top, 5)

            if let note = ticket.note {
                let alert = Rail.isAlert(note)
                Text((alert ? "⚠ " : "") + note)
                    .font((compact ? Font.caption : .subheadline).weight(.semibold))
                    .foregroundStyle(alert ? SN.red : SN.amber)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Rail.corner).fill((alert ? SN.red : SN.amber).opacity(0.14)))
                    .padding(.horizontal, 8).padding(.top, 6)
            }

            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                    if i > 0 { Rectangle().fill(SN.line).frame(height: 1) }
                    Button { onTap(l) } label: { line(l) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(l.quantity) \(l.name), \(Rail.word(l.status))")
                        .accessibilityHint("Tap to mark \(Rail.word(Rail.next(l.status)))")
                        .accessibilityIdentifier("kitchen-line-\(l.id)")
                }
            }
            .padding(.top, 4)

            if ready.count == lines.count {
                Button { onSend(ready) } label: {
                    Text("Send\(station == "bar" ? " drinks" : "") · \(ticket.where)")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Rail.corner))
                .controlSize(compact ? .regular : .large)
                .tint(SN.teal)
                .padding(8)
            } else {
                Text("\(ready.count) of \(lines.count) ready").font(.caption).foregroundStyle(SN.mut)
                    .padding(.horizontal, compact ? 10 : 12).padding(.vertical, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SN.panel)
        .clipShape(RoundedRectangle(cornerRadius: Rail.corner))
        .overlay(RoundedRectangle(cornerRadius: Rail.corner).stroke(SN.line))
    }

    private func line(_ l: KitchenBoard.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Marker(status: l.status).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text("\(l.quantity)×").font((compact ? Font.subheadline : .body).monospaced().weight(.semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(l.name).font(compact ? .subheadline : .body).foregroundStyle(l.status == "READY" ? SN.mut : SN.ink)
                if !l.extras.isEmpty { Text(l.extras.joined(separator: ", ")).font(.caption.weight(.semibold)).foregroundStyle(SN.amber) }
                if let n = l.notes { Text(n).font(.caption.weight(.semibold)).foregroundStyle(Rail.isAlert(n) ? SN.red : SN.amber) }
            }
            Spacer(minLength: 4)
            if !compact, let cook = l.cook { Text(cook).font(.caption2.monospaced()).foregroundStyle(SN.blue).lineLimit(1) }
        }
        .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
        .contentShape(Rectangle())
    }
}

private struct Marker: View {
    let status: String
    var body: some View {
        switch status {
        case "READY":
            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(SN.panel)
                .frame(width: 18, height: 18).background(Circle().fill(SN.teal))
        case "PREPARING":
            // Half full: started
            Circle().fill(SN.blue)
                .mask(HStack(spacing: 0) { Rectangle(); Color.clear })
                .overlay(Circle().stroke(SN.blue, lineWidth: 2))
                .frame(width: 18, height: 18)
        default:
            Circle().stroke(SN.mut, lineWidth: 2).frame(width: 18, height: 18)
        }
    }
}

// MARK: - Sheets

/// Everything that isn't a tap: set a dish directly, pick its cook, cancel, print
private struct TicketSheet: View {
    let ticket: KitchenBoard.Ticket
    let store: KitchenRailStore
    let onPrint: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cancelling = false
    @State private var cancellingLine: KitchenBoard.Line?
    @State private var reason = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(ticket.lines) { l in
                    Section {
                        Picker("State", selection: Binding(get: { l.status }, set: { s in Task { await store.move(ticket, l, to: s) } })) {
                            Text("To do").tag("PENDING"); Text("Cooking").tag("PREPARING"); Text("Ready").tag("READY")
                        }
                        .pickerStyle(.segmented)
                        Picker("Cook", selection: Binding(
                            get: { l.assigned ? store.staff.first { $0.name == l.cook }?.id ?? "" : "" },
                            set: { id in Task { await store.assign(ticket, l, to: id.isEmpty ? nil : id) } })) {
                            Text(l.cook.map { l.assigned ? "No cook assigned" : "\($0) (last moved it)" } ?? "No cook assigned").tag("")
                            ForEach(store.staff, id: \.id) { s in Text(s.name ?? "").tag(s.id ?? "") }
                        }
                        Button("Cancel dish", role: .destructive) { cancellingLine = l }
                    } header: {
                        Text("\(l.quantity)× \(l.name) · \(l.station)")
                    }
                }
                Section {
                    Button { onPrint() } label: { Label("Print ticket", systemImage: "printer") }
                    Button("Cancel order…", role: .destructive) { cancelling = true }
                }
            }
            .navigationTitle("\(ticket.where) · #\(ticket.number)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Cancel \(cancellingLine.map { "\($0.quantity) \($0.name)" } ?? "")?", isPresented: Binding(get: { cancellingLine != nil }, set: { if !$0 { cancellingLine = nil } })) {
                Button("Cancel Dish", role: .destructive) { if let l = cancellingLine { Task { await store.move(ticket, l, to: "CANCELLED") } } }
                Button("Keep It", role: .cancel) {}
            } message: { Text("It comes off the bill.") }
            .alert("Cancel the whole order for \(ticket.where)?", isPresented: $cancelling) {
                TextField("Reason (optional)", text: $reason)
                Button("Cancel Order", role: .destructive) {
                    Task { if await store.cancelOrder(ticket, reason: reason.trimmingCharacters(in: .whitespaces)) { dismiss() } }
                }
                Button("Keep It", role: .cancel) {}
            } message: { Text("It comes off the bill and the kitchen.") }
        }
        .frame(minWidth: 380, minHeight: 420)
    }
}

/// Sent in the last hour; an admin can put one back on the rail
private struct RecallSheet: View {
    let store: KitchenRailStore
    let isAdmin: Bool
    let now: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if (store.board?.recent ?? []).isEmpty { Text("Nothing sent in the last hour.").foregroundStyle(.secondary) }
                ForEach(store.board?.recent ?? []) { t in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.where).font(.headline)
                            + Text("  #\(t.number)\(t.sentAt.map { " · \(Rail.waited(Rail.minutes($0, now: now))) ago" } ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(t.lines.map { "\($0.quantity) \($0.name)" }.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isAdmin {
                            Button("Back to the rail") { Task { await store.putBack(t); dismiss() } }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Sent in the last hour")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 380, minHeight: 360)
    }
}

/// Which menu categories the bar makes (the rest go to the kitchen). Admins only
private struct BarSheet: View {
    let store: KitchenRailStore
    let board: KitchenBoard
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String>

    init(store: KitchenRailStore, board: KitchenBoard) {
        self.store = store
        self.board = board
        _picked = State(initialValue: Set(board.barCategoryIds ?? board.categories.filter { $0.type != "FOOD" }.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(board.categories) { c in
                        Toggle(isOn: Binding(get: { picked.contains(c.id) }, set: { if $0 { picked.insert(c.id) } else { picked.remove(c.id) } })) {
                            HStack { Text(c.name); Spacer(); Text(c.type.lowercased()).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                    }
                } footer: {
                    Text("Dishes in these categories go to the bar; everything else to the kitchen.")
                }
            }
            .navigationTitle("Made at the bar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await store.saveBar(Array(picked)) { dismiss() } } }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 480)
    }
}
