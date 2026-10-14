//
//  Reports.swift
//  Durigo
//
//  Server-driven Reports — mirrors the web's /reports page.
//  Fetches /api/reports?period=… for analytics that exactly match what the
//  website's analytics page renders (total revenue, orders, avg, top items,
//  category breakdown, payment methods, hour distribution, staff performance).
//

import SwiftUI

// MARK: - Models

enum ReportPeriod: String, CaseIterable, Identifiable {
    case last24h = "24h"
    case last7d = "7d"
    case last30d = "30d"
    case last90d = "90d"
    case last1y = "1y"
    case allTime = "all"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .last24h:  "Last 24 Hours"
        case .last7d:   "Last 7 Days"
        case .last30d:  "Last 30 Days"
        case .last90d:  "Last 90 Days"
        case .last1y:   "Last Year"
        case .allTime:  "All Time"
        }
    }
}

struct ReportData: Decodable {
    let period: String
    let startDate: String
    let totalRevenue: Double
    let totalOrders: Int
    let avgOrderValue: Double
    let topSellingItems: [TopItem]
    let categoryBreakdown: [Category]
    let hourlyDistribution: [Hour]
    let paymentMethods: [PaymentMethod]
    let staffPerformance: [Staff]

    struct TopItem: Decodable, Identifiable {
        let name: String
        let category: String
        let quantity: Int
        let orders: Int
        var id: String { "\(name)-\(category)" }
    }
    struct Category: Decodable, Identifiable {
        let category: String
        let orders: Int
        let itemsSold: Int
        let revenue: Double
        var id: String { category }
    }
    struct Hour: Decodable, Identifiable {
        let hour: Int
        let orders: Int
        var id: Int { hour }
    }
    struct PaymentMethod: Decodable, Identifiable {
        let method: String
        let count: Int
        let total: Double
        var id: String { method }
    }
    struct Staff: Decodable, Identifiable {
        let staffName: String
        let role: String
        let ordersHandled: Int
        let revenueGenerated: Double
        var id: String { staffName }
    }
}

// MARK: - Store

@MainActor
@Observable
final class ReportsStore {
    private let session: Session
    private let urlSession: URLSession
    private let baseURL: URL

    var data: ReportData?
    var isLoading = false
    var error: String?

    init(session: Session,
         baseURL: URL? = nil,
         urlSession: URLSession = NetworkHelper.shared.currentSession) {
        self.session = session
        self.baseURL = baseURL
            ?? URL(string: Config.shared.serverURL)
            ?? URL(string: "http://127.0.0.1:3000")!
        self.urlSession = urlSession
    }

