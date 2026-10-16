//
//  ReportOverview.swift
//  Durigo
//
//  The Reports screen, as on the web's /reports: takings over a period
//  against the period before, by day, hour, dish, tender and waiter, and
//  the month as a calendar. Figures come from /api/reports/overview, so
//  they match the web and the Bills ledger (admin and cashier; cashiers
//  get no staff figures).
//

import SwiftUI

// MARK: - Model

struct ReportOverview: Decodable {
    struct Period: Decodable, Equatable {
        let range: String
        let from: String
        let to: String
        let prevFrom: String
        let prevTo: String
        let label: String
        let prevLabel: String
        let month: String
    }
    struct Figures: Decodable, Equatable {
        let takings: Double
        let bills: Int
        let averageBill: Double
        let discounts: Double
        let cancelledDishes: Int
        let cancelledValue: Double
    }
    struct Day: Decodable, Equatable, Identifiable {
        let date: String
        let takings: Double
        let bills: Int
        let topDish: String?
        var id: String { date }
    }
    struct Heat: Decodable, Equatable {
        let hours: [Int]
        let cells: [[Int]]
    }
    struct Dish: Decodable, Equatable, Identifiable {
        let name: String
        let quantity: Double
        let takings: Double
        var id: String { name }
    }
    struct Tender: Decodable, Equatable, Identifiable {
        let method: String
        let amount: Double
        var id: String { method }
    }
    struct Code: Decodable, Equatable, Identifiable {
        let code: String
        let uses: Int
        var id: String { code }
    }
    struct Waiter: Decodable, Equatable, Identifiable {
        let name: String
        let bills: Int
        let takings: Double
        var id: String { name }
    }

    let period: Period
    let figures: Figures
    let previous: Figures
    let days: [Day]
    let previousDays: [Double]
    let bestDay: Day?
    let heat: Heat
    let dishes: [Dish]
    let tenders: [Tender]
    let splitBills: Int
    let codes: [Code]
    /// nil for cashiers
    let waiters: [Waiter]?
    let ca: CAReportData
}

enum ReportRange: String, CaseIterable, Identifiable {
    case today, week = "7d", month, quarter, pick
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "Month"
        case .quarter: "Quarter"
        case .pick: "Dates"
        }
    }
}

/// Calendar dates as the server sends them ("2026-10-15"), worked on in UTC
/// so a date never shifts with the device's time zone
enum ReportDate {
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    static func date(_ s: String) -> Date? { parser.date(from: s) }
    static func string(_ d: Date) -> String { parser.string(from: d) }
    static func add(_ s: String, days: Int) -> String {
        guard let d = date(s), let n = cal.date(byAdding: .day, value: days, to: d) else { return s }
        return string(n)
    }
    /// 0 = Monday
    static func weekdayIndex(_ s: String) -> Int {
        guard let d = date(s) else { return 0 }
        return (cal.component(.weekday, from: d) + 5) % 7
    }
    static func dayOfMonth(_ s: String) -> Int { Int(s.suffix(2)) ?? 1 }
    /// "Thu 15 Oct"
    static func label(_ s: String) -> String {
        guard let d = date(s) else { return s }
        let c = cal.dateComponents([.weekday, .day, .month], from: d)
        return "\(weekdays[(c.weekday ?? 1) - 1]) \(c.day ?? 1) \(months[(c.month ?? 1) - 1].prefix(3))"
    }
    static func weekdayShort(_ s: String) -> String { String(label(s).prefix(3)) }
    /// "2026-10" → "October"
    static func monthName(_ month: String) -> String { months[max(0, min(11, (Int(month.suffix(2)) ?? 1) - 1))] }
    static func shiftMonth(_ month: String, by n: Int) -> String {
        guard let d = date("\(month)-01"), let m = cal.date(byAdding: .month, value: n, to: d) else { return month }
        return String(string(m).prefix(7))
    }
    static func daysInMonth(_ month: String) -> Int {
        guard let d = date("\(month)-01"), let r = cal.range(of: .day, in: .month, for: d) else { return 30 }
        return r.count
    }
    /// Today in Goa
    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - Store

@MainActor @Observable final class ReportOverviewStore {
    private let api: APIClient
    var data: ReportOverview?
    var isLoading = false
    var error: String?
    /// Files to share, made when the report arrives
    var reportCSV: URL?
    var caCSV: URL?
    var caPDF: URL?

    init(session: Session) { self.api = APIClient(session: session) }

