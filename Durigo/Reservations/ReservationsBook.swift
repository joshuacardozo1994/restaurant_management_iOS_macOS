//
//  ReservationsBook.swift
//  Durigo
//
//  Reservations as on the web's /reservations: the day's Book (half-hour
//  slots, late in red, one button for the next step), a Timeline (booked
//  tables down, the evening across) and the Week (covers per day). Data
//  from /api/reservations/day and /week; the rules (clashes, the table's
//  status) are the server's.
//

import SwiftUI

// MARK: - Model

struct ReservationDayData: Decodable {
    struct Booking: Decodable, Identifiable, Hashable {
        let id: String
        let date: String
        let time: String
        let startsAt: String
        let duration: Int
        let name: String
        let phone: String
        let people: Int
        let tableId: String?
        let table: Int?
        let status: String
        let note: String?
        let visits: Int
    }
    struct Table: Decodable, Identifiable, Hashable {
        let id: String
        let number: Int
        let capacity: Int
        let status: String
    }
    struct Coming: Decodable, Hashable { let date: String; let covers: Int; let bookings: Int }
    let date: String
    let bookings: [Booking]
    let tables: [Table]
    let opens: String
    let closes: String
    let coming: [Coming]
    let generatedAt: String
}

struct ReservationWeekData: Decodable {
    struct Day: Decodable, Identifiable {
        struct Item: Decodable, Identifiable { let id: String; let time: String; let name: String; let people: Int; let status: String }
        let date: String
        let covers: Int
        let bookings: Int
        let list: [Item]
        var id: String { date }
    }
    let start: String
    let seats: Int
    let days: [Day]
}

typealias Booking = ReservationDayData.Booking

private enum Book {
    static let corner: CGFloat = 4
    static let lateAfter: TimeInterval = 15 * 60
    static let holding: Set<String> = ["PENDING", "CONFIRMED", "ARRIVED"]

