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
    @State private var selectedMethod: String?
    @State private var submitting = false
    @State private var errorMessage: String?

    private static let paymentMethods = ["CASH", "CARD", "UPI", "WALLET"]

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
                    }
                    Spacer()
                    Text("₹\(Int(item.unitPrice * Double(item.quantity)))")
                        .font(.subheadline)
                        .monospacedDigit()
                    statusChip(item.status, small: true)
                }
            }
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private func totalCard(table: POSTable) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total").font(.system(.headline, weight: .semibold))
                Text("\(table.liveOrders.count) order\(table.liveOrders.count == 1 ? "" : "s") • tax inclusive")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("₹\(Int(table.unpaidTotal))")
                .font(.system(.title2, weight: .bold))
                .monospacedDigit()
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

    private func paymentPicker(table: POSTable) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            Text("Payment Method")
                .font(.system(.subheadline, weight: .semibold))
            // Two-column grid of payment methods, matching the web's button row.
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Self.paymentMethods, id: \.self) { method in
                    Button {
                        selectedMethod = method
                    } label: {
                        HStack {
                            Image(systemName: methodIcon(method))
                            Text(method.capitalized)
                            Spacer()
                            if selectedMethod == method {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedMethod == method ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedMethod == method ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                Task { await doPayment(table: table) }
            } label: {
                if submitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(selectedMethod.map { "Pay ₹\(Int(table.unpaidTotal)) via \($0.capitalized)" } ?? "Select Payment Method")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedMethod == nil || submitting)
        }
        .padding(DesignTokens.spacingL)
        .webCardBackground()
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

    private func methodIcon(_ method: String) -> String {
        switch method {
        case "CASH":   return "banknote"
        case "CARD":   return "creditcard"
        case "UPI":    return "qrcode"
        case "WALLET": return "wallet.pass"
        default:       return "circle"
        }
    }

    private func orderTotalString(_ order: POSOrder) -> String {
        let total = (order.items ?? [])
            .filter { $0.status != "CANCELLED" }
            .reduce(0.0) { $0 + ($1.unitPrice * Double($1.quantity)) }
        return "₹\(Int(total))"
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
        guard let method = selectedMethod else { return }
        submitting = true
        defer { submitting = false }
        do {
            // The total shown on screen: the server refuses if the bill has
            // changed since (items added or cancelled on another device)
            try await store.processPayment(table: table,
                                           expectedTotal: Int(table.unpaidTotal.rounded()),
                                           method: method)
            dismiss()
        } catch let APIError.server(code, body) where code == 409 {
            await store.loadTables()  // show the current bill
            errorMessage = APIError.server(code: code, body: body).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