    func load(range: ReportRange, month: String?, from: Date, to: Date) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        var query = [URLQueryItem(name: "range", value: range.rawValue)]
        if range == .month, let month { query.append(URLQueryItem(name: "month", value: month)) }
        if range == .pick {
            query.append(URLQueryItem(name: "from", value: ReportDate.string(Self.istDay(from))))
            query.append(URLQueryItem(name: "to", value: ReportDate.string(Self.istDay(to))))
        }
        do {
            let bytes = try await api.get("/api/reports/overview", query: query)
            let report = try JSONDecoder().decode(ReportOverview.self, from: bytes)
            data = report
            makeExports(report)
        } catch is CancellationError {
            // A newer range was asked for
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The date a DatePicker shows, as a calendar date (it picks in the device's zone)
    private static func istDay(_ d: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return ReportDate.date(String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)) ?? d
    }

    private func makeExports(_ r: ReportOverview) {
        let dir = FileManager.default.temporaryDirectory
        func write(_ name: String, _ text: String) -> URL? {
            let url = dir.appendingPathComponent(name)
            return (try? text.write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
        }
        let ca = r.ca
        let stem = String(format: "ca-report-%04d-%02d", ca.year, ca.month)
        reportCSV = write("durigos-report-\(r.period.from)-to-\(r.period.to).csv", ReportCSV.report(r))
        caCSV = write("\(stem).csv", ReportCSV.sections(ReportCSV.ca(ca)))
        caPDF = CAPDF.render(ca, to: dir.appendingPathComponent("\(stem).pdf"))
    }
}

// MARK: - Exports

enum ReportCSV {
    typealias Section = (title: String, header: [String], rows: [[String]])

    /// A cell a spreadsheet won't run as a formula
    static func cell(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
        return v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\"" : v
    }

    static func sections(_ sections: [Section]) -> String {
        sections.map { s in
            ([cell(s.title), s.header.map(cell).joined(separator: ",")] + (s.rows.isEmpty ? ["(none)"] : s.rows.map { $0.map(cell).joined(separator: ",") }))
                .joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    static func num(_ d: Double) -> String { String(Int(d.rounded())) }

    static func ca(_ ca: CAReportData) -> [Section] {
        [
            ("\(ca.monthLabel) Sales Report", ["item", "value"], [
                ["Total sales", String(ca.totalSales)], ["Items sold", String(ca.totalItems)], ["Bills", String(ca.totalBills)],
                ["GST collected", String(ca.totalGst ?? 0)], ["VAT collected", String(ca.totalVat ?? 0)],
            ]),
            ("Category breakdown", ["category", "sales", "percent"], ca.categories.map { [CAText.category($0.type), String($0.revenue), String(format: "%.1f", $0.percentage)] }),
        ]
    }

    static func report(_ r: ReportOverview) -> String {
        let f = r.figures, p = r.previous
        var s: [Section] = [
            ("Durigo's report, \(r.period.from) to \(r.period.to)", ["figure", "value", "before"], [
                ["Takings", num(f.takings), num(p.takings)], ["Bills", String(f.bills), String(p.bills)],
                ["Average bill", num(f.averageBill), num(p.averageBill)], ["Discounts", num(f.discounts), num(p.discounts)],
                ["Cancelled dishes", String(f.cancelledDishes), String(p.cancelledDishes)], ["Cancelled value", num(f.cancelledValue), num(p.cancelledValue)],
            ]),
            ("Each day", ["date", "takings", "bills", "top_dish"], r.days.map { [$0.date, num($0.takings), String($0.bills), $0.topDish ?? ""] }),
            ("What sells", ["dish", "sold", "value"], r.dishes.map { [$0.name, num($0.quantity), num($0.takings)] }),
            ("How they pay", ["method", "amount"], r.tenders.map { [$0.method, num($0.amount)] }),
        ]
        if let w = r.waiters { s.append(("Who served", ["waiter", "bills", "takings"], w.map { [$0.name, String($0.bills), num($0.takings)] })) }
        return sections(s + ca(r.ca))
    }
}

enum CAText {
    static func category(_ type: String) -> String {
        switch type {
        case "FOOD": "Food"
        case "BEVERAGE": "Beverage"
        case "ALCOHOL": "Alcohol"
        default: type.capitalized
        }
    }

    /// The summary to paste into a message to the CA
    static func text(_ ca: CAReportData) -> String {
        var lines = [
            "\(ca.monthLabel) Sales Report", "",
            "Total Sales: \(ca.totalSales.rupees)",
            "Total Items Sold: \(ca.totalItems)",
            "Total Bills: \(ca.totalBills)",
        ]
        if let gst = ca.totalGst, let vat = ca.totalVat {
            lines.append("GST collected (food & soft drinks): \(gst.rupees)")
            lines.append("VAT collected (liquor): \(vat.rupees)")
        }
        lines += ["", "Category Breakdown:"]
        lines += ca.categories.map { "\(category($0.type)) Sales: \($0.revenue.rupees) (\(String(format: "%.1f", $0.percentage))%)" }
        return lines.joined(separator: "\n")
    }
}

/// The CA summary on one A4 page, the same as the web's /print/ca
enum CAPDF {
    @MainActor
    static func render(_ ca: CAReportData, to url: URL) -> URL? {
        let renderer = ImageRenderer(content: CASheet(ca: ca).frame(width: 595, height: 842))
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        return ok ? url : nil
    }

    private struct CASheet: View {
        let ca: CAReportData
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Durigo's · \(ca.monthLabel) Sales Report").font(.system(size: 20, weight: .bold))
                Text("Amounts collected after discounts, including taxes, for the Goa calendar month. Completed bills only.")
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.35))
                VStack(spacing: 0) {
                    row("Total sales", ca.totalSales.rupees, bold: true)
                    row("Total bills", "\(ca.totalBills)")
                    row("Total items sold", "\(ca.totalItems)")
                    row("GST collected (food and soft drinks)", (ca.totalGst ?? 0).rupees)
                    row("VAT collected (liquor)", (ca.totalVat ?? 0).rupees)
                }
                VStack(spacing: 0) {
                    ForEach(ca.categories) { c in
                        row(CAText.category(c.type), "\(c.revenue.rupees)   \(String(format: "%.1f", c.percentage))%")
                    }
                }
                Spacer()
                Text("Generated \(Date().formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundStyle(Color(white: 0.5))
            }
            .padding(50)
            .foregroundStyle(Color.black)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }
        private func row(_ k: String, _ v: String, bold: Bool = false) -> some View {
            VStack(spacing: 0) {
                HStack { Text(k); Spacer(); Text(v).monospacedDigit() }
                    .font(.system(size: 12, weight: bold ? .bold : .regular))
                    .padding(.vertical, 6)
                Rectangle().fill(Color(white: bold ? 0.1 : 0.85)).frame(height: bold ? 1.5 : 0.5)
            }
        }
    }
}

// MARK: - Screen

/// Routes inside the Reports stack, and `--start-report=` for screenshots
enum ReportBreakout: String, Hashable, CaseIterable {
    case customers, inventory, ca
}

struct Reports: View {
    @Environment(Session.self) private var session
    @State private var store: ReportOverviewStore?
    @State private var range: ReportRange = .week
    @State private var month: String?
    @State private var pickFrom = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var pickTo = Date.now
    @State private var picking = false
    /// DEBUG launch args already gave the days to pick
    @State private var presetPick = false
    @State private var selectedDay: String?
    @State private var path = NavigationPath()
    @Environment(\.inNavigationStack) private var inStack