    static func minutes(_ t: String) -> Int {
        let p = t.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }
    static func clock(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }
    /// "19:30" → "7:30"
    static func short(_ t: String) -> String {
        let m = minutes(t); let h = m / 60
        return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m % 60))"
    }
    static func isLate(_ b: Booking, now: Date) -> Bool {
        guard b.status == "PENDING" || b.status == "CONFIRMED", let s = Fmt.date(b.startsAt) else { return false }
        return now.timeIntervalSince(s) > lateAfter
    }
    static func isAlert(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.range(of: "allerg|nut|gluten|shellfish|vegan|jain", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func pill(_ b: Booking, now: Date, today: Bool) -> (String, Color) {
        if today && isLate(b, now: now), let s = Fmt.date(b.startsAt) { return ("\(Int(now.timeIntervalSince(s) / 60))m late", SN.red) }
        switch b.status {
        case "PENDING": return ("Not confirmed", SN.amber)
        case "CONFIRMED": return ("Confirmed", SN.blue)
        case "ARRIVED": return ("Here", SN.teal)
        case "COMPLETED": return ("Done", SN.mut)
        case "NO_SHOW": return ("No-show", SN.mut)
        default: return ("Cancelled", SN.mut)
        }
    }
}

enum BookView: String, CaseIterable, Identifiable {
    case book, timeline, week
    var id: String { rawValue }
}

// MARK: - Store

@MainActor @Observable final class ReservationsBookStore {
    private let api: APIClient
    var day: ReservationDayData?
    var week: ReservationWeekData?
    var errorMessage: String?
    private var streamTask: Task<Void, Never>?

    init(session: Session) { self.api = APIClient(session: session) }

    func load(_ date: String) async {
        do {
            day = try JSONDecoder().decode(ReservationDayData.self, from: try await api.get("/api/reservations/day", query: [URLQueryItem(name: "date", value: date)]))
        } catch is CancellationError {
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func loadWeek(_ start: String) async {
        do {
            week = try JSONDecoder().decode(ReservationWeekData.self, from: try await api.get("/api/reservations/week", query: [URLQueryItem(name: "start", value: start)]))
        } catch is CancellationError {
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    /// The bookings on another date (for which tables are free)
    func bookings(on date: String) async -> [Booking] {
        if day?.date == date { return day?.bookings ?? [] }
        guard let data = try? await api.get("/api/reservations/day", query: [URLQueryItem(name: "date", value: date)]) else { return [] }
        return (try? JSONDecoder().decode(ReservationDayData.self, from: data))?.bookings ?? []
    }

    /// Change a booking; nil on success, else the server's reason
    func patch(_ b: Booking, _ body: [String: AnyEncodable]) async -> String? {
        defer { Task { await load(day?.date ?? b.date) } }
        do {
            _ = try await api.putJSON("/api/reservations/\(b.id)", payload: body)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    struct NewBooking: Encodable {
        let guestName: String; let guestPhone: String; let guestCount: Int
        let date: String; let time: String; let tableId: String?; let notes: String?
    }

    func create(_ b: NewBooking) async -> String? {
        do {
            _ = try await api.postJSON("/api/reservations", payload: b)
            await load(b.date)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    struct Regular: Decodable { let name: String?; let visits: Int }
    func lookup(_ phone: String) async -> Regular? {
        guard let data = try? await api.get("/api/customers/lookup", query: [URLQueryItem(name: "phone", value: phone)]) else { return nil }
        return try? JSONDecoder().decode(Regular.self, from: data)
    }

    /// Bookings made or changed elsewhere (the POS, another device) show up here
    func start(reload: @escaping () async -> Void) {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                do {
                    for try await ev in self.api.eventStream("/api/events") where ev.event != "heartbeat" && ev.event != "connection" {
                        await reload()
                    }
                    backoff = 1_000_000_000
                } catch is CancellationError { break } catch {
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 30_000_000_000)
                }
            }
        }
    }
    func stop() { streamTask?.cancel(); streamTask = nil }
}

/// A JSON value of any encodable type, for partial updates
struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeValue = value.encode }
    /// An explicit null (takes a booking off its table)
    static let null = AnyEncodable(Optional<String>.none)
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

// MARK: - Screen

struct ReservationsAdminView: View {
    @Environment(Session.self) private var session
    @State private var store: ReservationsBookStore?
    @AppStorage("reservations.view") private var viewRaw = BookView.book.rawValue
    @State private var date = ReportDate.today
    @State private var weekStart = ReportDate.today
    @State private var now = Date()
    @State private var editing: Booking?
    @State private var creating = false
    @State private var newTable: String?
    @State private var message: String?
    private static let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var view: BookView { BookView(rawValue: viewRaw) ?? .book }

    var body: some View {
        NavigationRoot {
            Group {
                if let day = store?.day {
                    content(day, live: true)
                } else {
                    content(.sample, live: false).skeleton(true).accessibilityIdentifier("reservations-loading")
                }
            }
            .background(SN.page)
            .foregroundStyle(SN.ink)
            .navigationTitle("Reservations")
            .navigationSubtitleIfAvailable(bookSubtitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newTable = nil; creating = true } label: { Label("Book", systemImage: "plus") }
                        .accessibilityIdentifier("admin-reservations-new")
                }
            }
            .task {
                if store == nil { store = ReservationsBookStore(session: session) }
                await store?.load(date)
                store?.start { [date] in
                    await store?.load(store?.day?.date ?? date)
                    if viewRaw == BookView.week.rawValue { await store?.loadWeek(weekStart) }
                }
            }
            .onDisappear { store?.stop() }
            .onReceive(Self.tick) { now = $0 }
            .onChange(of: date) { _, d in Task { await store?.load(d) } }
            .onChange(of: viewRaw) { _, v in if v == BookView.week.rawValue { Task { await store?.loadWeek(weekStart) } } }
            .onChange(of: weekStart) { _, s in Task { await store?.loadWeek(s) } }
            .refreshable { await store?.load(date) }
            .sheet(item: $editing) { b in
                if let store, let day = store.day { BookingSheet(store: store, day: day, booking: b, table: nil) { message = $0 } }
            }
            .sheet(isPresented: $creating) {
                if let store, let day = store.day { BookingSheet(store: store, day: day, booking: nil, table: newTable) { message = $0 } }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            }
        }
    }

    @ViewBuilder
    private func content(_ day: ReservationDayData, live: Bool) -> some View {
        GeometryReader { geo in
            scroll(day, live: live, width: geo.size.width)
        }
    }

    /// The side panel and seven week columns need room: about 980pt
    private func scroll(_ day: ReservationDayData, live: Bool, width: CGFloat) -> some View {
        let wide = width >= 980
        return ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                Picker("View", selection: $viewRaw) {
                    ForEach(BookView.allCases) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                if view != .week { dayStrip }
                switch view {
                case .book: BookList(day: day, now: now, wide: wide, live: live, onOpen: { editing = $0 }, onAction: act)
                case .timeline: BookingTimeline(day: day, now: now, onOpen: { editing = $0 }, onNew: { newTable = $0; creating = true })
                case .week: WeekView(week: store?.week, start: $weekStart, wide: wide, onDay: { date = $0; viewRaw = BookView.book.rawValue })
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .allowsHitTesting(live)
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    let d = ReportDate.add(ReportDate.today, days: i)
                    let on = d == date
                    let label = VStack(spacing: 1) {
                        Text(i == 0 ? "Today" : ReportDate.weekdayShort(d)).font(.subheadline)
                        Text("\(ReportDate.dayOfMonth(d))").font(.caption2.monospaced()).opacity(0.7)
                    }
                    .frame(minWidth: 40)
                    // The screen's ink would otherwise win over the filled button's own label colour
                    .foregroundStyle(on ? SN.page : SN.ink)
                    Group {
                        if on {
                            Button { date = d } label: { label }.buttonStyle(.borderedProminent).tint(SN.ink)
                        } else {
                            Button { date = d } label: { label }.buttonStyle(.bordered)
                        }
                    }
                    .buttonBorderShape(.roundedRectangle(radius: Book.corner))
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("day-\(i)")
                }
                DatePicker("Another day", selection: Binding(
                    get: { ReportDate.date(date) ?? .now },
                    set: { date = ReportDate.string($0) }), displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
            }
        }
    }

    /// "36 covers · 11 bookings · 2 here · 1 late" for the shown day
    private var bookSubtitle: String {
        guard let day = store?.day else { return "" }
        let booked = day.bookings.filter { $0.status != "CANCELLED" && $0.status != "NO_SHOW" }
        let today = day.date == ReportDate.today
        var parts = ["\(booked.reduce(0) { $0 + $1.people }) covers", "\(booked.count) booking\(booked.count == 1 ? "" : "s")"]
        if today { parts.append("\(booked.filter { $0.status == "ARRIVED" || $0.status == "COMPLETED" }.count) here") }
        let late = today ? booked.filter { Book.isLate($0, now: now) }.count : 0
        if late > 0 { parts.append("\(late) late") }
        return (today ? "Today · " : "\(ReportDate.label(day.date)) · ") + parts.joined(separator: " · ")
    }

    /// The row's button: confirm, or seat (then offer to take the order)
    private func act(_ b: Booking, _ status: String) {
        Task {
            if let error = await store?.patch(b, ["status": AnyEncodable(status)]) { message = error; return }
            if status == "ARRIVED" { message = "\(b.name) seated\(b.table.map { " at T\($0)" } ?? ""). Take their order from the POS." }
        }
    }
}

// MARK: - Book

private struct BookList: View {
    let day: ReservationDayData
    let now: Date
    let wide: Bool
    let live: Bool
    let onOpen: (Booking) -> Void
    let onAction: (Booking, String) -> Void

    var body: some View {
        let isToday = day.date == ReportDate.today || !live
        let booked = day.bookings.filter { $0.status != "CANCELLED" && $0.status != "NO_SHOW" }
        let gone = day.bookings.filter { $0.status == "CANCELLED" || $0.status == "NO_SHOW" }
        let slots = Dictionary(grouping: booked) { Book.minutes($0.time) / 30 * 30 }
        let keys = slots.keys.sorted()
        let covers = booked.reduce(0) { $0 + $1.people }
        let late = isToday ? booked.filter { Book.isLate($0, now: now) }.count : 0
        let here = booked.filter { $0.status == "ARRIVED" || $0.status == "COMPLETED" }.count

        HStack(alignment: .top, spacing: DesignTokens.spacingXL) {
            VStack(alignment: .leading, spacing: 0) {
                if booked.isEmpty {
                    Text("No bookings for \(isToday ? "today" : ReportDate.label(day.date)) yet.").foregroundStyle(SN.mut).frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(keys, id: \.self) { k in
                    let list = slots[k] ?? []
                    Divider().overlay(SN.line)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Book.short(Book.clock(k))).font(.body.monospaced().weight(.semibold)).fixedSize()
                            Text("\(list.reduce(0) { $0 + $1.people }) ppl").font(.caption2.monospaced()).foregroundStyle(SN.mut)
                        }
                        .frame(minWidth: wide ? 64 : 48, alignment: .leading)
                        .padding(.top, 8)
                        VStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                                if i > 0 { Rectangle().fill(SN.line).frame(height: 1).opacity(0.6) }
                                row(b, isToday: isToday)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !gone.isEmpty {
                    Divider().overlay(SN.line)
                    DisclosureGroup("Cancelled and no-shows · \(gone.count)") {
                        ForEach(gone) { b in row(b, isToday: isToday) }
                    }
                    .font(.subheadline).foregroundStyle(SN.mut).padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity)
            if wide { side(booked: booked, keys: keys, slots: slots, covers: covers, isToday: isToday).frame(width: 260) }
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 4) { Text("\(n)").font(.body.monospaced().weight(.semibold)); Text(label).foregroundStyle(SN.mut) }.font(.subheadline)
    }

    private func row(_ b: Booking, isToday: Bool) -> some View {
        let lateNow = isToday && Book.isLate(b, now: now)
        let done = ["ARRIVED", "COMPLETED", "CANCELLED", "NO_SHOW"].contains(b.status)
        let (label, color) = Book.pill(b, now: now, today: isToday)
        return HStack(alignment: .center, spacing: 10) {
            Text("\(b.people)").font(.title3.monospaced().weight(.bold)).frame(width: 30)
            Button { onOpen(b) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name).font(.body.weight(.semibold)).lineLimit(1)
                    // The status sits with the phone, whole: it never wraps mid-word
                    HStack(spacing: 6) {
                        Text(label).font(.caption2.monospaced().weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundStyle(lateNow ? .white : color)
                            .background(RoundedRectangle(cornerRadius: 3).fill(lateNow ? SN.red : color.opacity(0.14)))
                            .fixedSize()
                        Text(b.phone + (b.visits > 0 ? " · regular, \(b.visits) visit\(b.visits == 1 ? "" : "s")" : "")).font(.caption).foregroundStyle(SN.mut).lineLimit(1)
                    }
                    // Notes in full: an allergy must never be cut short
                    if let note = b.note { Text(note).font(.caption.weight(.semibold)).foregroundStyle(Book.isAlert(note) ? SN.red : SN.amber) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("booking-\(b.id)")
            action(b, late: lateNow)
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Book.corner).fill(lateNow ? SN.red.opacity(0.07) : .clear))
        .opacity(done ? 0.6 : 1)
    }

    @ViewBuilder private func action(_ b: Booking, late: Bool) -> some View {
        switch b.status {
        case "PENDING":
            Button("Confirm") { onAction(b, "CONFIRMED") }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: Book.corner)).tint(SN.ink)
        case "CONFIRMED":
            HStack(spacing: 6) {
                if late, let url = URL(string: "tel:\(b.phone.filter { $0.isNumber || $0 == "+" })") {
                    Link(destination: url) { Image(systemName: "phone") }.buttonStyle(.bordered).tint(SN.ink).accessibilityLabel("Call \(b.name)")
                }
                if b.tableId != nil {
                    Button("Seat\(b.table.map { " T\($0)" } ?? "")") { onAction(b, "ARRIVED") }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: Book.corner)).tint(SN.teal)
                } else {
                    Button("Pick table") { onOpen(b) }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: Book.corner)).tint(SN.ink)
                }
            }
        case "ARRIVED":
            Text(b.table.map { "T\($0)" } ?? "Here").font(.subheadline.monospaced()).foregroundStyle(SN.teal)
        default:
            EmptyView()
        }
    }

    private func side(booked: [Booking], keys: [Int], slots: [Int: [Booking]], covers: Int, isToday: Bool) -> some View {
        let peak = max(1, keys.map { k in (slots[k] ?? []).reduce(0) { $0 + $1.people } }.max() ?? 1)
        let held = Set(booked.filter { b in b.tableId != nil && (b.status == "ARRIVED" || (Fmt.date(b.startsAt).map { $0.timeIntervalSince(now) < 7200 } ?? false)) }.compactMap(\.tableId))
        let free = day.tables.filter { $0.status == "AVAILABLE" && !held.contains($0.id) }
        return VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            VStack(alignment: .leading, spacing: 2) {
                PanelLabel(text: isToday ? "Tonight" : ReportDate.label(day.date))
                Text("\(covers) covers").font(.largeTitle.weight(.semibold)).monospacedDigit()
            }
            if !keys.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    PanelLabel(text: "Through the evening")
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(keys, id: \.self) { k in
                            let n = (slots[k] ?? []).reduce(0) { $0 + $1.people }
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 2).fill(n == peak && keys.count > 1 ? SN.amber : SN.teal)
                                    .frame(height: max(4, 70 * CGFloat(n) / CGFloat(peak)))
                                Text(Book.short(Book.clock(k))).font(.system(size: 8).monospaced()).foregroundStyle(SN.mut).fixedSize()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 86, alignment: .bottom)
                }
            }
            if isToday {
                VStack(alignment: .leading, spacing: 6) {
                    PanelLabel(text: "Free for walk-ins now")
                    Text(free.isEmpty ? "None free" : free.prefix(12).map { "T\($0.number)" }.joined(separator: "  ") + (free.count > 12 ? "  +\(free.count - 12) more" : ""))
                        .font(.caption.monospaced()).foregroundStyle(free.isEmpty ? SN.mut : SN.ink)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                PanelLabel(text: "Coming days")
                ForEach(day.coming, id: \.date) { c in
                    Text("\(ReportDate.label(c.date)) · \(c.covers) covers · \(c.bookings) booking\(c.bookings == 1 ? "" : "s")").font(.caption).foregroundStyle(SN.mut)
                }
            }
        }
        .padding(.leading, DesignTokens.spacingL)
        .overlay(alignment: .leading) { Rectangle().fill(SN.line).frame(width: 1) }
    }
}

