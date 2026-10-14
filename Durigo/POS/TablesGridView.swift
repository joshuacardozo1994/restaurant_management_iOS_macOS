//
//  TablesGridView.swift
//  Durigo
//
//  Mirrors the web's /pos page (RealtimeTablesGrid.tsx): adaptive grid of
//  table cards, status-coded background, capacity + unpaid total, list of
//  active orders, primary "Take Order" action that presents TakeOrderView.
//

import SwiftUI

struct TablesGridView: View {
    @Bindable var store: POSStore
    @State private var orderingTableId: String?
    @State private var orderingType: OrderType = .dineIn
    @State private var showTakeawaySheet = false
    @State private var showDeliverySheet = false
    /// Table whose order detail (with payment / bill request) is open.
    @State private var detailTableId: String?
    /// Table being reserved via the reservation dialog.
    @State private var reservingTable: POSTable?
    /// Toggles the merge-tables modal.
    @State private var showMergeSheet = false
    /// Toggles the add/edit tables sheet.
    @State private var showManageSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                header
                grid
                if !store.tableGroups.isEmpty {
                    activeGroupsSection
                }
                legend
            }
            .padding(DesignTokens.spacingL)
        }
        .refreshable { await store.loadTables() }
        .background(Color(.systemGroupedBackground))
        .sheet(item: Binding(
            get: { orderingTableId.map { OrderingContext(tableId: $0, type: .dineIn) } },
            set: { ctx in orderingTableId = ctx?.tableId }
        )) { ctx in
            TakeOrderView(
                store: store,
                tableId: ctx.tableId,
                table: store.tables.first(where: { $0.id == ctx.tableId }),
                orderType: .dineIn
            )
        }
        .sheet(isPresented: $showTakeawaySheet) {
            TakeOrderView(store: store, tableId: nil, table: nil, orderType: .takeaway)
        }
        .sheet(isPresented: $showDeliverySheet) {
            TakeOrderView(store: store, tableId: nil, table: nil, orderType: .delivery)
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tables")
                    .font(.system(.title2, weight: .bold))
                Text("\(store.tables.count) tables • \(occupiedCount) occupied")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: store.sseConnected ? "wifi" : "wifi.slash")
                    .font(.subheadline)
                    .foregroundStyle(store.sseConnected ? .green : .red)
                Menu {
                    Button {
                        showTakeawaySheet = true
                    } label: {
                        Label("Takeaway Order", systemImage: "bag")
                    }
                    Button {
                        showDeliverySheet = true
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
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
            }
        }
    }

    private var occupiedCount: Int {
        store.tables.filter { $0.effectiveStatus == .occupied || $0.effectiveStatus == .billRequested }.count
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: DesignTokens.spacingL)]
    }

    private var grid: some View {
        LazyVGrid(columns: gridColumns, spacing: DesignTokens.spacingL) {
            ForEach(store.tables) { table in
                let group = groupContaining(table)
                let primary = primaryTable(for: group)
                TableCardView(
                    table: table,
                    group: group,
                    primaryNumber: primary?.number,
                    isOrderable: group == nil || primary?.id == table.id,
                    upcomingReservation: store.nextReservation(for: table.id),
                    onTakeOrder: {
                        // If this card is a secondary member, route the
                        // order to the primary instead of refusing.
                        orderingTableId = primary?.id ?? table.id
                    },
                    onViewOrders: { detailTableId = primary?.id ?? table.id },
                    onReserve: { reservingTable = table },
                    onBackInService: {
                        Task { try? await store.updateTable(id: table.id, status: "AVAILABLE") }
                    }
                )
            }
        }
    }

    private func groupContaining(_ table: POSTable) -> POSTableGroup? {
        store.tableGroups.first { $0.members.contains { $0.tableId == table.id } }
    }

    /// The "lowest-numbered" member of a group acts as the orderable
    /// primary. Convention-based (low number = primary) so a manager
    /// merging tables doesn't have to think about it. Returns nil if no
    /// group or members can't be matched to known tables.
    private func primaryTable(for group: POSTableGroup?) -> POSTable? {
        guard let group else { return nil }
        let members = store.tables.filter { t in group.members.contains { $0.tableId == t.id } }
        return members.min(by: { $0.number < $1.number })
    }

    /// Summary list of every currently-active TableGroup (merged tables).
    /// Mirrors the web's "Active Table Groups" panel at the bottom of /pos.
    /// Each row shows the group name, member tables, total capacity, and
    /// an Unmerge action. Hidden when there are no groups.
    private var activeGroupsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(.subheadline))
                Text("Active Groups")
                    .font(.system(.subheadline, weight: .semibold))
                Text("\(store.tableGroups.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue.opacity(0.18)))
                    .foregroundStyle(.blue)
            }
            ForEach(store.tableGroups) { group in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.displayName)
                            .font(.system(.subheadline, weight: .semibold))
                        Text("\(group.totalCapacity) seats • \(group.members.count) tables")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        Task { try? await store.unmergeGroup(group.id) }
                    } label: {
                        Label("Unmerge", systemImage: "rectangle.split.3x1.slash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Unmerge \(group.displayName)")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium).fill(Color.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium).stroke(Color.blue.opacity(0.18), lineWidth: 1))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status Legend")
                .font(.system(.subheadline, weight: .semibold))
            HStack(spacing: 12) {
                legendDot(color: .green, label: "Available")
                legendDot(color: .red, label: "Occupied")
                legendDot(color: .yellow, label: "Reserved")
                legendDot(color: .purple, label: "Bill Req.")
                legendDot(color: .gray, label: "Maint.")
            }
            .font(.caption)
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Table card

