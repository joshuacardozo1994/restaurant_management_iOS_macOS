//
//  OrderDetailView.swift
//  Durigo
//
//  Sheet shown when a waiter taps a table card with active orders.
//  Mirrors the web's `/pos/order/[id]` page but at the *table* level —
//  payment is computed across every live order on the table and all of
//  them get completed together (matches web behavior).
//

import SwiftUI

struct OrderDetailView: View {
    @Bindable var store: POSStore
    let tableId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(Session.self) private var session
    @EnvironmentObject private var menuLoader: MenuLoader
    @State private var submitting = false
    @State private var errorMessage: String?

    /// Method, discount, split and cash given, shared with the Till's pay pad
    @State private var draft = PayDraft()

    /// Shown once the table is paid
    @State private var receipt: PaidReceipt?

    /// The order being cancelled, and the optional reason for its log
    @State private var cancelling: POSOrder?
    @State private var cancelReason = ""

    private var table: POSTable? {
        store.tables.first(where: { $0.id == tableId })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let table {
                    content(table: table)
                } else {
                    ContentUnavailableView("Table not found", systemImage: "tray")
                }
            }
            .navigationTitle(table.map { "Table \($0.number)" } ?? "Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            // Categories decide GST vs VAT for the breakdown
            .task { if store.menu.isEmpty { await store.loadMenu() } }
            .alert("Cancel this whole order?", isPresented: Binding(
                get: { cancelling != nil },
                set: { if !$0 { cancelling = nil } }
            ), presenting: cancelling) { order in
                TextField("Reason (optional)", text: $cancelReason)
                Button("Cancel Order", role: .destructive) { Task { await doCancel(order) } }
                Button("Keep It", role: .cancel) { cancelling = nil }
            } message: { _ in
                Text("It will be taken off the bill and the kitchen.")
            }
            .sheet(item: $receipt, onDismiss: { dismiss() }) { paid in
                PaidReceiptSheet(receipt: paid, config: menuLoader.billingConfig, identity: menuLoader.identity)
            }
        }
    }

    @ViewBuilder
    private func content(table: POSTable) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                statusBanner(table: table)
                ForEach(table.liveOrders) { order in
                    orderCard(order)
                }
                if !table.liveOrders.isEmpty {
                    totalCard(table: table)
                    actionZone(table: table)
                } else {
                    emptyState
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func statusBanner(table: POSTable) -> some View {
        let s = table.effectiveStatus
        let label: String
        let color: Color
        switch s {
        case .billRequested: label = "Bill Requested — awaiting payment"; color = .purple
        case .occupied:      label = "Occupied"; color = .red
        case .reserved:      label = "Reserved"; color = .yellow
        case .available:     label = "Available"; color = .green
        case .maintenance:   label = "Maintenance"; color = .gray
        }
        return HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(.subheadline, weight: .semibold)).foregroundStyle(color)
            Spacer()
            Text("\(table.capacity) seats").font(.caption).foregroundStyle(.secondary)
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(color.opacity(0.08)))
    }

    private func orderCard(_ order: POSOrder) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack {
                Text("#\(order.orderNumber?.suffix(4).map(String.init).joined() ?? String(order.id.suffix(4)))")
                    .font(.system(.subheadline, design: .monospaced, weight: .bold))
                statusChip(order.status)
                Spacer()
                Text(orderTotalString(order))
                    .font(.system(.subheadline, weight: .semibold))
                    .monospacedDigit()
            }
            if let waiter = order.waiter?.name, !waiter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption2)
                    Text(waiter).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            // Order-level notes (shown to the kitchen on every card and
            // here for the cashier/waiter to verify against the receipt).
            if let n = order.notes, !n.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "note.text")
                        .font(.caption2)
                    Text(n)
                        .font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
                .foregroundStyle(.blue)
            }
            ForEach(order.items?.filter { $0.status != "CANCELLED" } ?? []) { item in
                HStack(alignment: .top) {
                    Text("\(item.quantity)×")
                        .font(.caption.monospaced())
                        .frame(width: 28, alignment: .leading)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.subheadline)
                        if let v = item.displayVariant, !v.isEmpty {
                            Text(v).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let extras = item.modifiers?.summary {
                            Text(extras).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\((item.unitPrice * Double(item.quantity)).rupees)")
                        .font(.subheadline)
                        .monospacedDigit()
                    statusChip(item.status, small: true)
                }
            }
            if canCancel(order) {
                Button(role: .destructive) {
                    cancelReason = ""
                    cancelling = order
                } label: {
                    Label("Cancel order", systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(submitting)
                .accessibilityIdentifier("order-cancel-\(order.id)")
            }
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    // MARK: Cancel

    /// Staff can cancel until food is served; after that only an admin can
    /// (the server enforces the same rule)
    private func canCancel(_ order: POSOrder) -> Bool {
        if session.user?.role.uppercased() == "ADMIN" { return true }
        let served = order.status.uppercased() == "SERVED"
            || (order.items ?? []).contains { $0.status.uppercased() == "SERVED" }
        return !served
    }

    private func doCancel(_ order: POSOrder) async {
        cancelling = nil
        submitting = true
        defer { submitting = false }
        do {
            let reason = cancelReason.trimmingCharacters(in: .whitespacesAndNewlines)
            try await store.cancelOrder(order.id, reason: reason.isEmpty ? nil : reason)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Bill

    /// Discounts are for the cashier or an admin (the server refuses others)
    private var canDiscount: Bool {
        ["ADMIN", "CASHIER"].contains(session.user?.role.uppercased() ?? "")
    }

    /// The bill as the server will record it: GST on food, VAT on liquor
    private func bill(for table: POSTable) -> BillAmounts {
        let gross = store.grossByTax(for: table)
        return draft.amounts(gst: gross.gst, vat: gross.vat, config: menuLoader.billingConfig,
                             discountAllowed: canDiscount && table.effectiveStatus == .billRequested)
    }

    private func totalCard(table: POSTable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PayBillTotals(amounts: bill(for: table), config: menuLoader.billingConfig,
                          discountLabel: draft.discountLabel)
            Text("\(table.liveOrders.count) order\(table.liveOrders.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(DesignTokens.spacingL)
        .webCardBackground()
    }

    @ViewBuilder
    private func actionZone(table: POSTable) -> some View {
        switch table.effectiveStatus {
        case .billRequested:
            paymentPicker(table: table)
        case .occupied, .reserved:
            // Allow Request Bill once everything has at least been served.
            // Web allows it any time; we mirror.
            Button {
                Task { await doRequestBill() }
            } label: {
                if submitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Request Bill", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(submitting)
        default:
            EmptyView()
        }
    }

    /// The same pay pad as the Till
    private func paymentPicker(table: POSTable) -> some View {
        let amounts = bill(for: table)
        return VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            PayPadControls(draft: draft, amounts: amounts, canDiscount: canDiscount) { code in
                Task { await applyCode(code, table: table) }
            }
            PayButton(draft: draft, total: amounts.total, submitting: submitting) {
                Task { await doPayment(table: table) }
            }
        }
        .padding(DesignTokens.spacingL)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).fill(SN.page))
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "tray").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text("No active orders").font(.headline)
            Text("This table has been cleared.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(DesignTokens.spacing2XL)
    }

    // MARK: Helpers

    private func orderTotalString(_ order: POSOrder) -> String {
        let total = (order.items ?? [])
            .filter { $0.status != "CANCELLED" }
            .reduce(0.0) { $0 + ($1.unitPrice * Double($1.quantity)) }
        return "\((total).rupees)"
    }

    private func statusChip(_ status: String, small: Bool = false) -> some View {
        let color: Color
        switch status {
        case "PENDING":   color = .orange
        case "CONFIRMED": color = .blue
        case "PREPARING": color = .yellow
        case "READY":     color = .mint
        case "SERVED":    color = .green
        case "COMPLETED": color = .gray
        case "CANCELLED": color = .red
        default:          color = .gray
        }
        return Text(status)
            .font(.system(size: small ? 9 : 10, weight: .semibold))
            .padding(.horizontal, small ? 5 : 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    // MARK: Actions

    private func doRequestBill() async {
        submitting = true
        defer { submitting = false }
        do {
            try await store.requestBill(tableId: tableId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func doPayment(table: POSTable) async {
        let amounts = bill(for: table)
        guard let method = draft.filedMethod else { return }
        // What's being paid for, for the receipt (captured before the table
        // clears): every order on the table
        let items = table.liveOrders.flatMap { $0.items ?? [] }
            .filter { $0.status != "CANCELLED" }
            .map { item in
                MenuItem(id: UUID(),
                         name: item.displayVariant.map { "\(item.displayName) (\($0))" } ?? item.displayName,
                         quantity: Double(item.quantity), price: item.unitPrice)
            }
        submitting = true
        defer { submitting = false }
        do {
            // The total shown on screen: the server refuses if the bill has
            // changed since (items added or cancelled on another device)
            let settled = try await store.processPayment(
                table: table, expectedTotal: amounts.total, method: method,
                discount: amounts.discount > 0 ? amounts.discount : nil,
                discountCode: draft.appliedCode?.code, tenders: draft.tenders)
            receipt = PaidReceipt(items: items, tableNumber: table.number, bill: settled, paidBy: draft.paidBy)
        } catch let APIError.server(code, body) where code == 409 {
            await store.loadTables()  // show the current bill
            errorMessage = APIError.server(code: code, body: body).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyCode(_ text: String, table: POSTable) async {
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        let gross = store.grossByTax(for: table)
        draft.checkingCode = true
        defer { draft.checkingCode = false }
        do {
            let amount = try await store.discountCodeValue(code: code, orderTotal: gross.gst + gross.vat)
            draft.appliedCode = .init(code: code, amount: amount)
            draft.discountText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