    var body: some View {
        Group {
            // Opened from More: push onto its stack rather than nesting another
            if inStack {
                screen
            } else {
                NavigationStack(path: $path) { screen }
                    .environment(\.inNavigationStack, true)
            }
        }
        .lockWithBiometric()
    }

    private var subtitle: String {
        guard let p = store?.data?.period else { return "" }
        return "\(p.label) · vs \(p.prevLabel)"
    }

    private var screen: some View {
            GeometryReader { geo in
                ScrollView {
                    content(width: geo.size.width - DesignTokens.spacingL * 2)
                        .padding(DesignTokens.spacingL)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable { await load() }
            }
            .background(SN.page)
            .foregroundStyle(SN.ink)
            .navigationTitle("Reports")
            .navigationSubtitleIfAvailable(subtitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button { picking = true } label: { Label("Pick dates…", systemImage: "calendar") }
                        .accessibilityIdentifier("report-pick-dates")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = store?.reportCSV {
                        ShareLink(item: url) { Label("Export", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("report-export")
                    }
                }
            }
            .task {
                if store == nil { store = ReportOverviewStore(session: session) }
                applyDebugLaunchArgs()
                await load()
            }
            .onChange(of: range) { _, new in
                if new == .pick && !presetPick { picking = true } else { presetPick = false; Task { await load() } }
            }
            .onChange(of: month) { _, _ in Task { await load() } }
            .sheet(isPresented: $picking) { pickSheet }
            .navigationDestination(for: ReportBreakout.self) { route in
                switch route {
                case .customers: CustomersReportView()
                case .inventory: InventoryReportView()
                case .ca:        CAReportView()
                }
            }
    }

    private func load() async {
        selectedDay = nil
        await store?.load(range: range, month: month, from: pickFrom, to: pickTo)
    }

    /// `--report-range=month` (with `--report-from=` / `--report-to=` for pick) and `--start-report=<name>` (DEBUG, for screenshots)
    private func applyDebugLaunchArgs() {
        #if DEBUG
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--report-range="), let r = ReportRange(rawValue: String(arg.dropFirst("--report-range=".count))) { range = r }
            if arg.hasPrefix("--report-from="), let d = ReportDate.date(String(arg.dropFirst("--report-from=".count))) { pickFrom = d }
            if arg.hasPrefix("--report-to="), let d = ReportDate.date(String(arg.dropFirst("--report-to=".count))) { pickTo = d; presetPick = true }
            if path.isEmpty, arg.hasPrefix("--start-report="), let route = ReportBreakout(rawValue: String(arg.dropFirst("--start-report=".count))) { path.append(route) }
        }
        #endif
    }

    private var pickSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $pickFrom, in: ...pickTo, displayedComponents: .date)
                DatePicker("To", selection: $pickTo, in: pickFrom...Date.now, displayedComponents: .date)
            }
            .navigationTitle("Pick the days")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        picking = false
                        if store?.data?.period.range != "pick" { range = ReportRange(rawValue: store?.data?.period.range ?? "7d") ?? .week }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") {
                        picking = false
                        // From the toolbar: switching to Dates loads through onChange
                        if range != .pick { presetPick = true; range = .pick } else { Task { await load() } }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .frame(minWidth: 320, minHeight: 240)
    }