// MARK: - Timeline

private struct BookingTimeline: View {
    let day: ReservationDayData
    let now: Date
    let onOpen: (Booking) -> Void
    let onNew: (String) -> Void
    private let perHour: CGFloat = 120
    private let labelWidth: CGFloat = 56

    var body: some View {
        let booked = day.bookings.filter { $0.status != "CANCELLED" && $0.status != "NO_SHOW" }
        let (from, to) = span(booked)
        let width = CGFloat(to - from) / 60 * perHour
        let x = { (m: Int) in CGFloat(m - from) / 60 * perHour }
        let byTable = Dictionary(grouping: booked.filter { $0.tableId != nil }) { $0.tableId! }
        let noTable = booked.filter { $0.tableId == nil && Book.holding.contains($0.status) }
        let empty = day.tables.filter { byTable[$0.id] == nil }

        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelWidth, height: 1)
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(stride(from: from, through: to, by: 60)), id: \.self) { h in
                                Text(Book.short(Book.clock(h))).font(.caption2.monospaced()).foregroundStyle(SN.mut).offset(x: x(h) + 2)
                            }
                        }
                        .frame(width: width, height: 18, alignment: .topLeading)
                    }
                    ForEach(day.tables.filter { byTable[$0.id] != nil }) { t in
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("T\(t.number)").font(.subheadline.monospaced().weight(.semibold))
                                Text("\(t.capacity) seats").font(.system(size: 9)).foregroundStyle(SN.mut)
                            }
                            .frame(width: labelWidth, alignment: .leading)
                            ZStack(alignment: .topLeading) {
                                ForEach(Array(stride(from: from, through: to, by: 60)), id: \.self) { h in
                                    Rectangle().fill(SN.line).frame(width: 1, height: 48).offset(x: x(h))
                                }
                                ForEach(byTable[t.id] ?? []) { b in block(b, list: byTable[t.id] ?? []).offset(x: x(Book.minutes(b.time)) + 1, y: 5) }
                            }
                            .frame(width: width, height: 48, alignment: .topLeading)
                        }
                        .overlay(alignment: .top) { Rectangle().fill(SN.line).frame(height: 1) }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if day.date == ReportDate.today {
                        let cal = Calendar(identifier: .gregorian)
                        let ist = cal.dateComponents(in: TimeZone(identifier: "Asia/Kolkata")!, from: now)
                        let m = (ist.hour ?? 0) * 60 + (ist.minute ?? 0)
                        if m > from && m < to {
                            Rectangle().fill(SN.red).frame(width: 2).offset(x: labelWidth + x(m)).accessibilityHidden(true)
                        }
                    }
                }
            }
            if !empty.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    PanelLabel(text: "Free all evening · \(empty.count)")
                    FlowChips(items: empty.map { ($0.id, "T\($0.number)") }, onTap: onNew)
                }
            }
            if !noTable.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    PanelLabel(text: "No table yet")
                    FlowChips(items: noTable.map { ($0.id, "\($0.name) · \($0.people) · \(Book.short($0.time))") }) { id in
                        if let b = noTable.first(where: { $0.id == id }) { onOpen(b) }
                    }
                }
            }
        }
    }

    /// The evening the bookings span, on whole hours, at least four of them
    private func span(_ booked: [Booking]) -> (Int, Int) {
        let from = max(0, booked.map { Book.minutes($0.time) }.min().map { ($0 - 30) / 60 * 60 } ?? Book.minutes(day.opens))
        let to = booked.map { Book.minutes($0.time) + $0.duration }.max().map { ($0 + 89) / 60 * 60 } ?? Book.minutes(day.closes)
        return (from, max(to, from + 240))
    }

    private func block(_ b: Booking, list: [Booking]) -> some View {
        let clash = Book.holding.contains(b.status) && list.contains { o in
            o.id != b.id && Book.holding.contains(o.status)
                && Book.minutes(o.time) < Book.minutes(b.time) + b.duration && Book.minutes(b.time) < Book.minutes(o.time) + o.duration
        }
        let late = day.date == ReportDate.today && Book.isLate(b, now: now)
        let tone: Color = clash ? SN.red : b.status == "ARRIVED" || b.status == "COMPLETED" ? SN.teal : b.status == "PENDING" ? SN.amber : SN.blue
        return Button { onOpen(b) } label: {
            HStack(spacing: 4) {
                Text("\(b.name) · \(b.people)").font(.caption.weight(.semibold))
                Text(Book.short(b.time) + (b.note.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(SN.mut)
            }
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: CGFloat(b.duration) / 60 * perHour - 3, height: 38, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Book.corner).fill(tone.opacity(clash ? 0.22 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius: Book.corner).strokeBorder(late ? SN.red : tone.opacity(0.5), style: StrokeStyle(lineWidth: late ? 2 : 1, dash: b.status == "PENDING" ? [4, 3] : [])))
            .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(b.name), \(b.people) at \(Book.short(b.time))")
    }
}

/// Chips that wrap onto new lines
private struct FlowChips: View {
    let items: [(String, String)]
    let onTap: (String) -> Void
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.0) { id, label in
                Button { onTap(id) } label: {
                    Text(label).font(.caption.monospaced()).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(SN.panel2))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct WrapLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width && x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Week

private struct WeekView: View {
    let week: ReservationWeekData?
    @Binding var start: String
    let wide: Bool
    let onDay: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            HStack {
                Button { start = ReportDate.add(start, days: -7) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous week")
                Text("\(ReportDate.label(start)) – \(ReportDate.label(ReportDate.add(start, days: 6)))").font(.subheadline.weight(.semibold))
                Button { start = ReportDate.add(start, days: 7) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next week")
            }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: Book.corner)).tint(SN.ink)
            if let week {
                if wide {
                    HStack(alignment: .top, spacing: 8) { ForEach(week.days) { d in dayCard(d, seats: week.seats, column: true) } }
                } else {
                    VStack(spacing: 8) { ForEach(week.days) { d in dayCard(d, seats: week.seats, column: false) } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            }
        }
    }

    private func dayCard(_ d: ReservationWeekData.Day, seats: Int, column: Bool) -> some View {
        let fill = seats > 0 ? min(1, Double(d.covers) / Double(seats)) : 0
        let today = d.date == ReportDate.today
        let head = VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(today ? "Today \(ReportDate.dayOfMonth(d.date))" : "\(ReportDate.weekdayShort(d.date)) \(ReportDate.dayOfMonth(d.date))").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(d.bookings) bk").font(.caption2.monospaced()).foregroundStyle(SN.mut)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(d.covers)").font(.title2.monospaced().weight(.semibold))
                Text("covers").font(.caption).foregroundStyle(SN.mut)
            }
            GeometryReader { g in
                Capsule().fill(SN.panel2).overlay(alignment: .leading) { Capsule().fill(fill > 0.85 ? SN.amber : SN.teal).frame(width: g.size.width * fill) }
            }
            .frame(height: 5)
        }
        let list = VStack(alignment: .leading, spacing: 3) {
            ForEach(d.list.prefix(column ? 8 : 4)) { b in
                HStack(spacing: 4) {
                    Text(Book.short(b.time)).font(.caption.monospaced().weight(.semibold))
                    Text("\(b.name) · \(b.people)").font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 3).fill(b.people >= 8 ? SN.amber.opacity(0.14) : SN.panel2))
            }
            if d.list.count > (column ? 8 : 4) { Text("+\(d.list.count - (column ? 8 : 4)) more").font(.caption).foregroundStyle(SN.mut) }
        }
        return Button { onDay(d.date) } label: {
            Group {
                if column { VStack(alignment: .leading, spacing: 8) { head; list; Spacer(minLength: 0) } }
                else { HStack(alignment: .top, spacing: 12) { head.frame(width: 110); list } }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: column ? 260 : 0, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Book.corner).fill(SN.panel))
            .overlay(RoundedRectangle(cornerRadius: Book.corner).stroke(today ? SN.teal : SN.line, lineWidth: today ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Booking form

/// New or existing booking: phone first (a regular's name fills in), then
/// people, day, time, table and a note; an existing one can be confirmed,
/// cancelled or marked a no-show
private struct BookingSheet: View {
    let store: ReservationsBookStore
    let day: ReservationDayData
    let booking: Booking?
    let onMessage: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phone: String
    @State private var name: String
    @State private var people: Int
    @State private var date: Date
    @State private var time: String
    @State private var tableId: String
    @State private var note: String
    @State private var regular: String?
    @State private var others: [Booking] = []
    @State private var error: String?
    @State private var saving = false

    init(store: ReservationsBookStore, day: ReservationDayData, booking: Booking?, table: String?, onMessage: @escaping (String) -> Void) {
        self.store = store; self.day = day; self.booking = booking; self.onMessage = onMessage
        _phone = State(initialValue: booking?.phone ?? "")
        _name = State(initialValue: booking?.name ?? "")
        _people = State(initialValue: booking?.people ?? 2)
        _date = State(initialValue: ReportDate.date(booking?.date ?? max(day.date, ReportDate.today)) ?? .now)
        _time = State(initialValue: booking?.time ?? "20:00")
        _tableId = State(initialValue: booking?.tableId ?? table ?? "")
        _note = State(initialValue: booking?.note ?? "")
    }

    private var dateString: String { ReportDate.string(date) }
    private var slots: [String] {
        let from = (Book.minutes(day.opens) + 29) / 30 * 30, to = Book.minutes(day.closes)
        return stride(from: from, to: to, by: 30).map { Book.clock($0) }
    }
    private func takenBy(_ t: ReservationDayData.Table) -> Booking? {
        let s = Book.minutes(time)
        return others.first { o in o.id != booking?.id && o.tableId == t.id && Book.holding.contains(o.status)
            && Book.minutes(o.time) < s + 120 && s < Book.minutes(o.time) + o.duration }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Phone", text: $phone)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        #endif
                        .accessibilityIdentifier("reservation-form-phone")
                        .onChange(of: phone) { _, p in lookup(p) }
                    if let regular { Text("Regular: \(regular)").font(.caption).foregroundStyle(SN.teal) }
                    TextField("Name", text: $name).accessibilityIdentifier("reservation-form-name")
                    Stepper("\(people) \(people == 1 ? "person" : "people")", value: $people, in: 1...40)
                }
                Section {
                    DatePicker("Day", selection: $date, displayedComponents: .date).environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    Picker("Time", selection: $time) {
                        if !slots.contains(time) { Text(Book.short(time)).tag(time) }
                        ForEach(slots, id: \.self) { s in Text("\(Book.short(s)) \(Book.minutes(s) >= 720 ? "pm" : "am")").tag(s) }
                    }
                    .accessibilityIdentifier("reservation-form-time")
                    Picker("Table", selection: $tableId) {
                        Text("No table yet").tag("")
                        ForEach(day.tables) { t in
                            let taken = takenBy(t)
                            Text("T\(t.number) · \(t.capacity) seats\(taken.map { " · booked for \($0.name) at \(Book.short($0.time))" } ?? (t.capacity < people ? " · small" : ""))").tag(t.id)
                        }
                    }
                    TextField("Note: birthday, allergy, window seat", text: $note)
                }
                if let error { Section { Text(error).foregroundStyle(SN.red) } }
                if let b = booking, Book.holding.contains(b.status), b.status != "ARRIVED" {
                    Section {
                        if b.status == "PENDING" { Button("Confirm") { status("CONFIRMED") } }
                        Button("No-show", role: .destructive) { status("NO_SHOW") }
                        Button("Cancel booking", role: .destructive) { status("CANCELLED") }
                    }
                }
            }
            .navigationTitle(booking.map { "\($0.name) · \(ReportDate.label($0.date))" } ?? "New booking")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(booking == nil ? "Book" : "Save") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || phone.filter(\.isNumber).count < 10)
                }
            }
            .task(id: dateString) { others = await store.bookings(on: dateString) }
        }
        .frame(minWidth: 400, minHeight: 520)
    }

    private func lookup(_ p: String) {
        guard booking == nil, p.filter(\.isNumber).count >= 10 else { regular = nil; return }
        Task {
            guard let c = await store.lookup(p) else { return }
            if name.isEmpty, let n = c.name { name = n }
            regular = "\(c.name ?? "Known number") · \(c.visits) visit\(c.visits == 1 ? "" : "s")"
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            let trimmedNote = note.trimmingCharacters(in: .whitespaces)
            if let b = booking {
                let body: [String: AnyEncodable] = [
                    "guestName": AnyEncodable(name.trimmingCharacters(in: .whitespaces)), "guestPhone": AnyEncodable(phone),
                    "guestCount": AnyEncodable(people), "date": AnyEncodable(dateString), "time": AnyEncodable(time),
                    "tableId": tableId.isEmpty ? .null : AnyEncodable(tableId),
                    "notes": trimmedNote.isEmpty ? .null : AnyEncodable(trimmedNote),
                ]
                if let e = await store.patch(b, body) { error = e } else { dismiss() }
            } else {
                let new = ReservationsBookStore.NewBooking(guestName: name.trimmingCharacters(in: .whitespaces), guestPhone: phone, guestCount: people,
                                                          date: dateString, time: time, tableId: tableId.isEmpty ? nil : tableId, notes: trimmedNote.isEmpty ? nil : trimmedNote)
                if let e = await store.create(new) { error = e } else {
                    onMessage("Booked \(new.guestName), \(people) at \(Book.short(time)) on \(ReportDate.label(dateString))")
                    dismiss()
                }
            }
        }
    }

    private func status(_ s: String) {
        guard let b = booking else { return }
        Task { if let e = await store.patch(b, ["status": AnyEncodable(s)]) { error = e } else { dismiss() } }
    }
}
