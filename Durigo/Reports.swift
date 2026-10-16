//
//  Reports.swift
//  Durigo
//
//  The owner's other reports, opened from the foot of the Reports screen
//  (ReportOverview.swift): customers, stock, and the CA report by month.
//

import SwiftUI
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
                // Loading: the report's own sections with sample figures, as placeholders
                let loading = store?.data == nil && (store?.isLoading ?? true)
                if let d = store?.data ?? (loading ? CustomersReportData.sample : nil) {
                    Group {
                        metricGrid(d)
                        if d.topSpenders.isEmpty && d.totalCustomers == 0 {
                            emptyState(message: "No customer data yet. Bills uploaded from iOS don't yet associate customers — once you start linking customers in POS, this view will populate.")
                        }
                        if !d.topSpenders.isEmpty { topSpendersSection(d.topSpenders) }
                        if !d.frequencyDistribution.isEmpty { frequencySection(d.frequencyDistribution, total: d.totalCustomers) }
                        if !d.orderTypePreferences.isEmpty { orderTypeSection(d.orderTypePreferences) }
                    }
                    .skeleton(loading)
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Customers")
        .toolbar { ToolbarItem(placement: .primaryAction) { AnalyticsPeriodPicker(period: $period) } }
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
            ContentUnavailableView("Nothing yet", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text(message))
        }
    }

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
                // Loading: the report's own sections with sample figures, as placeholders
                let loading = store?.data == nil && (store?.isLoading ?? true)
                if let d = store?.data ?? (loading ? InventoryReportData.sample : nil) {
                    Group {
                        metricGrid(d)
                        if !d.lowStockItems.isEmpty { lowStockSection(d.lowStockItems) }
                        if !d.topConsumed.isEmpty { consumedSection(d.topConsumed) }
                        if !d.suppliers.isEmpty { supplierSection(d.suppliers) }
                    }
                    .skeleton(loading)
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Stock")
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

/// The period, as a menu in the navigation bar
private struct AnalyticsPeriodPicker: View {
    @Binding var period: AnalyticsPeriod

    var body: some View {
        Picker("Period", selection: $period) {
            ForEach(AnalyticsPeriod.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
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

                // Loading: the report's own sections with sample figures, as placeholders
                let loading = store?.data == nil && (store?.isLoading ?? true)
                if let d = store?.data ?? (loading ? CAReportData.sample : nil) {
                    Group {
                        if d.totalBills == 0 {
                            emptyMonth(label: d.monthLabel)
                        } else {
                            copyCard(d)
                            metricGrid(d)
                            breakdownSection(d)
                        }
                    }
                    .skeleton(loading)
                } else if let err = store?.error {
                    errorBanner(err)
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("CA Report")
        .toolbar { ToolbarItem(placement: .primaryAction) { MonthYearPicker(year: $year, month: $month) } }
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
            ContentUnavailableView("No bills", systemImage: "doc.text.magnifyingglass",
                                   description: Text("No completed bills in this month."))
        }
    }

    private func copyCard(_ d: CAReportData) -> some View {
        SectionCard(title: d.monthLabel, subtitle: "Completed payments only; sales include GST and VAT") {
            VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
                Text(CAText.text(d))
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: DesignTokens.spacingM) {
                    Button {
                        copyToPasteboard(CAText.text(d))
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

                    ShareLink(item: CAText.text(d)) {
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
        Picker("Month", selection: Binding(
            get: { Option(year: year, month: month) },
            set: { year = $0.year; month = $0.month })) {
            ForEach(options) { Text(Self.label(year: $0.year, month: $0.month)).tag($0) }
        }
        .pickerStyle(.menu)
    }
}

#Preview("Customers") {
    NavigationStack { CustomersReportView() }.environment(Session())
}
#Preview("Inventory") {
    NavigationStack { InventoryReportView() }.environment(Session())
}
#Preview("CA") {
    NavigationStack { CAReportView() }.environment(Session())
}