    // MARK: Layout

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        let loading = store?.data == nil && (store?.isLoading ?? true)
        VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            Picker("Period", selection: $range) {
                ForEach(ReportRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            .accessibilityIdentifier("report-range")

            if let msg = store?.error {
                Label(store?.data == nil ? "Couldn't load the report: \(msg)" : "Showing the last figures: \(msg)", systemImage: "wifi.exclamationmark")
                    .font(.footnote).foregroundStyle(SN.red)
            }

            if let r = store?.data ?? (loading ? ReportOverview.sample(range: range) : nil) {
                Group {
                    // Older systems have no navigation subtitle: keep the period in the content
                    if #unavailable(iOS 26, macOS 26) {
                        Text("\(r.period.label) · vs \(r.period.prevLabel)")
                            .font(.subheadline).foregroundStyle(SN.mut)
                    }
                    if r.period.range == "month" {
                        MonthLayout(r: r, width: width, selected: $selectedDay, month: $month, caCSV: store?.caCSV, caPDF: store?.caPDF)
                    } else {
                        RangeLayout(r: r, width: width, caCSV: store?.caCSV, caPDF: store?.caPDF)
                    }
                    if r.waiters != nil { moreLinks }
                }
                .skeleton(loading)
            }
        }
    }

    private var moreLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.spacingL) { PanelLabel(text: "More"); links }
            VStack(alignment: .leading, spacing: DesignTokens.spacingS) { PanelLabel(text: "More"); links }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var links: some View {
        NavigationLink("Customers", value: ReportBreakout.customers)
        NavigationLink("Stock", value: ReportBreakout.inventory)
        NavigationLink("CA report by month", value: ReportBreakout.ca)
    }
}

// MARK: - Shared pieces

private func pctChange(_ now: Double, _ before: Double) -> Int? {
    before > 0 ? Int(((now - before) / before * 100).rounded()) : nil
}

private struct Change: View {
    let now: Double
    let before: Double
    var body: some View {
        if let p = pctChange(now, before) {
            Text("\(p >= 0 ? "▲" : "▼") \(abs(p))%").foregroundStyle(p >= 0 ? SN.teal : SN.red)
        } else {
            Text("none before").foregroundStyle(SN.mut)
        }
    }
}

/// ₹41k / ₹4.9L, for the small calendar cells
private func shortRupees(_ n: Double) -> String {
    if n >= 100_000 { return String(format: "₹%.1fL", n / 100_000) }
    if n >= 1000 { return "₹\(Int((n / 1000).rounded()))k" }
    return "₹\(Int(n))"
}