struct TableCardView: View {
    let table: POSTable
    let group: POSTableGroup?
    /// Number of the lowest-numbered table in this card's group. Used to
    /// label secondary members ("Order at Table 2"). Nil when not grouped
    /// or when this card *is* the primary.
    let primaryNumber: Int?
    /// True if this card can independently take an order. False for
    /// secondary members of a merged group — those defer to the primary.
    let isOrderable: Bool
    let upcomingReservation: POSReservation?
    let onTakeOrder: () -> Void
    let onViewOrders: () -> Void
    let onReserve: () -> Void
    var onBackInService: () -> Void = {}

    /// Convenience: this card is a *secondary* group member (not the lowest).
    private var isSecondaryGroupMember: Bool {
        group != nil && !isOrderable
    }

    var body: some View {
        // Compact: spacingS between sections (was spacingM); empty
        // "No active orders" placeholder removed — the green Available
        // badge already conveys that state.
        VStack(alignment: .leading, spacing: 0) {
            // Merged-group banner — saturated colored band at the top of
            // every member card so two tables sharing a party are
            // immediately and unambiguously paired across the grid.
            // Color is hashed deterministically from the group id so
            // distinct groups always get distinct hues.
            if let group {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .bold))
                    Text(group.displayName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(group.totalCapacity) seats")
                        .font(.caption2)
                        .opacity(0.85)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(groupColor(group.id))
                .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Table \(table.number)")
                            .font(.system(.headline, weight: .bold))
                        // Capacity inlined with the title to save a row.
                        HStack(spacing: 2) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 9))
                            Text("\(table.capacity)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    // Active waiter — only when occupied (not relevant for empty cards).
                    if let waiter = table.activeWaiterName {
                        HStack(spacing: 3) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 9))
                            Text(waiter)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusBadge
            }

            // Upcoming reservation indicator — only on cards without
            // active orders, so it doesn't compete with the order list.
            if table.liveOrders.isEmpty, let r = upcomingReservation {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9))
                    Text("\(r.time) — \(r.guestName) (\(r.guestCount))")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.yellow)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow.opacity(0.12)))
            }

            if !table.liveOrders.isEmpty {
                ordersSection
                HStack {
                    Spacer()
                    Text("₹\(Int(table.unpaidTotal))")
                        .font(.system(.headline, weight: .bold))
                        .monospacedDigit()
                }
            }

            actionButton
            }
            .padding(DesignTokens.spacingM)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusLarge, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusLarge, style: .continuous)
                .stroke(group != nil ? groupColor(group!.id) : borderColor,
                        lineWidth: group != nil ? 2.5 : 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusLarge, style: .continuous))
        // Secondary group members get visually de-emphasized so the eye
        // settles on the primary that actually takes orders.
        .opacity(isSecondaryGroupMember ? 0.78 : 1.0)
    }

    /// Deterministic color from a group id so all members of the same
    /// merge get the same saturated hue, but different groups get
    /// distinct colors. Hash mod 6 against a hand-picked palette that
    /// reads well over the existing card backgrounds.
    private func groupColor(_ id: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.13, green: 0.46, blue: 0.95), // blue
            Color(red: 0.85, green: 0.30, blue: 0.65), // pink
            Color(red: 0.55, green: 0.30, blue: 0.85), // purple
            Color(red: 0.95, green: 0.55, blue: 0.15), // orange
            Color(red: 0.10, green: 0.65, blue: 0.55), // teal
            Color(red: 0.70, green: 0.20, blue: 0.30), // crimson
        ]
        var sum = 0
        for c in id.unicodeScalars { sum &+= Int(c.value) }
        return palette[abs(sum) % palette.count]
    }

    private var ordersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active (\(table.liveOrders.count))")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(table.liveOrders.prefix(3)) { order in
                HStack {
                    Text("#\(order.orderNumber?.suffix(4).map(String.init).joined() ?? String(order.id.suffix(4)))")
                        .font(.caption)
                        .monospaced()
                    statusChip(for: order.status)
                    Spacer()
                    Text("\(order.items?.count ?? 0) items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if table.liveOrders.count > 3 {
                Text("+ \(table.liveOrders.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        // Secondary group members defer all order actions to the primary
        // (lowest-numbered) table — they don't get their own buttons.
        if isSecondaryGroupMember, let pn = primaryNumber {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                Text("Order at Table \(pn)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .foregroundStyle(.secondary)
        } else {
        switch table.effectiveStatus {
        case .available:
            HStack(spacing: 8) {
                Button(action: onTakeOrder) {
                    Label("Take Order", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("take-order-\(table.number)")
                Button(action: onReserve) {
                    Image(systemName: "calendar")
                }
                .buttonStyle(.bordered)
            }
        case .reserved:
            Button(action: onTakeOrder) {
                Label("Seat & Take Order", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case .billRequested:
            // Skip "Add Items" — a bill has been requested. Tap straight
            // into payment.
            Button(action: onViewOrders) {
                Label("Process Payment", systemImage: "creditcard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        case .occupied:
            HStack(spacing: 8) {
                Button(action: onViewOrders) {
                    Label("View / Pay", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("view-orders-\(table.number)")
                Button(action: onTakeOrder) {
                    Label("Add", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
            }
        case .maintenance:
            Button(action: onBackInService) {
                Label("Back in service", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        }
    }

    private var statusBadge: some View {
        let s = table.effectiveStatus
        let label: String
        switch s {
        case .available: label = "Available"
        case .occupied: label = "Occupied"
        case .reserved: label = "Reserved"
        case .billRequested: label = "Bill Req."
        case .maintenance: label = "Maint."
        }
        return Text(label)
            .font(.system(.caption, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor(for: s).opacity(0.15)))
            .overlay(Capsule().stroke(statusColor(for: s).opacity(0.5), lineWidth: 1))
            .foregroundStyle(statusColor(for: s))
    }

    private func statusChip(for status: String) -> some View {
        Text(status)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(orderStatusColor(status).opacity(0.18)))
            .foregroundStyle(orderStatusColor(status))
    }

    private func statusColor(for s: TableStatus) -> Color {
        switch s {
        case .available: return .green
        case .occupied: return .red
        case .reserved: return .yellow
        case .billRequested: return .purple
        case .maintenance: return .gray
        }
    }

    private func orderStatusColor(_ status: String) -> Color {
        switch status {
        case "PENDING": return .orange
        case "CONFIRMED": return .blue
        case "PREPARING": return .yellow
        case "READY": return .mint
        case "SERVED": return .green
        case "COMPLETED": return .gray
        case "CANCELLED": return .red
        default: return .gray
        }
    }

    private var cardBackground: Color {
        switch table.effectiveStatus {
        case .available: return Color.green.opacity(0.06)
        case .occupied: return Color.red.opacity(0.06)
        case .reserved: return Color.yellow.opacity(0.08)
        case .billRequested: return Color.purple.opacity(0.08)
        case .maintenance: return Color.gray.opacity(0.06)
        }
    }

    private var borderColor: Color {
        switch table.effectiveStatus {
        case .available: return Color.green.opacity(0.4)
        case .occupied: return Color.red.opacity(0.4)
        case .reserved: return Color.yellow.opacity(0.6)
        case .billRequested: return Color.purple.opacity(0.5)
        case .maintenance: return Color.gray.opacity(0.4)
        }
    }
}

// Internal sheet context — keeps the sheet binding identifiable.
private struct OrderingContext: Identifiable {
    let tableId: String
    let type: OrderType
    var id: String { tableId + type.rawValue }
}

/// Same pattern as OrderingContext but for the order-detail sheet —
/// SwiftUI sheets bound by `item:` need an Identifiable wrapper.
private struct DetailContext: Identifiable {
    let tableId: String
    var id: String { tableId }
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
