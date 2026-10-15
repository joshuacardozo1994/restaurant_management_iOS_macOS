//
//  TablesGridView.swift
//  Durigo
//
//  The POS floor ("Floor + Counter"): compact table tiles grouped by
//  section, filter chips, and the selected table's bill beside the floor
//  (a side panel on iPad and Mac, a card at the bottom on iPhone). Adding
//  items opens TakeOrderView: inline beside the floor on a wide screen, as
//  a sheet on iPhone.
//

import SwiftUI

/// What the order screen is for: a table, or a takeaway / delivery
struct OrderTarget: Identifiable, Equatable {
    var tableId: String?
    var type: OrderType
    var id: String { (tableId ?? "counter") + "-" + type.rawValue }
}

enum FloorFilter: String, CaseIterable, Identifiable {
    case all = "All", seated = "Seated", billAsked = "Bill asked", free = "Free"
    var id: String { rawValue }

    func includes(_ table: POSTable) -> Bool {
        switch self {
        case .all: true
        case .seated: table.effectiveStatus == .occupied
        case .billAsked: table.effectiveStatus == .billRequested
        case .free: table.effectiveStatus == .available
        }
    }
}

struct TablesGridView: View {
    @Bindable var store: POSStore
    var onOpenBillGenerator: () -> Void = {}

    @State private var selectedTableId: String?
    @State private var filter: FloorFilter = .all
    /// The order screen: inline on a wide screen, a sheet on a narrow one
    @State private var ordering: OrderTarget?
    @State private var isWide = false
    /// Table whose order detail (with payment / bill request) is open.
    @State private var detailTableId: String?
    /// Table being reserved via the reservation dialog.
    @State private var reservingTable: POSTable?
    @State private var showMergeSheet = false
    @State private var showManageSheet = false
    /// iPhone: the bill card pulled up to show every line
    @State private var cardExpanded = false
    @State private var busy = false
    @State private var errorMessage: String?

