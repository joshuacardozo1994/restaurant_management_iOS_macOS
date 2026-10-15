//
//  Stats.swift
//  Durigo
//
//  Stats screen — uses the shared DesignSystem to match the web's analytics style.
//  Data layer (loadStats + StatsData) is unchanged from the original.
//

import SwiftUI
import SwiftData

extension Stats {
    struct Container {
        let totalSalesAmounts: [String: Double]
        let totalQuantities: [String: Double]
        let sortedMenuItemsForSale: [String]
        let sortedMenuItemsForQuantity: [String]
    }

    struct StatsData {
        var totalBills: Int = 0
        var totalQuantity: Double = 0
        var totalSales: Double = 0
        var averageBillAmount: Double = 0
        var cashPayments: [BillHistoryItem] = []
        var cardPayments: [BillHistoryItem] = []
        var upiPayments: [BillHistoryItem] = []
        var salesInCash: Double = 0
        var salesInCard: Double = 0
        var salesInUPI: Double = 0
        var container: Container?
        var filteredItems: [BillHistoryItem] = []
    }
}

struct Stats: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isShowingStatsFilter = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var isLoading = true
    @State private var statsData = StatsData()

    // MARK: - Sections

    @ViewBuilder
    private func heroRevenue() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Total Sales")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(statsData.totalSales.asCurrencyString() ?? "₹0.00")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .accessibilityIdentifier("stats-total-sales")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.spacingL)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusLarge)
    }

    @ViewBuilder
    private func keyMetrics() -> some View {
        // Two side-by-side StatTiles
        HStack(spacing: DesignTokens.spacingM) {
            StatTile(
                title: "Bills",
                value: "\(statsData.totalBills)",
                subtitle: nil,
                icon: "doc.text"
            )
            StatTile(
                title: "Items Sold",
                value: String(format: "%.0f", statsData.totalQuantity),
                subtitle: nil,
                icon: "tag"
            )
        }

        StatTile(
            title: "Average Bill",
            value: statsData.averageBillAmount.asCurrencyString() ?? "₹0.00",
            subtitle: "across selected period",
            icon: "indianrupeesign"
        )
    }

    @ViewBuilder
    private func popularSection(container: Container) -> some View {
        SectionCard(title: "Popular", subtitle: "Best sellers in this period") {
            VStack(spacing: 0) {
                NavigationLink {
                    StatsPopularQuantities(statsContainer: container)
                } label: {
                    PopularRow(
                        title: container.sortedMenuItemsForQuantity.first ?? "—",
                        subtitle: "\(Int(container.totalQuantities[container.sortedMenuItemsForQuantity.first ?? ""] ?? 0)) sold",
                        kicker: "By quantity"
                    )
                }
                .buttonStyle(.plain)

                Divider().padding(.vertical, 4)

                NavigationLink {
                    StatsPopularSales(statsContainer: container)
                } label: {
                    PopularRow(
                        title: container.sortedMenuItemsForSale.first ?? "—",
                        subtitle: (container.totalSalesAmounts[container.sortedMenuItemsForSale.first ?? ""] ?? 0).asCurrencyString() ?? "—",
                        kicker: "By revenue"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func paymentDistributionSection() -> some View {
        SectionCard(title: "Payment Methods", subtitle: "How customers paid") {
            VStack(spacing: 0) {
                PaymentRow(
                    label: "Cash",
                    color: Color(red: 0.2, green: 0.7, blue: 0.3),
                    percentage: percentage(for: statsData.cashPayments.count),
                    count: statsData.cashPayments.count,
                    amount: statsData.salesInCash.asCurrencyString() ?? "—"
                )
                Divider().padding(.vertical, 4)
                PaymentRow(
                    label: "Card",
                    color: Color(red: 0.5, green: 0.4, blue: 0.9),
                    percentage: percentage(for: statsData.cardPayments.count),
                    count: statsData.cardPayments.count,
                    amount: statsData.salesInCard.asCurrencyString() ?? "—"
                )
                Divider().padding(.vertical, 4)
                PaymentRow(
                    label: "UPI",
                    color: Color(red: 1.0, green: 0.6, blue: 0.2),
                    percentage: percentage(for: statsData.upiPayments.count),
                    count: statsData.upiPayments.count,
                    amount: statsData.salesInUPI.asCurrencyString() ?? "—"
                )
            }
        }
    }

    private func percentage(for count: Int) -> Int {
        Int(Double(count) / Double(max(statsData.totalBills, 1)) * 100)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            // While loading, the same sections (with no figures yet) are placeholders
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                    heroRevenue()

                    keyMetrics()

                    if let container = statsData.container {
                        popularSection(container: container)
                    }

                    paymentDistributionSection()
                }
                .padding(DesignTokens.spacingL)
                .skeleton(isLoading)
            }
            .background(Color(.systemBackground))
            .task { await loadStats() }
            .onChange(of: startDate) { _, _ in Task { await loadStats() } }
            .onChange(of: endDate) { _, _ in Task { await loadStats() } }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isShowingStatsFilter.toggle() }) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        StatsChart(billHistoryItems: statsData.filteredItems)
                    } label: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                }
            }
            .sheet(isPresented: $isShowingStatsFilter) {
                StatsFilter(startDate: $startDate, endDate: $endDate)
            }
        }
        .lockWithBiometric()
    }

    // MARK: - Data loading (unchanged from original)

    private func loadStats() async {
        isLoading = true
        if SkeletonPreview.isActive { return }

        let descriptor = FetchDescriptor<BillHistoryItem>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )

        do {
            let items = try modelContext.fetch(descriptor)

            let filteredItems: [BillHistoryItem]
            if startDate <= endDate {
                filteredItems = items.filter { (startDate...endDate).contains($0.date) }
            } else {
                filteredItems = items
            }

            var data = StatsData()
            data.filteredItems = filteredItems
            data.totalBills = filteredItems.count
            data.totalQuantity = filteredItems.reduce(0.0) { partialResult, item in
                partialResult + item.items.reduce(0.0) { $0 + $1.quantity }
            }
            data.totalSales = filteredItems.reduce(0.0) { partialResult, item in
                partialResult + item.items.reduce(0.0) { $0 + ($1.quantity * $1.price) }
            }
            data.averageBillAmount = data.totalSales / max(Double(data.totalBills), 1.0)

            for item in filteredItems {
                let itemTotal = item.items.reduce(0.0) { $0 + ($1.quantity * $1.price) }
                switch item.paymentStatus {
                case .paidByCash:
                    data.cashPayments.append(item)
                    data.salesInCash += itemTotal
                case .paidByCard:
                    data.cardPayments.append(item)
                    data.salesInCard += itemTotal
                case .paidByUPI:
                    data.upiPayments.append(item)
                    data.salesInUPI += itemTotal
                case .pending:
                    break
                }
            }

            data.container = filteredItems.getStatsContainer()

            if let minDate = items.map({ $0.date }).min() {
                await MainActor.run {
                    if startDate > minDate {
                        startDate = minDate
                    }
                }
            }

            await MainActor.run {
                statsData = data
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

// MARK: - Reusable rows

private struct PopularRow: View {
    let title: String
    let subtitle: String
    let kicker: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(.body, weight: .medium))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
}

private struct PaymentRow: View {
    let label: String
    let color: Color
    let percentage: Int
    let count: Int
    let amount: String

    var body: some View {
        HStack(spacing: 12) {
            StatusChip(label: label, color: color)
            Text("\(percentage)% · \(count) bill\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(amount)
                .font(.system(.body, design: .rounded, weight: .semibold))
        }
        .padding(.vertical, 8)
    }
}

#Preview {
#if DEBUG
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: BillHistoryItem.self, configurations: config)
    PreviewData.billHistoryItems.forEach { container.mainContext.insert($0) }
#endif
    return Stats()
#if DEBUG
        .modelContainer(container)
#endif
}