    func load(period: ReportPeriod) async {
        guard let token = session.token else {
            error = "Not signed in"
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        let trimmed = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(trimmed)/api/reports")!
        components.queryItems = [URLQueryItem(name: "period", value: period.rawValue)]
        guard let url = components.url else {
            error = "Bad URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("auth-token=\(token)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 30

        do {
            let (responseData, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                error = "Bad response"
                return
            }
            if http.statusCode == 401 {
                session.signOut()
                error = "Session expired"
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                error = "HTTP \(http.statusCode)"
                return
            }
            data = try JSONDecoder().decode(ReportData.self, from: responseData)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - View

/// Routes inside the Reports navigation stack. Used by both the breakout
/// link cards and the `--start-report=` debug launch arg, which lets us
/// drive sim screenshots without UI automation.
enum ReportBreakout: String, Hashable, CaseIterable {
    case sales, performance, customers, staff, inventory, ca
}

struct Reports: View {
    @Environment(Session.self) private var session
    @State private var store: ReportsStore?
    @State private var period: ReportPeriod = .last7d
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                    periodPicker
                    breakoutLinks

                    if let store, store.isLoading && store.data == nil {
                        loadingState
                    } else if let data = store?.data {
                        keyMetrics(data: data)
                        if !data.topSellingItems.isEmpty {
                            topItemsSection(items: data.topSellingItems)
                        }
                        if !data.categoryBreakdown.isEmpty {
                            categorySection(categories: data.categoryBreakdown, total: data.totalRevenue)
                        }
                        if !data.paymentMethods.isEmpty {
                            paymentMethodSection(methods: data.paymentMethods)
                        }
                        if !data.staffPerformance.isEmpty {
                            staffSection(staff: data.staffPerformance)
                        }
                        if !data.hourlyDistribution.isEmpty {
                            hourlyDistributionSection(hours: data.hourlyDistribution)
                        }
                    } else if let err = store?.error {
                        errorState(err)
                    }
                }
                .padding(DesignTokens.spacingL)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Reports")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await store?.load(period: period)
            }
            .task {
                if store == nil {
                    store = ReportsStore(session: session)
                }
                await store?.load(period: period)
                applyDebugStartRouteIfPresent()
            }
            .onChange(of: period) { _, newPeriod in
                Task { await store?.load(period: newPeriod) }
            }
            .navigationDestination(for: ReportBreakout.self) { route in
                switch route {
                case .sales:       SalesReportView()
                case .performance: PerformanceReportView()
                case .customers:   CustomersReportView()
                case .staff:       StaffReportView()
                case .inventory:   InventoryReportView()
                case .ca:          CAReportView()
                }
            }
        }
        .lockWithBiometric()
    }

    /// Honor `--start-report=<name>` only on first task to avoid re-pushing
    /// the same view when the user navigates back. DEBUG-only.
    private func applyDebugStartRouteIfPresent() {
        #if DEBUG
        guard path.isEmpty else { return }
        for arg in CommandLine.arguments where arg.hasPrefix("--start-report=") {
            let value = String(arg.dropFirst("--start-report=".count))
            if let route = ReportBreakout(rawValue: value) { path.append(route) }
            return
        }
        #endif
    }

    // MARK: - Sections

    private var breakoutLinks: some View {
        VStack(spacing: DesignTokens.spacingM) {
            breakoutLinkRow(route: .ca,          title: "CA report (monthly)",  icon: "doc.text")
            breakoutLinkRow(route: .sales,       title: "Sales & comparison",   icon: "indianrupeesign.circle")
            breakoutLinkRow(route: .performance, title: "Performance & efficiency", icon: "speedometer")
            breakoutLinkRow(route: .customers,   title: "Customers",             icon: "person.2")
            breakoutLinkRow(route: .staff,       title: "Staff",                 icon: "person.crop.circle.badge.checkmark")
            breakoutLinkRow(route: .inventory,   title: "Inventory",             icon: "shippingbox")
        }
    }

    private func breakoutLinkRow(route: ReportBreakout, title: String, icon: String) -> some View {
        NavigationLink(value: route) {
            HStack {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(title).font(.system(.body, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .webCardBackground()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reports-link-\(route.rawValue)")
    }

    private var periodPicker: some View {
        Menu {
            ForEach(ReportPeriod.allCases) { p in
                Button {
                    period = p
                } label: {
                    if period == p {
                        Label(p.label, systemImage: "checkmark")
                    } else {
                        Text(p.label)
                    }
                }
            }
        } label: {
            HStack {
                Text(period.label)
                    .font(.system(.body, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .webCardBackground(cornerRadius: DesignTokens.cornerRadiusSmall)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading reports…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load reports")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                Task { await store?.load(period: period) }
            }
            .buttonStyle(.webPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func keyMetrics(data: ReportData) -> some View {
        VStack(spacing: DesignTokens.spacingM) {
            StatTile(
                title: "Total Revenue",
                value: data.totalRevenue.asCurrencyString() ?? "—",
                subtitle: nil,
                icon: "indianrupeesign"
            )
            HStack(spacing: DesignTokens.spacingM) {
                StatTile(
                    title: "Total Orders",
                    value: "\(data.totalOrders)",
                    subtitle: nil,
                    icon: "cart"
                )
                StatTile(
                    title: "Avg Order",
                    value: data.avgOrderValue.asCurrencyString() ?? "—",
                    subtitle: nil,
                    icon: "chart.line.uptrend.xyaxis"
                )
            }
        }
    }

    private func topItemsSection(items: [ReportData.TopItem]) -> some View {
        SectionCard(title: "Top Selling Items") {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: DesignTokens.spacingM) {
                        Text("\(index + 1)")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(.body, weight: .medium))
                            Text(item.category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(item.quantity)")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                            Text("sold")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    if index < items.count - 1 { Divider() }
                }
            }
        }
    }

    private func categorySection(categories: [ReportData.Category], total: Double) -> some View {
        SectionCard(title: "Category Performance") {
            VStack(spacing: DesignTokens.spacingM) {
                ForEach(categories) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(c.category)
                                .font(.system(.body, weight: .medium))
                            Spacer()
                            Text(c.revenue.asCurrencyString() ?? "—")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                        }
                        // Progress bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.accentColor)
                                    .frame(
                                        width: total > 0 ? geo.size.width * CGFloat(c.revenue / total) : 0,
                                        height: 6
                                    )
                            }
                        }
                        .frame(height: 6)
                        HStack {
                            Text("\(c.orders) orders")
                            Text("•").foregroundStyle(.tertiary)
                            Text("\(c.itemsSold) items")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func paymentMethodSection(methods: [ReportData.PaymentMethod]) -> some View {
        SectionCard(title: "Payment Methods") {
            VStack(spacing: 0) {
                ForEach(Array(methods.enumerated()), id: \.element.id) { index, m in
                    HStack(spacing: DesignTokens.spacingM) {
                        StatusChip(label: humanMethod(m.method), color: methodColor(m.method))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(m.total.asCurrencyString() ?? "—")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                            Text("\(m.count) transaction\(m.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    if index < methods.count - 1 { Divider() }
                }
            }
        }
    }

    private func humanMethod(_ raw: String) -> String {
        switch raw {
        case "CASH": "Cash"
        case "CARD": "Card"
        case "UPI": "UPI"
        case "WALLET": "Wallet"
        case "BANK_TRANSFER": "Bank Transfer"
        default: raw.capitalized
        }
    }

    private func methodColor(_ raw: String) -> Color {
        switch raw {
        case "CASH": Color(red: 0.2, green: 0.7, blue: 0.3)
        case "CARD": Color(red: 0.5, green: 0.4, blue: 0.9)
        case "UPI":  Color(red: 1.0, green: 0.6, blue: 0.2)
        default: .gray
        }
    }

    private func staffSection(staff: [ReportData.Staff]) -> some View {
        SectionCard(title: "Top Performing Staff") {
            VStack(spacing: 0) {
                ForEach(Array(staff.prefix(5).enumerated()), id: \.element.id) { index, s in
                    HStack(spacing: DesignTokens.spacingM) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.staffName)
                                .font(.system(.body, weight: .medium))
                            Text(s.role.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(s.revenueGenerated.asCurrencyString() ?? "—")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                            Text("\(s.ordersHandled) order\(s.ordersHandled == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    if index < min(staff.count, 5) - 1 { Divider() }
                }
            }
        }
    }

    private func hourlyDistributionSection(hours: [ReportData.Hour]) -> some View {
        let maxOrders = max(hours.map(\.orders).max() ?? 1, 1)
        return SectionCard(title: "Order Distribution by Hour") {
            VStack(spacing: 8) {
                ForEach(hours) { h in
                    HStack(spacing: DesignTokens.spacingM) {
                        Text(formatHour(h.hour))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 22)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.accentColor)
                                    .frame(
                                        width: max(28, geo.size.width * CGFloat(h.orders) / CGFloat(maxOrders)),
                                        height: 22
                                    )
                                    .overlay(alignment: .trailing) {
                                        Text("\(h.orders)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.white)
                                            .padding(.trailing, 6)
                                    }
                            }
                        }
                        .frame(height: 22)
                    }
                }
            }
        }
    }

    private func formatHour(_ hour24: Int) -> String {
        let h12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let suffix = hour24 < 12 ? "AM" : "PM"
        return "\(h12) \(suffix)"
    }
}

// MARK: - Performance sub-page (kitchen / staff / table utilization)

struct PerformanceReportData: Decodable, Equatable {
    let avgOrderTime: Double         // minutes
    // Percentages 0..100. The server sends one decimal (26.6), so these are
    // Doubles; kitchen efficiency and satisfaction aren't tracked yet (0)
    let kitchenEfficiency: Double
    let customerSatisfaction: Double
    let staffProductivity: Double
    let tableUtilization: Double
    let orderAccuracy: Double
    let staffPerformance: [StaffStat]
    let busyHours: [BusyHour]
    let alerts: [PerformanceAlert]

    struct StaffStat: Decodable, Equatable, Identifiable {
        let name: String
        let role: String
        let ordersHandled: Int
        let revenue: Double
        var id: String { "\(name)-\(role)" }

        // Older servers didn't send revenue
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            role = try c.decode(String.self, forKey: .role)
            ordersHandled = try c.decode(Int.self, forKey: .ordersHandled)
            revenue = try c.decodeIfPresent(Double.self, forKey: .revenue) ?? 0
        }
        private enum CodingKeys: String, CodingKey { case name, role, ordersHandled, revenue }
    }

    struct BusyHour: Decodable, Equatable, Identifiable {
        let hour: Int
        let orders: Int
        var id: Int { hour }
    }

    struct PerformanceAlert: Decodable, Equatable, Identifiable {
        let type: String         // warning / info / critical
        let title: String
        let message: String
        var id: String { "\(type)-\(title)" }
    }
}

@MainActor @Observable final class PerformanceReportStore {
    private let api: APIClient
    var data: PerformanceReportData?
    var isLoading = false
    var error: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load(range: String) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let bytes = try await api.get("/api/admin/reports/performance",
                                          query: [URLQueryItem(name: "range", value: range)])
            data = try JSONDecoder().decode(PerformanceReportData.self, from: bytes)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct PerformanceReportView: View {
    @Environment(Session.self) private var session
    @State private var store: PerformanceReportStore?
    @State private var range: String = "7d"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                rangePicker
                if let store, store.isLoading && store.data == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, DesignTokens.spacing2XL)
                } else if let d = store?.data {
                    metricGrid(d)
                    if !d.alerts.isEmpty { alertsSection(d.alerts) }
                    if !d.staffPerformance.isEmpty { staffSection(d.staffPerformance) }
                    if !d.busyHours.isEmpty { busySection(d.busyHours) }
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Performance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if store == nil { store = PerformanceReportStore(session: session) }
            await store?.load(range: range)
        }
        .onChange(of: range) { _, newRange in Task { await store?.load(range: newRange) } }
        .refreshable { await store?.load(range: range) }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            Text("Today").tag("today")
            Text("7d").tag("7d")
            Text("30d").tag("30d")
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func metricGrid(_ d: PerformanceReportData) -> some View {
        let columns = [GridItem(.flexible(), spacing: DesignTokens.spacingM),
                       GridItem(.flexible(), spacing: DesignTokens.spacingM)]
        LazyVGrid(columns: columns, spacing: DesignTokens.spacingM) {
            StatTile(title: "Avg order time", value: String(format: "%.1f min", d.avgOrderTime), subtitle: "ticket → served", icon: "timer")
            // As on the web; kitchen efficiency and satisfaction are left out
            // until something measures them (the server sends 0)
            StatTile(title: "Table utilization", value: percent(d.tableUtilization), subtitle: "tables occupied now", icon: "square.grid.3x3")
            StatTile(title: "Orders kept", value: percent(d.orderAccuracy), subtitle: "not cancelled", icon: "checkmark.seal")
            StatTile(title: "Staff productivity", value: percent(d.staffProductivity), subtitle: "of an 8-hour shift's orders", icon: "person.2")
        }
    }

    /// 26.6 → "26.6%", 50 → "50%"
    private func percent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    private func alertsSection(_ alerts: [PerformanceReportData.PerformanceAlert]) -> some View {
        SectionCard(title: "Alerts") {
            VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
                ForEach(alerts) { a in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: alertIcon(a.type))
                            .foregroundStyle(alertColor(a.type))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.subheadline.weight(.semibold))
                            Text(a.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func staffSection(_ staff: [PerformanceReportData.StaffStat]) -> some View {
        SectionCard(title: "Staff performance") {
            VStack(spacing: 0) {
                ForEach(Array(staff.enumerated()), id: \.element.id) { idx, s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.medium))
                            Text(s.role.lowercased()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(s.ordersHandled) orders").font(.caption)
                            Text("\((Int(s.revenue)).rupees)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    if idx < staff.count - 1 { Divider() }
                }
            }
        }
    }

    private func busySection(_ hours: [PerformanceReportData.BusyHour]) -> some View {
        let max = Double(hours.map(\.orders).max() ?? 1)
        return SectionCard(title: "Busy hours") {
            VStack(spacing: DesignTokens.spacingS) {
                ForEach(hours) { h in
                    HStack {
                        Text(formatHour(h.hour)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: geo.size.width * (Double(h.orders) / max))
                        }
                        .frame(height: 8)
                        Text("\(h.orders)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
            .padding(DesignTokens.spacingM)
            .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
    }

    private func alertIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "critical": "exclamationmark.octagon.fill"
        case "warning":  "exclamationmark.triangle.fill"
        default:         "info.circle.fill"
        }
    }
    private func alertColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "critical": .red
        case "warning":  .orange
        default:         .blue
        }
    }
    private func formatHour(_ h: Int) -> String {
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(h < 12 ? "AM" : "PM")"
    }
}

#Preview {
    Reports()
        .environment(Session())
}

// MARK: - Sales sub-page (period-over-period comparison)

struct SalesReportData: Decodable, Equatable {
    let todayRevenue: Double
    let todayOrders: Int
    let avgOrderValue: Double
    let totalCustomers: Int
    let revenueChange: Double      // percent vs previous period
    let ordersChange: Double       // percent vs previous period
    let topItems: [TopItem]
    let hourlyData: [HourBucket]
    let paymentMethods: [PaymentBucket]

    struct TopItem: Decodable, Equatable, Identifiable {
        let id: String?
        let name: String
        let revenue: Double
        let orders: Int
        var stableID: String { id ?? name }
    }

    struct HourBucket: Decodable, Equatable, Identifiable {
        let hour: Int
        let revenue: Double
        let orders: Int
        var id: Int { hour }
    }

    struct PaymentBucket: Decodable, Equatable, Identifiable {
        let method: String
        let amount: Double
        let count: Int
        var id: String { method }
    }
}

/// Range buckets accepted by `/api/admin/reports/sales`. Mirrors the web's
/// `<Select>` options on `/reports/sales`: today/yesterday/week/month/quarter.
/// Note this is *operational* (today vs yesterday) rather than analytical
/// (24h/7d/30d) — that's why the main Reports page and this sub-page use
/// different period enums.
enum SalesRange: String, CaseIterable, Identifiable {
    case today, yesterday, week, month, quarter

    var id: String { rawValue }
    var label: String {
        switch self {
        case .today:     "Today"
        case .yesterday: "Yesterday"
        case .week:      "This Week"
        case .month:     "This Month"
        case .quarter:   "This Quarter"
        }
    }
}

@MainActor @Observable final class SalesReportStore {
    private let api: APIClient
    var data: SalesReportData?
    var isLoading = false
    var error: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load(range: SalesRange) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let bytes = try await api.get("/api/admin/reports/sales",
                                          query: [URLQueryItem(name: "range", value: range.rawValue)])
            data = try JSONDecoder().decode(SalesReportData.self, from: bytes)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct SalesReportView: View {
    @Environment(Session.self) private var session
    @State private var store: SalesReportStore?
    @State private var range: SalesRange = .today

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                rangePicker
                if let store, store.isLoading && store.data == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, DesignTokens.spacing2XL)
                } else if let d = store?.data {
                    metricGrid(d)
                    if !d.topItems.isEmpty { topItemsSection(d.topItems) }
                    if !d.paymentMethods.isEmpty { paymentSection(d.paymentMethods) }
                    if !d.hourlyData.isEmpty { hourlySection(d.hourlyData) }
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sales")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if store == nil { store = SalesReportStore(session: session) }
            await store?.load(range: range)
        }
        .onChange(of: range) { _, newRange in Task { await store?.load(range: newRange) } }
        .refreshable { await store?.load(range: range) }
    }

    private var rangePicker: some View {
        Menu {
            ForEach(SalesRange.allCases) { r in
                Button {
                    range = r
                } label: {
                    if range == r {
                        Label(r.label, systemImage: "checkmark")
                    } else {
                        Text(r.label)
                    }
                }
            }
        } label: {
            HStack {
                Text(range.label).font(.system(.body, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .webCardBackground(cornerRadius: DesignTokens.cornerRadiusSmall)
        }
    }

    @ViewBuilder
    private func metricGrid(_ d: SalesReportData) -> some View {
        let columns = [GridItem(.flexible(), spacing: DesignTokens.spacingM),
                       GridItem(.flexible(), spacing: DesignTokens.spacingM)]
        LazyVGrid(columns: columns, spacing: DesignTokens.spacingM) {
            StatTile(
                title: "Revenue",
                value: "\((Int(d.todayRevenue)).rupees)",
                subtitle: "vs previous \(range.label.lowercased())",
                icon: "indianrupeesign",
                trend: trend(forChange: d.revenueChange)
            )
            StatTile(
                title: "Orders",
                value: "\(d.todayOrders)",
                subtitle: "vs previous \(range.label.lowercased())",
                icon: "doc.text",
                trend: trend(forChange: d.ordersChange)
            )
            StatTile(
                title: "Avg order",
                value: "\((Int(d.avgOrderValue)).rupees)",
                subtitle: "per ticket",
                icon: "cart"
            )
            StatTile(
                title: "Customers",
                value: "\(d.totalCustomers)",
                subtitle: "unique in period",
                icon: "person.2"
            )
        }
    }

    /// Map a percent change to a `StatTile.Trend`. Up for positive, down for
    /// negative, neutral for ~zero. The threshold avoids showing noisy
    /// arrows when the period change is essentially flat.
    private func trend(forChange change: Double) -> StatTile.Trend? {
        let formatted = String(format: "%+.1f%%", change)
        if change > 0.5 { return .up(formatted) }
        if change < -0.5 { return .down(formatted) }
        return .neutral("flat")
    }

    private func topItemsSection(_ items: [SalesReportData.TopItem]) -> some View {
        SectionCard(title: "Top items", subtitle: "by revenue") {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.stableID) { idx, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(idx + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text("\(item.orders) order\(item.orders == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\((Int(item.revenue)).rupees)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    .padding(.vertical, 6)
                    if idx < items.count - 1 { Divider() }
                }
            }
        }
    }

    private func paymentSection(_ methods: [SalesReportData.PaymentBucket]) -> some View {
        let total = max(1, methods.reduce(0) { $0 + $1.amount })
        return SectionCard(title: "Payment methods") {
            VStack(spacing: DesignTokens.spacingS) {
                ForEach(methods) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(displayName(forMethod: m.method)).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\((Int(m.amount)).rupees)").font(.subheadline.monospacedDigit())
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: geo.size.width * (m.amount / total))
                        }
                        .frame(height: 6)
                        Text("\(m.count) transaction\(m.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func hourlySection(_ hours: [SalesReportData.HourBucket]) -> some View {
        let max = Double(hours.map(\.orders).max() ?? 1)
        return SectionCard(title: "Hourly", subtitle: "orders by hour of day") {
            VStack(spacing: DesignTokens.spacingS) {
                ForEach(hours) { h in
                    HStack {
                        Text(formatHour(h.hour)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .leading)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: geo.size.width * (Double(h.orders) / max))
                        }
                        .frame(height: 8)
                        Text("\(h.orders)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
            .padding(DesignTokens.spacingM)
            .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
    }

    private func displayName(forMethod method: String) -> String {
        switch method.uppercased() {
        case "CASH":          "Cash"
        case "CARD":          "Card"
        case "UPI":           "UPI"
        case "WALLET":        "Wallet"
        case "BANK_TRANSFER": "Bank transfer"
        default:              method.capitalized
        }
    }

    private func formatHour(_ h: Int) -> String {
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(h < 12 ? "AM" : "PM")"
    }
}

#Preview {
    NavigationStack { SalesReportView() }
        .environment(Session())
}

// MARK: - Customers sub-page

struct CustomersReportData: Decodable, Equatable {
    let period: String
    let totalCustomers: Int
    let newCustomers: Int
    let returningCustomers: Int
    let avgCustomerValue: Int
    let retentionRate: Double
    let avgVisitDays: Int
    let topSpenders: [TopSpender]
    let frequencyDistribution: [FrequencyBucket]
    let orderTypePreferences: [OrderTypePreference]

    struct TopSpender: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let orders: Int
        let totalSpent: Int
        let avgOrder: Int
    }

    struct FrequencyBucket: Decodable, Equatable, Identifiable {
        let bucket: String
        let customerCount: Int
        var id: String { bucket }
    }

    struct OrderTypePreference: Decodable, Equatable, Identifiable {
        let type: String
        let uniqueCustomers: Int
        let totalOrders: Int
        let revenue: Int
        var id: String { type }
    }
}

/// Period buckets accepted by `/api/admin/reports/customers` and `/staff`.
/// Distinct from the main reports' `ReportPeriod` because the web's customer
/// analytics page uses a longer-window menu (no 24h, but adds 365d).
enum AnalyticsPeriod: String, CaseIterable, Identifiable {
    case last7d = "7d"
    case last30d = "30d"
    case last90d = "90d"
    case last1y = "365d"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .last7d:  "Last 7 Days"
        case .last30d: "Last 30 Days"
        case .last90d: "Last 90 Days"
        case .last1y:  "Last Year"
        }
    }
}

@MainActor @Observable final class CustomersReportStore {
    private let api: APIClient
    var data: CustomersReportData?
    var isLoading = false
    var error: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load(period: AnalyticsPeriod) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let bytes = try await api.get("/api/admin/reports/customers",
                                          query: [URLQueryItem(name: "period", value: period.rawValue)])
            data = try JSONDecoder().decode(CustomersReportData.self, from: bytes)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct CustomersReportView: View {
    @Environment(Session.self) private var session
    @State private var store: CustomersReportStore?
    @State private var period: AnalyticsPeriod = .last30d

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                AnalyticsPeriodPicker(period: $period)
                if let store, store.isLoading && store.data == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, DesignTokens.spacing2XL)
                } else if let d = store?.data {
                    metricGrid(d)
                    if d.topSpenders.isEmpty && d.totalCustomers == 0 {
                        emptyState(message: "No customer data yet. Bills uploaded from iOS don't yet associate customers — once you start linking customers in POS, this view will populate.")
                    }
                    if !d.topSpenders.isEmpty { topSpendersSection(d.topSpenders) }
                    if !d.frequencyDistribution.isEmpty { frequencySection(d.frequencyDistribution, total: d.totalCustomers) }
                    if !d.orderTypePreferences.isEmpty { orderTypeSection(d.orderTypePreferences) }
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Customers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if store == nil { store = CustomersReportStore(session: session) }
            await store?.load(period: period)
        }
        .onChange(of: period) { _, newPeriod in Task { await store?.load(period: newPeriod) } }
        .refreshable { await store?.load(period: period) }
    }

    @ViewBuilder
    private func metricGrid(_ d: CustomersReportData) -> some View {
        let columns = [GridItem(.flexible(), spacing: DesignTokens.spacingM),
                       GridItem(.flexible(), spacing: DesignTokens.spacingM)]
        LazyVGrid(columns: columns, spacing: DesignTokens.spacingM) {
            StatTile(title: "Total customers", value: "\(d.totalCustomers)",
                     subtitle: "\(d.newCustomers) new in period", icon: "person.2")
            StatTile(title: "Avg value", value: "\((d.avgCustomerValue).rupees)",
                     subtitle: "lifetime per customer", icon: "indianrupeesign.circle")
            StatTile(title: "Retention", value: String(format: "%.1f%%", d.retentionRate),
                     subtitle: "\(d.returningCustomers) returning", icon: "heart")
            StatTile(title: "Visit frequency", value: "\(d.avgVisitDays) days",
                     subtitle: "between visits", icon: "calendar")
        }
    }

    private func topSpendersSection(_ spenders: [CustomersReportData.TopSpender]) -> some View {
        SectionCard(title: "Top spenders") {
            VStack(spacing: 0) {
                ForEach(Array(spenders.enumerated()), id: \.element.id) { idx, c in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(idx + 1)").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.subheadline.weight(.medium))
                            Text("\(c.orders) order\(c.orders == 1 ? "" : "s") · avg \((c.avgOrder).rupees)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\((c.totalSpent).rupees)").font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    .padding(.vertical, 6)
                    if idx < spenders.count - 1 { Divider() }
                }
            }
        }
    }

    private func frequencySection(_ buckets: [CustomersReportData.FrequencyBucket], total: Int) -> some View {
        let safeTotal = max(1, total)
        return SectionCard(title: "Visit frequency", subtitle: "customers by visits in period") {
            VStack(spacing: DesignTokens.spacingS) {
                ForEach(buckets) { b in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(b.bucket).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(b.customerCount)").font(.subheadline.monospacedDigit())
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: geo.size.width * (Double(b.customerCount) / Double(safeTotal)))
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    private func orderTypeSection(_ prefs: [CustomersReportData.OrderTypePreference]) -> some View {
        SectionCard(title: "Order type preferences") {
            VStack(spacing: 0) {
                ForEach(Array(prefs.enumerated()), id: \.element.id) { idx, p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(formatOrderType(p.type)).font(.subheadline.weight(.medium))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(p.uniqueCustomers) customers").font(.caption)
                            Text("\((p.revenue).rupees)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    if idx < prefs.count - 1 { Divider() }
                }
            }
        }
    }

    private func formatOrderType(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func emptyState(message: String) -> some View {
        SectionCard {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.spacingM)
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
            .padding(DesignTokens.spacingM)
            .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
    }
}

// MARK: - Staff sub-page

struct StaffReportData: Decodable, Equatable {
    let period: String
    let activeStaffCount: Int
    let totalRevenue: Int
    let totalOrders: Int
    let avgRevenuePerStaff: Int
    let staffPerformance: [StaffMember]
    let roleStats: [RoleStat]
    let topPerformers: [TopPerformer]

    struct StaffMember: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let role: String
        let ordersHandled: Int
        let revenueGenerated: Int
        let avgOrder: Int
        let daysWorked: Int
        let lastOrder: String?
    }

    struct RoleStat: Decodable, Equatable, Identifiable {
        let role: String
        let staffCount: Int
        let totalOrders: Int
        let totalRevenue: Int
        let avgOrder: Int
        var id: String { role }
    }

    struct TopPerformer: Decodable, Equatable, Identifiable {
        let name: String
        let role: String
        let recentOrders: Int
        let recentRevenue: Int
        var id: String { "\(name)-\(role)" }
    }
}

@MainActor @Observable final class StaffReportStore {
    private let api: APIClient
    var data: StaffReportData?
    var isLoading = false
    var error: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load(period: AnalyticsPeriod) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let bytes = try await api.get("/api/admin/reports/staff",
                                          query: [URLQueryItem(name: "period", value: period.rawValue)])
            data = try JSONDecoder().decode(StaffReportData.self, from: bytes)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct StaffReportView: View {
    @Environment(Session.self) private var session
    @State private var store: StaffReportStore?
    @State private var period: AnalyticsPeriod = .last30d

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                AnalyticsPeriodPicker(period: $period)
                if let store, store.isLoading && store.data == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, DesignTokens.spacing2XL)
                } else if let d = store?.data {
                    metricGrid(d)
                    if !d.topPerformers.isEmpty { topPerformersSection(d.topPerformers) }
                    if !d.staffPerformance.isEmpty { staffSection(d.staffPerformance) }
                    if !d.roleStats.isEmpty { roleSection(d.roleStats) }
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Staff")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if store == nil { store = StaffReportStore(session: session) }
            await store?.load(period: period)
        }
        .onChange(of: period) { _, newPeriod in Task { await store?.load(period: newPeriod) } }
        .refreshable { await store?.load(period: period) }
    }

    @ViewBuilder
    private func metricGrid(_ d: StaffReportData) -> some View {
        let columns = [GridItem(.flexible(), spacing: DesignTokens.spacingM),
                       GridItem(.flexible(), spacing: DesignTokens.spacingM)]
        LazyVGrid(columns: columns, spacing: DesignTokens.spacingM) {
            StatTile(title: "Active staff", value: "\(d.activeStaffCount)",
                     subtitle: "currently rostered", icon: "person.2")
            StatTile(title: "Total revenue", value: "\((d.totalRevenue).rupees)",
                     subtitle: "in period", icon: "indianrupeesign.circle")
            StatTile(title: "Total orders", value: "\(d.totalOrders)",
                     subtitle: "handled by staff", icon: "doc.text")
            StatTile(title: "Avg per staff", value: "\((d.avgRevenuePerStaff).rupees)",
                     subtitle: "revenue per head", icon: "person.crop.circle")
        }
    }

    private func topPerformersSection(_ performers: [StaffReportData.TopPerformer]) -> some View {
        SectionCard(title: "Top performers", subtitle: "last 7 days") {
            VStack(spacing: 0) {
                ForEach(Array(performers.enumerated()), id: \.element.id) { idx, p in
                    HStack {
                        Text("\(idx + 1)").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.subheadline.weight(.medium))
                            Text(formatRole(p.role)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(p.recentOrders) orders").font(.caption)
                            Text("\((p.recentRevenue).rupees)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    if idx < performers.count - 1 { Divider() }
                }
            }
        }
    }

    private func staffSection(_ staff: [StaffReportData.StaffMember]) -> some View {
        SectionCard(title: "All staff", subtitle: "ranked by revenue in period") {
            VStack(spacing: 0) {
                ForEach(Array(staff.enumerated()), id: \.element.id) { idx, s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.medium))
                            Text("\(formatRole(s.role)) · \(s.daysWorked) day\(s.daysWorked == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(s.ordersHandled) orders").font(.caption)
                            Text("\((s.revenueGenerated).rupees)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    if idx < staff.count - 1 { Divider() }
                }
            }
        }
    }

    private func roleSection(_ roles: [StaffReportData.RoleStat]) -> some View {
        SectionCard(title: "By role") {
            VStack(spacing: 0) {
                ForEach(Array(roles.enumerated()), id: \.element.id) { idx, r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatRole(r.role)).font(.subheadline.weight(.medium))
                            Text("\(r.staffCount) staff · \(r.totalOrders) orders")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\((r.totalRevenue).rupees)").font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    .padding(.vertical, 6)
                    if idx < roles.count - 1 { Divider() }
                }
            }
        }
    }

    private func formatRole(_ raw: String) -> String { raw.capitalized }

    private func errorBanner(_ msg: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
            .padding(DesignTokens.spacingM)
            .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
    }
}

// MARK: - Inventory sub-page

struct InventoryReportData: Decodable, Equatable {
    let totalItems: Int
    let totalValue: Int
    let lowStockCount: Int
    let overstockedCount: Int
    let lowStockItems: [LowStockItem]
    let topConsumed: [ConsumedItem]
    let suppliers: [Supplier]

    struct LowStockItem: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let unit: String
        let currentStock: Double
        let minimumStock: Double
    }

    struct ConsumedItem: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let unit: String
        let totalConsumed: Double
        let timesUsed: Int
    }

    struct Supplier: Decodable, Equatable, Identifiable {
        let supplier: String
        let itemCount: Int
        let totalValue: Int
        var id: String { supplier }
    }
}

@MainActor @Observable final class InventoryReportStore {
    private let api: APIClient
    var data: InventoryReportData?
    var isLoading = false
    var error: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let bytes = try await api.get("/api/admin/reports/inventory")
            data = try JSONDecoder().decode(InventoryReportData.self, from: bytes)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct InventoryReportView: View {
    @Environment(Session.self) private var session
    @State private var store: InventoryReportStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let store, store.isLoading && store.data == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, DesignTokens.spacing2XL)
                } else if let d = store?.data {
                    metricGrid(d)
                    if !d.lowStockItems.isEmpty { lowStockSection(d.lowStockItems) }
                    if !d.topConsumed.isEmpty { consumedSection(d.topConsumed) }
                    if !d.suppliers.isEmpty { supplierSection(d.suppliers) }
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Inventory")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if store == nil { store = InventoryReportStore(session: session) }
            await store?.load()
        }
        .refreshable { await store?.load() }
    }

    @ViewBuilder
    private func metricGrid(_ d: InventoryReportData) -> some View {
        let columns = [GridItem(.flexible(), spacing: DesignTokens.spacingM),
                       GridItem(.flexible(), spacing: DesignTokens.spacingM)]
        LazyVGrid(columns: columns, spacing: DesignTokens.spacingM) {
            StatTile(title: "Stock value", value: "\((d.totalValue).rupees)",
                     subtitle: "\(d.totalItems) items", icon: "shippingbox")
            StatTile(title: "Low stock", value: "\(d.lowStockCount)",
                     subtitle: "need attention", icon: "exclamationmark.triangle",
                     trend: d.lowStockCount > 0 ? .down("alert") : nil)
            StatTile(title: "Overstocked", value: "\(d.overstockedCount)",
                     subtitle: "above max", icon: "arrow.up.bin")
            StatTile(title: "Total items", value: "\(d.totalItems)",
                     subtitle: "tracked SKUs", icon: "list.bullet")
        }
    }

    private func lowStockSection(_ items: [InventoryReportData.LowStockItem]) -> some View {
        SectionCard(title: "Low stock", subtitle: "below minimum threshold") {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text("min \(formatStock(item.minimumStock)) \(item.unit)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(formatStock(item.currentStock)) \(item.unit)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 6)
                    if idx < items.count - 1 { Divider() }
                }
            }
        }
    }

    private func consumedSection(_ items: [InventoryReportData.ConsumedItem]) -> some View {
        SectionCard(title: "Top consumed", subtitle: "last 30 days") {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        Text("\(idx + 1)").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text("used in \(item.timesUsed) order\(item.timesUsed == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(formatStock(item.totalConsumed)) \(item.unit)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    .padding(.vertical, 6)
                    if idx < items.count - 1 { Divider() }
                }
            }
        }
    }

    private func supplierSection(_ suppliers: [InventoryReportData.Supplier]) -> some View {
        SectionCard(title: "Suppliers") {
            VStack(spacing: 0) {
                ForEach(Array(suppliers.enumerated()), id: \.element.id) { idx, s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.supplier).font(.subheadline.weight(.medium))
                            Text("\(s.itemCount) item\(s.itemCount == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\((s.totalValue).rupees)").font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    .padding(.vertical, 6)
                    if idx < suppliers.count - 1 { Divider() }
                }
            }
        }
    }

    private func formatStock(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
            .padding(DesignTokens.spacingM)
            .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
    }
}

// MARK: - Shared period picker for analytics breakouts

private struct AnalyticsPeriodPicker: View {
    @Binding var period: AnalyticsPeriod

    var body: some View {
        Menu {
            ForEach(AnalyticsPeriod.allCases) { p in
                Button {
                    period = p
                } label: {
                    if period == p {
                        Label(p.label, systemImage: "checkmark")
                    } else {
                        Text(p.label)
                    }
                }
            }
        } label: {
            HStack {
                Text(period.label).font(.system(.body, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .webCardBackground(cornerRadius: DesignTokens.cornerRadiusSmall)
        }
    }
}

// MARK: - CA Report (monthly summary for Chartered Accountant)

/// Mirrors `app/lib/data/admin-reports/ca.ts` on the web. Categories sum to
/// totalSales because revenue uses pre-tax line-item subtotals.
struct CAReportData: Decodable, Equatable {
    let year: Int
    let month: Int
    let monthLabel: String
    let totalSales: Int
    let totalItems: Int
    let totalBills: Int
    /// GST (food, soft drinks) and VAT (liquor) included in totalSales.
    /// Optional so the screen still works against an older server.
    let totalGst: Int?
    let totalVat: Int?
    let categories: [CategoryRow]

    struct CategoryRow: Decodable, Equatable, Identifiable {
        let type: String   // FOOD | BEVERAGE | ALCOHOL
        let revenue: Int
        let percentage: Double
        var id: String { type }
    }
}

@MainActor @Observable final class CAReportStore {
    private let api: APIClient
    var data: CAReportData?
    var isLoading = false
    var error: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load(year: Int, month: Int) async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let bytes = try await api.get("/api/admin/reports/ca", query: [
                URLQueryItem(name: "year", value: String(year)),
                URLQueryItem(name: "month", value: String(month)),
            ])
            data = try JSONDecoder().decode(CAReportData.self, from: bytes)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct CAReportView: View {
    @Environment(Session.self) private var session
    @State private var store: CAReportStore?
    @State private var year: Int = Calendar.current.component(.year, from: Date())
    @State private var month: Int = Calendar.current.component(.month, from: Date())
    @State private var copied = false

    private static let inrLocale = Locale(identifier: "en_IN")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                MonthYearPicker(year: $year, month: $month)

                if let store, store.isLoading && store.data == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, DesignTokens.spacing2XL)
                } else if let d = store?.data {
                    if d.totalBills == 0 {
                        emptyMonth(label: d.monthLabel)
                    } else {
                        copyCard(d)
                        metricGrid(d)
                        breakdownSection(d)
                    }
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("CA Report")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if store == nil { store = CAReportStore(session: session) }
            await store?.load(year: year, month: month)
        }
        .onChange(of: year) { _, _ in Task { await store?.load(year: year, month: month) } }
        .onChange(of: month) { _, _ in Task { await store?.load(year: year, month: month) } }
        .refreshable { await store?.load(year: year, month: month) }
    }

    private func emptyMonth(label: String) -> some View {
        SectionCard(title: label) {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No completed bills in this month.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.spacingM)
        }
    }

    private func copyCard(_ d: CAReportData) -> some View {
        SectionCard(title: d.monthLabel, subtitle: "Completed payments only; sales include GST and VAT") {
            VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
                Text(buildCAText(d))
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: DesignTokens.spacingM) {
                    Button {
                        copyToPasteboard(buildCAText(d))
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy for CA",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.webPrimary)
                    .accessibilityIdentifier("ca-copy-button")

                    ShareLink(item: buildCAText(d)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.webSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func metricGrid(_ d: CAReportData) -> some View {
        let columns = [GridItem(.flexible(), spacing: DesignTokens.spacingM),
                       GridItem(.flexible(), spacing: DesignTokens.spacingM)]
        LazyVGrid(columns: columns, spacing: DesignTokens.spacingM) {
            StatTile(title: "Total Sales",
                     value: Double(d.totalSales).asCurrencyString(locale: Self.inrLocale) ?? "—",
                     subtitle: nil, icon: "indianrupeesign.circle")
            StatTile(title: "Total Bills", value: "\(d.totalBills)",
                     subtitle: nil, icon: "doc.text")
            StatTile(title: "Items Sold", value: "\(d.totalItems)",
                     subtitle: nil, icon: "cart")
            StatTile(title: "Avg Bill",
                     value: d.totalBills > 0
                        ? (Double(d.totalSales) / Double(d.totalBills)).asCurrencyString(locale: Self.inrLocale) ?? "—"
                        : "—",
                     subtitle: nil, icon: "chart.bar")
            if let gst = d.totalGst, let vat = d.totalVat {
                StatTile(title: "GST (food & soft drinks)",
                         value: Double(gst).asCurrencyString(locale: Self.inrLocale) ?? "—",
                         subtitle: nil, icon: "percent")
                StatTile(title: "VAT (liquor)",
                         value: Double(vat).asCurrencyString(locale: Self.inrLocale) ?? "—",
                         subtitle: nil, icon: "wineglass")
            }
        }
    }

    private func breakdownSection(_ d: CAReportData) -> some View {
        SectionCard(title: "Category breakdown") {
            VStack(spacing: DesignTokens.spacingM) {
                ForEach(d.categories) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(categoryLabel(row.type)).font(.system(.body, weight: .medium))
                            Spacer()
                            Text(Double(row.revenue).asCurrencyString(locale: Self.inrLocale) ?? "—")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                            Text(String(format: "(%.1f%%)", row.percentage))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(row.percentage / 100), height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    private func categoryLabel(_ type: String) -> String {
        switch type {
        case "FOOD": return "Food Sales"
        case "BEVERAGE": return "Beverage Sales"
        case "ALCOHOL": return "Alcohol Sales"
        default: return type.capitalized
        }
    }

    private func buildCAText(_ d: CAReportData) -> String {
        let totalStr = Double(d.totalSales).asCurrencyString(locale: Self.inrLocale) ?? "\((d.totalSales).rupees)"
        var lines: [String] = [
            d.monthLabel,
            "",
            "Total Sales: \(totalStr)",
            "Total Items Sold: \(d.totalItems)",
            "Total Bills: \(d.totalBills)",
        ]
        if let gst = d.totalGst, let vat = d.totalVat {
            lines.append("GST collected (food & soft drinks): \(Double(gst).asCurrencyString(locale: Self.inrLocale) ?? "\((gst).rupees)")")
            lines.append("VAT collected (liquor): \(Double(vat).asCurrencyString(locale: Self.inrLocale) ?? "\((vat).rupees)")")
        }
        lines += ["", "Category Breakdown:"]
        for row in d.categories {
            let revStr = Double(row.revenue).asCurrencyString(locale: Self.inrLocale) ?? "\((row.revenue).rupees)"
            let pctStr = String(format: "%.1f%%", row.percentage)
            lines.append("\(categoryLabel(row.type)): \(revStr) (\(pctStr))")
        }
        return lines.joined(separator: "\n")
    }

    private func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
            .padding(DesignTokens.spacingM)
            .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
    }
}

private struct MonthYearPicker: View {
    @Binding var year: Int
    @Binding var month: Int

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// One option per row in the menu. Hashable+Identifiable so SwiftUI's
    /// `ForEach` doesn't dedupe by year (the original bug — `id:\.year.description`
    /// collapsed all 12 months of each year into a single visible row).
    private struct Option: Hashable, Identifiable {
        let year: Int
        let month: Int
        var id: String { "\(year)-\(month)" }
    }

    private var options: [Option] {
        let cal = Calendar.current
        let now = Date()
        var result: [Option] = []
        for offset in 0..<36 {
            if let d = cal.date(byAdding: .month, value: -offset, to: now) {
                result.append(Option(
                    year: cal.component(.year, from: d),
                    month: cal.component(.month, from: d)
                ))
            }
        }
        return result
    }

    private static func label(year: Int, month: Int) -> String {
        "\(monthNames[max(0, min(11, month - 1))]) \(year)"
    }

    var body: some View {
        Menu {
            ForEach(options) { opt in
                Button {
                    year = opt.year
                    month = opt.month
                } label: {
                    let lbl = Self.label(year: opt.year, month: opt.month)
                    if opt.year == year && opt.month == month {
                        Label(lbl, systemImage: "checkmark")
                    } else {
                        Text(lbl)
                    }
                }
            }
        } label: {
            HStack {
                Text(Self.label(year: year, month: month))
                    .font(.system(.body, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .webCardBackground(cornerRadius: DesignTokens.cornerRadiusSmall)
        }
    }
}

#Preview("Customers") {
    NavigationStack { CustomersReportView() }.environment(Session())
}
#Preview("Staff") {
    NavigationStack { StaffReportView() }.environment(Session())
}
#Preview("Inventory") {
    NavigationStack { InventoryReportView() }.environment(Session())
}
#Preview("CA") {
    NavigationStack { CAReportView() }.environment(Session())
}