    /// From this width the bill sits beside the floor
    static let wideWidth: CGFloat = 760
    static let panelWidth: CGFloat = 380

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideWidth
            Group {
                if wide, let target = ordering {
                    TakeOrderView(store: store, target: target, inline: true,
                                  onClose: { finishOrdering(selecting: $0) },
                                  onPay: { id in
                                      finishOrdering(selecting: id)
                                      detailTableId = id
                                  })
                } else if wide {
                    HStack(spacing: 0) {
                        floor(compact: false, fourAcross: false)
                        Rectangle().fill(SN.line).frame(width: 1)
                        sidePanel
                            .frame(width: Self.panelWidth)
                    }
                } else {
                    floor(compact: true, fourAcross: geo.size.width < 500)
                        .safeAreaInset(edge: .bottom, spacing: 0) { bottomCard }
                }
            }
            .onChange(of: wide, initial: true) { _, now in isWide = now }
        }
        .background(SN.page)
        .foregroundStyle(SN.ink)
        .sheet(item: Binding(
            get: { isWide ? nil : ordering },
            set: { ordering = $0 }
        )) { target in
            TakeOrderView(store: store, target: target, onClose: { finishOrdering(selecting: $0) })
        }
        .sheet(item: Binding(
            get: { detailTableId.map { DetailContext(tableId: $0) } },
            set: { ctx in detailTableId = ctx?.tableId }
        )) { ctx in
            OrderDetailView(store: store, tableId: ctx.tableId)
        }
        .sheet(item: $reservingTable) { table in
            ReservationDialogView(store: store, tableId: table.id, tableNumber: table.number)
        }
        .sheet(isPresented: $showMergeSheet) {
            TableMergeView(store: store)
        }
        .sheet(isPresented: $showManageSheet) {
            ManageTablesView(store: store)
        }
        .alert("Couldn't update the table", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func finishOrdering(selecting tableId: String?) {
        ordering = nil
        if let tableId { selectedTableId = tableId }
    }

    // MARK: Floor

    /// `compact`: the bill is a card at the bottom; `fourAcross`: a phone
    private func floor(compact: Bool, fourAcross: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(compact: compact)
                filterChips
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    VStack(alignment: .leading, spacing: 16) {
                        let sections = floorSections
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                PanelLabel(text: section.name).accessibilityAddTraits(.isHeader)
                                LazyVGrid(columns: columns(fourAcross: fourAcross), spacing: 8) {
                                    ForEach(section.tables) { table in
                                        tile(table, now: tl.date, compact: fourAcross)
                                    }
                                    if section.id == sections.last?.id {
                                        ParcelTile { ordering = OrderTarget(tableId: nil, type: .takeaway) }
                                    }
                                }
                            }
                        }
                    }
                }
                legend
                if !store.tableGroups.isEmpty { mergedGroups }
            }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await store.loadTables() }
    }

    private func columns(fourAcross: Bool) -> [GridItem] {
        fourAcross
            ? Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
            : [GridItem(.adaptive(minimum: 100), spacing: 8)]
    }

    private var seatedCount: Int { store.tables.filter(\.isSeated).count }
    private var openTotal: Double { store.tables.filter(\.isSeated).reduce(0) { $0 + $1.unpaidTotal } }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Floor")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                PanelLabel(text: "\(seatedCount) of \(store.tables.count) seated · \(openTotal.rupees) open")
            }
            Spacer(minLength: 8)
            HStack(spacing: compact ? 10 : 8) {
                LiveBadge(isLive: store.sseConnected)
                if !compact {
                    Button("Takeaway") { ordering = OrderTarget(tableId: nil, type: .takeaway) }
                        .buttonStyle(QuietButtonStyle())
                    Button("Delivery") { ordering = OrderTarget(tableId: nil, type: .delivery) }
                        .buttonStyle(QuietButtonStyle())
                }
                Menu {
                    Button {
                        ordering = OrderTarget(tableId: nil, type: .takeaway)
                    } label: {
                        Label("Takeaway Order", systemImage: "bag")
                    }
                    Button {
                        ordering = OrderTarget(tableId: nil, type: .delivery)
                    } label: {
                        Label("Delivery Order", systemImage: "bicycle")
                    }
                    Divider()
                    Button {
                        showMergeSheet = true
                    } label: {
                        Label("Merge Tables", systemImage: "rectangle.3.group")
                    }
                    Button {
                        showManageSheet = true
                    } label: {
                        Label("Manage Tables", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(SN.ink)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .accessibilityLabel("New order and tables")
                .accessibilityIdentifier("pos-new-menu")
                Button(action: onOpenBillGenerator) {
                    Image(systemName: "doc.text")
                        .font(.title3)
                        .foregroundStyle(SN.mut)
                        .frame(minWidth: 32, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Bill Generator")
                .accessibilityLabel("Bill Generator")
                .accessibilityIdentifier("pos-bill-generator")
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FloorFilter.allCases) { f in
                    let count = f == .all ? nil : store.tables.filter(f.includes).count
                    let on = filter == f
                    Button {
                        filter = f
                    } label: {
                        HStack(spacing: 6) {
                            Text(f.rawValue)
                            if let count {
                                Text("\(count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(on ? SN.page.opacity(0.8) : SN.mut)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? SN.ink : SN.panel))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(on ? SN.ink : SN.line, lineWidth: 1))
                        .foregroundStyle(on ? SN.page : SN.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("floor-filter-\(f.rawValue)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: Sections and tiles

    private struct FloorSection: Identifiable {
        let name: String
        let tables: [POSTable]
        var id: String { name }
    }

    /// Tables in their sections (in table-number order), after the filter
    private var floorSections: [FloorSection] {
        let shown = store.tables.filter(filter.includes)
        var order: [String] = []
        var bySection: [String: [POSTable]] = [:]
        for t in shown.sorted(by: { $0.number < $1.number }) {
            let name = t.section?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Tables"
            if bySection[name] == nil { order.append(name) }
            bySection[name, default: []].append(t)
        }
        if order.isEmpty { return [FloorSection(name: "Tables", tables: [])] }
        return order.map { FloorSection(name: $0, tables: bySection[$0] ?? []) }
    }

    private func groupContaining(_ table: POSTable) -> POSTableGroup? {
        store.tableGroups.first { $0.members.contains { $0.tableId == table.id } }
    }

    /// The "lowest-numbered" member of a group acts as the orderable
    /// primary. Convention-based (low number = primary) so a manager
    /// merging tables doesn't have to think about it.
    private func primaryTable(for group: POSTableGroup?) -> POSTable? {
        guard let group else { return nil }
        let members = store.tables.filter { t in group.members.contains { $0.tableId == t.id } }
        return members.min(by: { $0.number < $1.number })
    }

    /// The table whose bill a tap on `table` shows: its group's primary,
    /// unless it has unpaid orders of its own
    private func billTable(for table: POSTable) -> POSTable {
        if !table.liveOrders.isEmpty { return table }
        return primaryTable(for: groupContaining(table)) ?? table
    }

    private var selectedTable: POSTable? {
        selectedTableId.flatMap { id in store.tables.first { $0.id == id } }
    }

    /// Selected tables: the tapped one and the rest of its merged group
    private var ringedIds: Set<String> {
        guard let t = selectedTable else { return [] }
        if let g = groupContaining(t) { return Set(g.members.map(\.tableId)) }
        return [t.id]
    }

    /// A reservation to show on a tile: when the table is reserved, or a
    /// free table is booked for later today
    private func tileReservation(_ table: POSTable) -> POSReservation? {
        guard let r = store.nextReservation(for: table.id) else { return nil }
        if table.effectiveStatus == .reserved || r.date.hasPrefix(POSTime.todayIST) { return r }
        return nil
    }

    private func tile(_ table: POSTable, now: Date, compact: Bool) -> some View {
        let group = groupContaining(table)
        let primary = primaryTable(for: group)
        let secondaryOf = (primary != nil && primary?.id != table.id && table.liveOrders.isEmpty) ? primary?.number : nil
        return FloorTableTile(
            table: table,
            isMerged: group != nil,
            primaryNumber: secondaryOf,
            reservation: tileReservation(table),
            isSelected: ringedIds.contains(table.id),
            compact: compact,
            now: now
        ) {
            if selectedTableId != table.id { cardExpanded = false }
            selectedTableId = table.id
        }
    }

    private var legend: some View {
        FlowLayout(spacing: 14, lineSpacing: 4) {
            ForEach(DishStage.allCases) { stage in
                HStack(spacing: 5) {
                    Circle().fill(stage.color).frame(width: 7, height: 7)
                    Text(stage.title.lowercased())
                }
            }
            Text("Tap a table for its bill")
        }
        .font(.caption)
        .foregroundStyle(SN.mut)
    }

    /// Every merged group, with Unmerge (also offered in Merge Tables)
    private var mergedGroups: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel(text: "Merged tables")
            ForEach(store.tableGroups) { group in
                HStack {
                    Image(systemName: "link").font(.caption).foregroundStyle(SN.mut)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.displayName).font(.subheadline.weight(.semibold))
                        Text("Tables \(group.members.map { String($0.table.number) }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.joined(separator: ", ")) · \(group.totalCapacity) seats")
                            .font(.caption).foregroundStyle(SN.mut)
                    }
                    Spacer()
                    Button("Unmerge") {
                        Task {
                            do { try await store.unmergeGroup(group.id) } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Unmerge \(group.displayName)")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SN.panel))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SN.line, lineWidth: 1))
            }
        }
    }

    // MARK: Bill beside the floor

    @ViewBuilder
    private var sidePanel: some View {
        if let tapped = selectedTable {
            billPanel(for: tapped, style: .side)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "hand.tap")
                    .font(.title2)
                Text("Tap a table to see its bill")
                    .font(.subheadline)
            }
            .foregroundStyle(SN.mut)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SN.panel)
        }
    }

    @ViewBuilder
    private var bottomCard: some View {
        if let tapped = selectedTable {
            billPanel(for: tapped, style: .card)
        }
    }

    private func billPanel(for tapped: POSTable, style: TableBillPanel.Style) -> some View {
        let table = billTable(for: tapped)
        let group = groupContaining(table)
        let others = group.map { g in g.members.map(\.table.number).filter { $0 != table.number }.sorted() } ?? []
        return TableBillPanel(
            store: store,
            table: table,
            mergedWith: others,
            reservation: store.nextReservation(for: table.id),
            style: style,
            expanded: $cardExpanded,
            busy: busy,
            onAddItems: { ordering = OrderTarget(tableId: table.id, type: .dineIn) },
            onRequestBill: { requestBill(table) },
            onPay: { detailTableId = table.id },
            onReserve: { reservingTable = table },
            onBackInService: { backInService(table) },
            onClose: { selectedTableId = nil; cardExpanded = false }
        )
    }

    private func requestBill(_ table: POSTable) {
        busy = true
        Task {
            defer { busy = false }
            do { try await store.requestBill(tableId: table.id) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func backInService(_ table: POSTable) {
        busy = true
        Task {
            defer { busy = false }
            do { try await store.updateTable(id: table.id, status: "AVAILABLE") } catch { errorMessage = error.localizedDescription }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// SwiftUI sheets bound by `item:` need an Identifiable wrapper.
private struct DetailContext: Identifiable {
    let tableId: String
    var id: String { tableId }
}

// MARK: - Tile

/// Fill and border for a table's state, shared by the floor tiles and the
/// table strip on the order screen
enum TileLook {
    static func fill(_ status: TableStatus) -> Color {
        switch status {
        case .occupied: SN.blue.opacity(0.12)
        case .billRequested: SN.amber.opacity(0.16)
        case .available, .reserved, .maintenance: SN.panel2
        }
    }

    static func stroke(_ status: TableStatus) -> Color {
        switch status {
        case .occupied: SN.blue.opacity(0.55)
        case .billRequested: SN.amber.opacity(0.7)
        case .reserved: SN.mut
        case .available, .maintenance: SN.line
        }
    }

    static func dash(_ status: TableStatus) -> [CGFloat] { status == .reserved ? [4, 3] : [] }
}

struct FloorTableTile: View {
    let table: POSTable
    let isMerged: Bool
    /// Set on a secondary member of a merged group: its bill is at this table
    let primaryNumber: Int?
    let reservation: POSReservation?
    let isSelected: Bool
    let compact: Bool
    let now: Date
    let action: () -> Void

    private var status: TableStatus { table.effectiveStatus }

    private var cornerNote: String? {
        if table.isSeated, let since = table.seatedSince { return POSTime.elapsed(since: since, now: now) }
        if let reservation, status == .reserved || status == .available { return POSTime.clock(reservation.time) }
        return nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: String(table.number))
                        .font(.subheadline.monospaced().weight(.semibold))
                        .foregroundStyle(status == .reserved || status == .maintenance ? SN.mut : SN.ink)
                    if isMerged {
                        Image(systemName: "link")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(SN.mut)
                    }
                    Spacer(minLength: 2)
                    if let cornerNote {
                        Text(cornerNote)
                            .font(.caption2.monospaced())
                            .foregroundStyle(SN.mut)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                detail
                Spacer(minLength: 0)
                if !table.dishStages.isEmpty {
                    DishProgress(stages: table.dishStages)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(shape.fill(TileLook.fill(status)))
            .overlay(shape.strokeBorder(TileLook.stroke(status), style: StrokeStyle(lineWidth: 1, dash: TileLook.dash(status))))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(SN.teal, lineWidth: 2)
                    .padding(-2)
                    .opacity(isSelected ? 1 : 0)
            )
            .opacity(status == .maintenance ? 0.6 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("table-tile-\(table.number)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        if let primaryNumber {
            Text("→ Table \(primaryNumber)")
                .font(.caption2)
                .foregroundStyle(SN.mut)
                .lineLimit(1)
        } else if table.isSeated {
            Text(table.unpaidTotal.rupees)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if !compact, let waiter = table.activeWaiterName {
                Text(waiter)
                    .font(.caption2)
                    .foregroundStyle(SN.mut)
                    .lineLimit(1)
            }
        } else if status == .maintenance {
            Text("Out of service").font(.caption2).foregroundStyle(SN.mut).lineLimit(1)
        } else if status == .reserved, let reservation {
            Text("\(reservation.guestName) ×\(reservation.guestCount)")
                .font(.caption2)
                .foregroundStyle(SN.mut)
                .lineLimit(1)
        } else if !compact || reservation == nil {
            Text("\(table.capacity) seats")
                .font(.caption2)
                .foregroundStyle(SN.mut)
                .lineLimit(1)
        }
    }

    private var accessibilityText: String {
        var parts = ["Table \(table.number)"]
        switch status {
        case .occupied: parts.append("seated")
        case .billRequested: parts.append("bill asked")
        case .reserved: parts.append("reserved")
        case .maintenance: parts.append("out of service")
        case .available: parts.append("free")
        }
        if let primaryNumber { parts.append("merged, bill at table \(primaryNumber)") } else if isMerged { parts.append("merged") }
        if table.isSeated {
            if let since = table.seatedSince { parts.append("for \(POSTime.elapsed(since: since, now: now))") }
            parts.append(table.unpaidTotal.rupees)
            if let waiter = table.activeWaiterName { parts.append(waiter) }
            let stages = table.dishStages
            let counts = DishStage.allCases.compactMap { s -> String? in
                let n = stages.filter { $0 == s }.count
                return n == 0 ? nil : "\(n) \(s.title.lowercased())"
            }
            parts.append(contentsOf: counts)
        } else if let reservation {
            parts.append("booked \(POSTime.clock(reservation.time)) for \(reservation.guestName)")
        } else if status == .available {
            parts.append("\(table.capacity) seats")
        }
        return parts.joined(separator: ", ")
    }
}

/// A thin line, one segment per dish, coloured by where the dish is
struct DishProgress: View {
    let stages: [DishStage]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                Capsule().fill(stage.color).frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The last tile: a takeaway for someone at the counter
private struct ParcelTile: View {
    let action: () -> Void
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            VStack(spacing: 2) {
                Text("Parcel").font(.subheadline.weight(.semibold))
                Text("quick bill").font(.caption2).foregroundStyle(SN.mut)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(shape.fill(SN.panel.opacity(0.5)))
            .overlay(shape.strokeBorder(SN.mut.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Parcel, quick bill")
        .accessibilityIdentifier("parcel-tile")
    }
}

// MARK: - Shared bill pieces

extension DishStage {
    var color: Color {
        switch self {
        case .todo: SN.amber
        case .cooking: SN.blue
        case .ready: SN.teal
        case .served: SN.mut
        }
    }
}

/// "● 2× Fish Curry Rice · Half   ₹640", with extras and the note under it
struct POSBillLine: View {
    let color: Color
    let quantity: Int
    let name: String
    var variant: String? = nil
    var extras: String? = nil
    var note: String? = nil
    let amount: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(quantity)× \(name)\(variant.map { " · \($0)" } ?? "")")
                    .font(.subheadline)
                if let extras {
                    Text(extras).font(.caption).foregroundStyle(SN.mut)
                }
                if let note, !note.isEmpty {
                    Text(note).font(.caption).italic().foregroundStyle(SN.mut)
                }
            }
            Spacer(minLength: 8)
            Text(amount.rupees)
                .font(.subheadline)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

/// A table's dishes grouped To do / Cooking / Ready / Served
struct POSStageGroups: View {
    let items: [POSOrderItem]

    var body: some View {
        ForEach(DishStage.allCases) { stage in
            let lines = items.filter { DishStage(itemStatus: $0.status) == stage }
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    PanelLabel(text: stage.title).padding(.bottom, 2)
                    ForEach(lines) { item in
                        POSBillLine(color: stage.color, quantity: item.quantity, name: item.displayName,
                                    variant: item.displayVariant, extras: item.modifiers?.summary,
                                    note: item.notes, amount: item.unitPrice * Double(item.quantity))
                        Rectangle().fill(SN.line).frame(height: 1)
                    }
                }
            }
        }
    }
}

/// Food & soft drinks with GST, liquor with VAT, and the total, by BillMath
struct POSBillTotals: View {
    let gst: Int
    let vat: Int
    @EnvironmentObject private var menuLoader: MenuLoader

    private static func percent(_ rate: Double) -> String {
        let p = rate * 100
        return p == p.rounded() ? "\(Int(p))%" : String(format: "%.1f%%", p)
    }

    var body: some View {
        let config = menuLoader.billingConfig
        let amounts = BillMath.computeBill(gst: gst, vat: vat, discount: 0, config: config)
        VStack(spacing: 4) {
            if gst > 0 || vat == 0 {
                row("Food & soft drinks", gst)
                row("GST \(Self.percent(config.taxRate)) (CGST + SGST)", amounts.gstTax)
            }
            if vat > 0 {
                row("Liquor", vat)
                row("VAT \(Self.percent(config.liquorTaxRate)) on liquor", amounts.vatTax)
            }
            Rectangle().fill(SN.line).frame(height: 1).padding(.vertical, 4)
            HStack(alignment: .firstTextBaseline) {
                Text("Total").font(.title3.weight(.bold))
                Text(config.taxInclusive ? "tax included" : "with tax")
                    .font(.caption)
                    .foregroundStyle(SN.mut)
                Spacer()
                Text(amounts.total.rupees)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .accessibilityIdentifier("bill-total")
            }
        }
    }

    private func row(_ label: String, _ amount: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.rupees).monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(SN.mut)
    }
}

/// Buttons on the floor and the bill: prominent (filled), tinted, or quiet
struct POSActionStyle: ButtonStyle {
    enum Kind { case prominent, bill, plain }
    var kind: Kind = .plain
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .foregroundStyle(kind == .prominent ? SN.page : SN.ink)
            .background(shape.fill(fill))
            .overlay(shape.stroke(stroke, lineWidth: kind == .prominent ? 0 : 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(shape)
    }

    private var fill: Color {
        switch kind {
        case .prominent: SN.teal
        case .bill: SN.amber.opacity(0.16)
        case .plain: SN.panel
        }
    }

    private var stroke: Color {
        switch kind {
        case .prominent: .clear
        case .bill: SN.amber.opacity(0.7)
        case .plain: SN.line
        }
    }
}

/// A small bordered button for the header (Takeaway, Delivery, Unmerge)
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(SN.ink)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(shape.fill(SN.panel))
            .overlay(shape.stroke(SN.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
    }
}

// MARK: - The selected table's bill

struct TableBillPanel: View {
    enum Style { case side, card }

    @Bindable var store: POSStore
    let table: POSTable
    /// The other tables merged with this one
    let mergedWith: [Int]
    let reservation: POSReservation?
    let style: Style
    @Binding var expanded: Bool
    let busy: Bool
    let onAddItems: () -> Void
    let onRequestBill: () -> Void
    let onPay: () -> Void
    let onReserve: () -> Void
    let onBackInService: () -> Void
    let onClose: () -> Void

    private var status: TableStatus { table.effectiveStatus }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            switch style {
            case .side: side(now: tl.date)
            case .card: card(now: tl.date)
            }
        }
    }

    // MARK: Layouts

    private func side(now: Date) -> some View {
        VStack(spacing: 0) {
            heading(now: now)
                .padding(DesignTokens.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(SN.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    lines
                }
                .padding(DesignTokens.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(SN.line).frame(height: 1)
            VStack(spacing: 12) {
                if table.isSeated { totals }
                actions
            }
            .padding(DesignTokens.spacingL)
        }
        .background(SN.panel)
    }

    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(SN.line)
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                .accessibilityElement()
                .accessibilityLabel(expanded ? "Show less" : "Show the whole bill")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { withAnimation(.snappy) { expanded.toggle() } }
            HStack(alignment: .top) {
                heading(now: now)
                Spacer(minLength: 8)
                if table.isSeated {
                    Text(table.unpaidTotal.rupees)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SN.mut)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close the bill")
            }
            if expanded {
                // As tall as the lines need, scrolling past 380pt
                ViewThatFits(in: .vertical) {
                    expandedLines
                    ScrollView { expandedLines }
                }
                .frame(maxHeight: 380)
            } else {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(SN.mut)
                    .lineLimit(2)
            }
            actions
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.top, 8)
        .padding(.bottom, DesignTokens.spacingM)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
                .fill(SN.panel)
                .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous)
                .stroke(SN.line, lineWidth: 1)
                .ignoresSafeArea(edges: .bottom)
        )
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                withAnimation(.snappy) {
                    if value.translation.height < -40 { expanded = true }
                    else if value.translation.height > 40 { if expanded { expanded = false } else { onClose() } }
                }
            }
        )
    }

    // MARK: Pieces

    private var expandedLines: some View {
        VStack(alignment: .leading, spacing: 14) {
            lines
            if table.isSeated { totals }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelLabel(text: headline(now: now))
                .lineLimit(2)
            Text("Table \(table.number)")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func headline(now: Date) -> String {
        var parts: [String] = []
        switch status {
        case .occupied, .billRequested:
            let since = table.seatedSince.map { POSTime.elapsed(since: $0, now: now) }
            parts.append(status == .billRequested ? "Bill asked" + (since.map { " \($0)" } ?? "") : "Seated" + (since.map { " \($0)" } ?? ""))
            if let waiter = table.activeWaiterName { parts.append(waiter) }
            parts.append("\(table.capacity) seats")
            let n = table.liveOrders.count
            parts.append("\(n) order\(n == 1 ? "" : "s")")
        case .available: parts += ["Free", "\(table.capacity) seats"]
        case .reserved: parts += ["Reserved", "\(table.capacity) seats"]
        case .maintenance: parts.append("Out of service")
        }
        if !mergedWith.isEmpty { parts.append("with \(mergedWith.map(String.init).joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    /// "1 to do · 1 cooking · 5 served", or the booking / seats for a free table
    private var summary: String {
        if table.isSeated {
            let stages = table.dishStages
            return DishStage.allCases.compactMap { s -> String? in
                let n = stages.filter { $0 == s }.count
                return n == 0 ? nil : "\(n) \(s.title.lowercased())"
            }.joined(separator: " · ")
        }
        if let reservation { return bookingText(reservation) }
        return status == .maintenance ? "Not taking guests" : "Nothing ordered yet"
    }

    private func bookingText(_ r: POSReservation) -> String {
        let day = r.date.hasPrefix(POSTime.todayIST) ? "" : " on \(String(r.date.prefix(10)))"
        return "Booked \(POSTime.clock(r.time))\(day) · \(r.guestName) ×\(r.guestCount)"
    }

    @ViewBuilder
    private var lines: some View {
        if table.isSeated {
            POSStageGroups(items: table.liveItems)
            let notes = table.liveOrders.compactMap(\.notes).filter { !$0.isEmpty }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    PanelLabel(text: "Notes")
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                        Text(n).font(.caption).foregroundStyle(SN.mut)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let reservation {
                    Label(bookingText(reservation), systemImage: "calendar")
                        .font(.subheadline)
                }
                Text(status == .maintenance ? "This table is out of service." : "Nothing ordered yet.")
                    .font(.subheadline)
                    .foregroundStyle(SN.mut)
            }
        }
    }

    private var totals: some View {
        let gross = store.grossByTax(for: table)
        return POSBillTotals(gst: gross.gst, vat: gross.vat)
    }

    @ViewBuilder
    private var actions: some View {
        let n = table.number
        switch status {
        case .available:
            HStack(spacing: 8) {
                Button("Take order", action: onAddItems)
                    .buttonStyle(POSActionStyle(kind: .prominent))
                    .accessibilityIdentifier("take-order-\(n)")
                Button("Reserve", action: onReserve)
                    .buttonStyle(POSActionStyle())
                    .accessibilityLabel("Reserve table \(n)")
                    .accessibilityIdentifier("reserve-table-\(n)")
            }
        case .reserved:
            Button("Seat & take order", action: onAddItems)
                .buttonStyle(POSActionStyle(kind: .prominent))
                .accessibilityIdentifier("take-order-\(n)")
        case .occupied:
            HStack(spacing: 8) {
                Button("+ Items", action: onAddItems)
                    .buttonStyle(POSActionStyle())
                    .accessibilityIdentifier("add-items-\(n)")
                Button("Bill", action: onRequestBill)
                    .buttonStyle(POSActionStyle(kind: .bill))
                    .disabled(busy)
                    .accessibilityLabel("Ask for the bill")
                    .accessibilityIdentifier("request-bill-\(n)")
                Button("Pay", action: onPay)
                    .buttonStyle(POSActionStyle())
                    .accessibilityIdentifier("view-orders-\(n)")
            }
        case .billRequested:
            HStack(spacing: 8) {
                Button("+ Items", action: onAddItems)
                    .buttonStyle(POSActionStyle(fullWidth: false))
                    .accessibilityIdentifier("add-items-\(n)")
                Button("Pay", action: onPay)
                    .buttonStyle(POSActionStyle(kind: .prominent))
                    .accessibilityIdentifier("view-orders-\(n)")
            }
        case .maintenance:
            Button("Back in service", action: onBackInService)
                .buttonStyle(POSActionStyle())
                .disabled(busy)
                .accessibilityIdentifier("back-in-service-\(n)")
        }
    }
}

// MARK: - Manage tables

/// Add tables, renumber them, change seats, take one out of service, or
/// (admins) delete one. Mirrors the web's Manage mode on /pos.
struct ManageTablesView: View {
    @Bindable var store: POSStore
    @Environment(\.dismiss) private var dismiss
    @Environment(Session.self) private var session
    @State private var editing: POSTable?
    @State private var deleting: POSTable?
    @State private var errorMessage: String?
    @State private var busy = false

    private var isAdmin: Bool { session.user?.role.uppercased() == "ADMIN" }
    private var nextNumber: Int { (store.tables.map(\.number).max() ?? 0) + 1 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.tables) { table in
                        row(table)
                    }
                } footer: {
                    Text("A table with diners can't be taken out of service or deleted.")
                }
            }
            .navigationTitle("Manage Tables")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        run { try await store.addTable(number: nextNumber, capacity: 4) }
                    } label: {
                        Label("Add Table \(nextNumber)", systemImage: "plus")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("manage-add-table")
                }
            }
            .sheet(item: $editing) { table in
                EditTableSheet(table: table) { number, capacity in
                    run { try await store.updateTable(id: table.id, number: number, capacity: capacity) }
                }
            }
            .confirmationDialog("Delete Table \(deleting?.number ?? 0)?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let table = deleting { run { try await store.deleteTable(id: table.id) } }
                }
            } message: {
                Text("Past bills keep their table number.")
            }
            .alert("Couldn't update the table", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(_ table: POSTable) -> some View {
        let inUse = !table.liveOrders.isEmpty
        let outOfService = table.statusEnum == .maintenance
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Table \(table.number)").font(.body.weight(.semibold))
                Text("\(table.capacity) seats\(outOfService ? " • out of service" : inUse ? " • in use" : "")")
                    .font(.caption)
                    .foregroundStyle(outOfService ? .orange : .secondary)
            }
            Spacer()
            Menu {
                Button { editing = table } label: { Label("Edit number & seats", systemImage: "pencil") }
                if outOfService {
                    Button {
                        run { try await store.updateTable(id: table.id, status: "AVAILABLE") }
                    } label: { Label("Back in service", systemImage: "checkmark.circle") }
                } else {
                    Button {
                        run { try await store.updateTable(id: table.id, status: "MAINTENANCE") }
                    } label: { Label("Out of service", systemImage: "wrench.and.screwdriver") }
                    .disabled(inUse)
                }
                if isAdmin {
                    Button(role: .destructive) { deleting = table } label: { Label("Delete", systemImage: "trash") }
                        .disabled(inUse)
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityIdentifier("manage-table-\(table.number)")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct EditTableSheet: View {
    let table: POSTable
    let onSave: (_ number: Int, _ capacity: Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var number: Int
    @State private var capacity: Int

    init(table: POSTable, onSave: @escaping (Int, Int) -> Void) {
        self.table = table
        self.onSave = onSave
        _number = State(initialValue: table.number)
        _capacity = State(initialValue: table.capacity)
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper("Table number: \(number)", value: $number, in: 1...999)
                Stepper("Seats: \(capacity)", value: $capacity, in: 1...30)
            }
            .navigationTitle("Table \(table.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(number, capacity)
                        dismiss()
                    }
                    .disabled(number == table.number && capacity == table.capacity)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 200)
        #endif
    }
}