private struct Kpi: View {
    let label: String
    let value: String
    let sub: AnyView
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelLabel(text: label)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            sub.font(.subheadline)
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).fill(SN.panel))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).stroke(SN.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct KeyValue: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(SN.mut)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

private struct DishesList: View {
    let dishes: [ReportOverview.Dish]
    var limit = 8
    var meters = true
    var body: some View {
        let top = max(1, dishes.map(\.takings).max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            if dishes.isEmpty { Text("Nothing sold.").font(.subheadline).foregroundStyle(SN.mut) }
            ForEach(Array(dishes.prefix(limit))) { d in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(d.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Fmt.qty(d.quantity)) · \(d.takings.rupees)").font(.caption.monospaced()).foregroundStyle(SN.mut)
                    }
                    .font(.subheadline)
                    if meters {
                        GeometryReader { g in
                            Capsule().fill(SN.panel2)
                                .overlay(alignment: .leading) { Capsule().fill(SN.teal).frame(width: g.size.width * d.takings / top) }
                        }
                        .frame(height: 5)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct TendersList: View {
    let r: ReportOverview
    var extras = true
    var body: some View {
        let total = max(1, r.tenders.map(\.amount).reduce(0, +))
        VStack(alignment: .leading, spacing: 8) {
            if !r.tenders.isEmpty {
                GeometryReader { g in
                    let room = g.size.width - CGFloat(r.tenders.count - 1) * 2
                    HStack(spacing: 2) {
                        ForEach(r.tenders) { t in
                            let share: CGFloat = room * CGFloat(t.amount / total)
                            Rectangle().fill(Fmt.methodColor(t.method)).frame(width: max(2, share))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 9)
                .accessibilityHidden(true)
            } else {
                Text("No bills paid.").font(.subheadline).foregroundStyle(SN.mut)
            }
            ForEach(r.tenders) { t in
                HStack {
                    Circle().fill(Fmt.methodColor(t.method)).frame(width: 7, height: 7)
                    Text(Fmt.methodLabels[t.method] ?? t.method)
                    Spacer()
                    Text("\(Int((t.amount / total * 100).rounded()))%").monospacedDigit()
                    Text("· \(t.amount.rupees)").foregroundStyle(SN.mut).monospacedDigit()
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
            if extras {
                KeyValue(key: "Split bills", value: "\(r.splitBills)").padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codes used").foregroundStyle(SN.mut)
                    Text(r.codes.isEmpty ? "None" : r.codes.prefix(4).map { "\($0.code) ×\($0.uses)" }.joined(separator: " · "))
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct WaitersList: View {
    let waiters: [ReportOverview.Waiter]
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if waiters.isEmpty { Text("No bills.").font(.subheadline).foregroundStyle(SN.mut) }
            ForEach(Array(waiters.prefix(compact ? 4 : 6).enumerated()), id: \.element.id) { i, w in
                if i > 0 { Divider().overlay(SN.line) }
                HStack(alignment: .firstTextBaseline) {
                    Text(w.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(compact ? w.takings.rupees : "\(w.bills) bill\(w.bills == 1 ? "" : "s") · \(w.takings.rupees)")
                        .font(.caption.monospaced()).foregroundStyle(SN.mut)
                }
                .font(.subheadline)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct CABox: View {
    let ca: CAReportData
    let csv: URL?
    let pdf: URL?
    @State private var copied = false

    var body: some View {
        let month = String(format: "%04d-%02d", ca.year, ca.month)
        let soFar = month == String(ReportDate.today.prefix(7))
        let pct = { (k: String) in Int((ca.categories.first { $0.type == k }?.percentage ?? 0).rounded()) }
        VStack(alignment: .leading, spacing: 8) {
            Text("For the CA · \(ReportDate.monthName(month))\(soFar ? " so far" : "")")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy") {
                    copy(CAText.text(ca))
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .accessibilityIdentifier("ca-copy")
                if let csv { ShareLink("CSV", item: csv) }
                if let pdf { ShareLink("PDF", item: pdf) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(SN.teal)
            KeyValue(key: "Total sales", value: ca.totalSales.rupees)
            KeyValue(key: "Food \(pct("FOOD"))% · Alcohol \(pct("ALCOHOL"))% · Beverage \(pct("BEVERAGE"))%", value: "\(ca.totalBills) bills")
            KeyValue(key: "GST \((ca.totalGst ?? 0).rupees) · VAT \((ca.totalVat ?? 0).rupees)", value: "Goa month")
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).fill(SN.panel2))
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - A: any range

private struct RangeLayout: View {
    let r: ReportOverview
    let width: CGFloat
    let caCSV: URL?
    let caPDF: URL?

    var body: some View {
        let wide = width >= 820
        let f = r.figures, p = r.previous
        let kpis: [(String, String, AnyView)] = [
            ("Takings", f.takings.rupees, AnyView(Change(now: f.takings, before: p.takings))),
            ("Bills", "\(f.bills)", AnyView(Change(now: Double(f.bills), before: Double(p.bills)))),
            ("Average bill", f.averageBill.rupees, AnyView(Change(now: f.averageBill, before: p.averageBill))),
            ("Discounts", f.discounts.rupees, AnyView(Text(f.takings > 0 ? String(format: "%.1f%% of sales", f.discounts / (f.takings + f.discounts) * 100) : "—").foregroundStyle(SN.mut))),
            ("Cancelled", "\(f.cancelledDishes) dish\(f.cancelledDishes == 1 ? "" : "es")", AnyView(Text(f.cancelledValue.rupees).foregroundStyle(SN.mut))),
        ]
        VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            if wide {
                HStack(spacing: DesignTokens.spacingM) { ForEach(kpis, id: \.0) { Kpi(label: $0.0, value: $0.1, sub: $0.2) } }
            } else {
                Kpi(label: kpis[0].0, value: kpis[0].1, sub: kpis[0].2)
                Grid(horizontalSpacing: DesignTokens.spacingM, verticalSpacing: DesignTokens.spacingM) {
                    GridRow { Kpi(label: kpis[1].0, value: kpis[1].1, sub: kpis[1].2); Kpi(label: kpis[2].0, value: kpis[2].1, sub: kpis[2].2) }
                    GridRow { Kpi(label: kpis[3].0, value: kpis[3].1, sub: kpis[3].2); Kpi(label: kpis[4].0, value: kpis[4].1, sub: kpis[4].2) }
                }
            }

            let daysPanel = Panel(title: "\(r.days.count > 62 ? "Each week" : "Each day") · teal this period, grey the one before") { DayBars(days: r.days, previous: r.previousDays) }
            let heatPanel = Panel(title: "Busiest times · bills by weekday and hour") { HeatGrid(heat: r.heat, days: r.days) }
            if r.days.count > 1 {
                if width >= 1000 {
                    HStack(alignment: .top, spacing: DesignTokens.spacingL) { daysPanel.frame(width: (width - DesignTokens.spacingL) * 0.58); heatPanel }
                        .fixedSize(horizontal: false, vertical: true)
                } else { daysPanel; heatPanel }
            } else { heatPanel }

            let dishes = Panel(title: "What sells") { DishesList(dishes: r.dishes) }
            let pay = Panel(title: "How they pay") { TendersList(r: r) }
            let last = VStack(spacing: DesignTokens.spacingL) {
                if let w = r.waiters { Panel(title: "Who served") { WaitersList(waiters: w) } }
                CABox(ca: r.ca, csv: caCSV, pdf: caPDF)
            }
            if wide {
                HStack(alignment: .top, spacing: DesignTokens.spacingL) { dishes; pay; last }
            } else { dishes; pay; last }
        }
    }
}

/// A bar a day up to two months; beyond that a bar a week, so a long range still fits
private struct Bar: Identifiable {
    let id: String
    let takings: Double
    let before: Double?
    let label: String
    let spoken: String

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func of(_ days: [ReportOverview.Day], previous: [Double]) -> [Bar] {
        guard days.count > 62 else {
            return days.enumerated().map { i, d in
                // Every day labelled up to a fortnight; beyond that, Mondays only
                let show = days.count <= 14 || ReportDate.weekdayIndex(d.date) == 0
                return Bar(id: d.date, takings: d.takings, before: i < previous.count ? previous[i] : nil,
                           label: show ? (days.count <= 7 ? ReportDate.weekdayShort(d.date) : "\(ReportDate.dayOfMonth(d.date))") : "",
                           spoken: "\(ReportDate.label(d.date)): \(d.takings.rupees), \(d.bills) bills")
            }
        }
        return stride(from: 0, to: days.count, by: 7).map { i in
            let week = days[i..<min(i + 7, days.count)]
            let before = i < previous.count ? previous[i..<min(i + 7, previous.count)].reduce(0, +) : nil
            let first = week.first!.date
            let month = Int(first.dropFirst(5).prefix(2)) ?? 1
            // The month's name under its first week
            let newMonth = i == 0 || days[i - 7].date.prefix(7) != first.prefix(7)
            let takings = week.map(\.takings).reduce(0, +)
            return Bar(id: first, takings: takings, before: before, label: newMonth ? months[month - 1] : "",
                       spoken: "Week of \(ReportDate.label(first)): \(takings.rupees)")
        }
    }
}

private struct DayBars: View {
    let days: [ReportOverview.Day]
    let previous: [Double]
    var body: some View {
        let bars = Bar.of(days, previous: previous)
        let top = max(1, bars.map { max($0.takings, $0.before ?? 0) }.max() ?? 1)
        let gap: CGFloat = bars.count > 31 ? 1 : 3
        VStack(spacing: 6) {
            GeometryReader { g in
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(bars) { b in
                        ZStack(alignment: .bottomTrailing) {
                            if let before = b.before {
                                RoundedRectangle(cornerRadius: 2).fill(SN.line)
                                    .frame(height: g.size.height * before / top)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.trailing, bars.count > 31 ? 1 : 4)
                            }
                            RoundedRectangle(cornerRadius: 2).fill(SN.teal)
                                .frame(height: g.size.height * b.takings / top)
                                .padding(.leading, bars.count > 31 ? 1 : 4)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .accessibilityElement()
                        .accessibilityLabel(b.spoken)
                    }
                }
            }
            .frame(height: 150)
            // Labels overlay their bar without taking width, so they can't widen the row
            HStack(spacing: gap) {
                ForEach(bars) { b in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 12)
                        .overlay {
                            Text(b.label).font(.system(size: 9).monospaced()).foregroundStyle(SN.mut).fixedSize()
                        }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

private struct HeatGrid: View {
    let heat: ReportOverview.Heat
    let days: [ReportOverview.Day]
    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    var body: some View {
        let top = max(1, heat.cells.flatMap { $0 }.max() ?? 1)
        let covered = Set(days.map { ReportDate.weekdayIndex($0.date) })
        let step = heat.hours.count > 12 ? 3 : 1
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                // Hour labels overlay their column: a Grid makes its columns equal,
                // so a label's own width would set every column's minimum
                ForEach(Array(heat.hours.enumerated()), id: \.offset) { i, h in
                    Color.clear.frame(maxWidth: .infinity).frame(height: 11)
                        .overlay(alignment: .leading) {
                            if i % step == 0 {
                                Text("\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "a" : "p")")
                                    .font(.system(size: 9).monospaced()).foregroundStyle(SN.mut).fixedSize()
                            }
                        }
                }
            }
            ForEach(0..<7, id: \.self) { d in
                if covered.contains(d), d < heat.cells.count {
                    GridRow {
                        Text(Self.weekdays[d]).font(.system(size: 9).monospaced()).foregroundStyle(SN.mut).fixedSize().gridColumnAlignment(.leading)
                        ForEach(Array(heat.cells[d].enumerated()), id: \.offset) { _, n in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(n == 0 ? SN.panel2 : SN.teal.opacity(0.18 + 0.82 * Double(n) / Double(top)))
                                .frame(height: 18)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.weekdays[d]): \(heat.cells[d].reduce(0, +)) bills")
                }
            }
        }
    }
}

// MARK: - D: the month as a calendar

private struct MonthLayout: View {
    let r: ReportOverview
    let width: CGFloat
    @Binding var selected: String?
    @Binding var month: String?
    let caCSV: URL?
    let caPDF: URL?
    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let wide = width >= 820
        if wide {
            HStack(alignment: .top, spacing: DesignTokens.spacingL) {
                VStack(alignment: .leading, spacing: DesignTokens.spacingL) { header; calendar(full: width - 340 >= 640); strip(wide: true) }
                VStack(spacing: DesignTokens.spacingL) { side }.frame(width: 320)
            }
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) { header; calendar(full: width >= 640); side; strip(wide: false) }
        }
    }

    private var header: some View {
        let m = r.period.month
        let prev = ReportDate.shiftMonth(m, by: -1), next = ReportDate.shiftMonth(m, by: 1)
        return HStack {
            Text(r.period.label).font(.title3.weight(.semibold))
            Spacer()
            Button { month = prev } label: { Label(ReportDate.monthName(prev), systemImage: "chevron.left") }
            if next <= String(ReportDate.today.prefix(7)) {
                Button { month = next } label: { Label(ReportDate.monthName(next), systemImage: "chevron.right").labelStyle(TrailingIcon()) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(SN.ink)
    }

    private func calendar(full: Bool) -> some View {
        let m = r.period.month
        let lead = ReportDate.weekdayIndex("\(m)-01")
        let byDate = Dictionary(uniqueKeysWithValues: r.days.map { ($0.date, $0) })
        let top = max(1, r.days.map(\.takings).max() ?? 1)
        let current = selected ?? r.period.to
        let cols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        return LazyVGrid(columns: cols, spacing: 5) {
            // One ForEach with distinct ids: a lazy grid drops cells whose ids repeat
            ForEach(cells(month: m, lead: lead), id: \.self) { cell in
              if cell.hasPrefix("h:") {
                Text(String(cell.dropFirst(2)).uppercased()).font(.system(size: 9).monospaced()).foregroundStyle(SN.mut)
              } else if cell.hasPrefix("b:") {
                Color.clear.frame(height: 1)
              } else {
                let date = cell
                let n = ReportDate.dayOfMonth(date)
                let d = byDate[date]
                let shade = d.map { $0.takings > 0 ? 0.12 + 0.48 * $0.takings / top : 0 } ?? 0
                Button { selected = date } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(n)").font(.system(size: 10).monospaced()).foregroundStyle(SN.mut)
                        Spacer(minLength: 0)
                        if let d, d.takings > 0 {
                            Text(full ? d.takings.rupees : shortRupees(d.takings))
                                .font(.system(size: full ? 13 : 11, weight: .semibold)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, minHeight: full ? 64 : 48, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(d == nil ? Color.clear : shade > 0 ? SN.teal.opacity(shade) : SN.panel))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(date == current ? SN.teal : SN.line, style: StrokeStyle(lineWidth: date == current ? 2 : 1, dash: d == nil ? [3, 3] : []))
                    )
                    .opacity(d == nil ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .disabled(d == nil)
                .accessibilityLabel(d.map { "\(ReportDate.label(date)): \($0.takings.rupees), \($0.bills) bills" } ?? "\(ReportDate.label(date)): still to come")
                .accessibilityAddTraits(date == current ? .isSelected : [])
              }
            }
        }
    }

    /// Weekday headings, blanks before the 1st, then every date of the month
    private func cells(month m: String, lead: Int) -> [String] {
        Self.weekdays.map { "h:\($0)" } + (0..<lead).map { "b:\($0)" }
            + (1...ReportDate.daysInMonth(m)).map { String(format: "%@-%02d", m, $0) }
    }

    @ViewBuilder private var side: some View {
        let f = r.figures, p = r.previous
        let soFar = r.period.to == ReportDate.today
        Panel(title: "\(ReportDate.monthName(r.period.month))\(soFar ? " so far" : "") · \(r.days.count) day\(r.days.count == 1 ? "" : "s")") {
            Text(f.takings.rupees).font(.system(size: 34, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Group {
                if pctChange(f.takings, p.takings) != nil {
                    HStack(spacing: 4) { Change(now: f.takings, before: p.takings); Text("on \(r.period.prevLabel)").foregroundStyle(SN.mut) }
                } else {
                    Text("Nothing taken in \(r.period.prevLabel) to compare").foregroundStyle(SN.mut)
                }
            }
            .font(.subheadline)
            VStack(spacing: 6) {
                KeyValue(key: "Bills", value: "\(f.bills)")
                KeyValue(key: "Average bill", value: f.averageBill.rupees)
                KeyValue(key: "Best day", value: r.bestDay.map { "\(ReportDate.weekdayShort($0.date)) \(ReportDate.dayOfMonth($0.date)) · \($0.takings.rupees)" } ?? "—")
                KeyValue(key: "Discounts", value: f.discounts.rupees)
                KeyValue(key: "Cancelled", value: "\(f.cancelledDishes) · \(f.cancelledValue.rupees)")
            }
        }
        if let day = r.days.first(where: { $0.date == (selected ?? r.period.to) }) ?? r.days.last {
            Panel(title: ReportDate.label(day.date)) {
                VStack(spacing: 6) {
                    KeyValue(key: "Takings", value: day.takings.rupees)
                    KeyValue(key: "Bills", value: "\(day.bills)")
                    KeyValue(key: "Top dish", value: day.topDish ?? "—")
                }
            }
        }
        CABox(ca: r.ca, csv: caCSV, pdf: caPDF)
    }

    @ViewBuilder private func strip(wide: Bool) -> some View {
        let dishes = VStack(alignment: .leading, spacing: 10) { PanelLabel(text: "What sells"); DishesList(dishes: r.dishes, limit: 4, meters: false) }
        let pay = VStack(alignment: .leading, spacing: 10) { PanelLabel(text: "How they pay"); TendersList(r: r, extras: false) }
        let staff = r.waiters.map { w in VStack(alignment: .leading, spacing: 4) { PanelLabel(text: "Who served"); WaitersList(waiters: w, compact: true) } }
        Group {
            if wide {
                HStack(alignment: .top, spacing: DesignTokens.spacingL) { dishes; if let staff { staff }; pay }
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.spacingL) { dishes; if let staff { staff }; pay }
            }
        }
        .padding(DesignTokens.spacingL + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).fill(SN.panel))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).stroke(SN.line, lineWidth: 1))
    }
}

/// Today / 7 days / Month / Quarter / Pick…, as on the web. Segments share
/// the width by their labels (a system segmented control makes each one as
/// wide as "Quarter", which is wider than an iPhone)
private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}
