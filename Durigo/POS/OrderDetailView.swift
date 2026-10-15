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
    @State private var selectedMethod: String?
    @State private var submitting = false
    @State private var errorMessage: String?

    // Discount: a manual amount in ₹, or a code checked with the server
    @State private var discountText = ""
    @State private var codeText = ""
    @State private var appliedCode: AppliedCode?
    @State private var checkingCode = false

    // Split bill: the tenders must add up to the bill
    @State private var splitting = false
    @State private var splits: [SplitPart] = []

    /// Shown once the table is paid
    @State private var receipt: PaidReceipt?

    /// The order being cancelled, and the optional reason for its log
    @State private var cancelling: POSOrder?
    @State private var cancelReason = ""

    struct AppliedCode: Equatable {
        let code: String
        let amount: Int
    }

    struct SplitPart: Identifiable, Equatable {
        let id = UUID()
        var amount: Int?
        var method: String
    }

    struct PaidReceipt: Identifiable {
        let id = UUID()
        let items: [MenuItem]
        let tableNumber: Int
        let bill: SettledBill
        /// "₹513 cash, ₹513 UPI" for a split bill, "cash" otherwise
        let paidBy: String
    }

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

    private func discount(for table: POSTable) -> Int {
        if let appliedCode { return appliedCode.amount }
        guard canDiscount, let amount = Int(discountText.trimmingCharacters(in: .whitespaces)) else { return 0 }
        return max(amount, 0)
    }

    /// The bill as the server will record it: GST on food, VAT on liquor
    private func bill(for table: POSTable) -> BillAmounts {
        let gross = store.grossByTax(for: table)
        return BillMath.computeBill(gst: gross.gst, vat: gross.vat, discount: discount(for: table),
                                    config: menuLoader.billingConfig)
    }

    private func totalCard(table: POSTable) -> some View {
        let amounts = bill(for: table)
        let taxes = ReceiptTaxes(amounts: amounts, config: menuLoader.billingConfig)
        return VStack(spacing: 6) {
            if amounts.discount > 0 {
                billRow("Items", amounts.gross)
                billRow("Discount\(appliedCode.map { " (\($0.code))" } ?? "")", -amounts.discount)
                    .foregroundStyle(.green)
            }
            billRow("Taxable value", amounts.subtotal)
            if amounts.gstTax > 0 {
                billRow("CGST @ \(taxes.halfGstRate)\(taxes.inclusive)", taxes.cgst)
                billRow("SGST @ \(taxes.halfGstRate)\(taxes.inclusive)", taxes.sgst)
            }
            if amounts.vatTax > 0 {
                billRow("VAT on liquor @ \(taxes.vatRate)\(taxes.inclusive)", amounts.vatTax)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total").font(.system(.headline, weight: .semibold))
                    Text("\(table.liveOrders.count) order\(table.liveOrders.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\((amounts.total).rupees)")
                    .font(.system(.title2, weight: .bold))
                    .monospacedDigit()
                    .accessibilityIdentifier("pay-total")
            }
        }
        .padding(DesignTokens.spacingL)
        .webCardBackground()
    }

    private func billRow(_ label: String, _ amount: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount < 0 ? "−\((-amount).rupees)" : "\((amount).rupees)").monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
        let total = bill(for: table).total
        return VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            if canDiscount {
                discountSection(table: table)
                Divider()
            }

            Toggle("Split the bill", isOn: $splitting.animation())
                .font(.system(.subheadline, weight: .semibold))
                .accessibilityIdentifier("pay-split-toggle")
                .onChange(of: splitting) {
                    if splitting && splits.isEmpty { splitEqually(total: total, ways: 2) }
                }

            if splitting {
                splitSection(total: total)
            } else {
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
                                Text(methodName(method))
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
            }

            Button {
                Task { await doPayment(table: table) }
            } label: {
                if submitting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(payButtonTitle(total: total))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPay(total: total) || submitting)
            .accessibilityIdentifier("pay-button")
        }
        .padding(DesignTokens.spacingL)
        .webCardBackground()
    }

    @ViewBuilder
    private func discountSection(table: POSTable) -> some View {
        Text("Discount").font(.system(.subheadline, weight: .semibold))
        if let appliedCode {
            HStack {
                Label("\(appliedCode.code): −\((appliedCode.amount).rupees)", systemImage: "ticket.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Remove", role: .destructive) { self.appliedCode = nil }
            }
            .font(.subheadline)
        } else {
            HStack {
                TextField("Code", text: $codeText)
                    .accessibilityIdentifier("pay-code-field")
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button(checkingCode ? "Checking…" : "Apply") {
                    Task { await applyCode(table: table) }
                }
                .disabled(codeText.trimmingCharacters(in: .whitespaces).isEmpty || checkingCode)
                .accessibilityIdentifier("pay-code-apply")
            }
            HStack {
                Text("or amount ₹").font(.subheadline).foregroundStyle(.secondary)
                TextField("0", text: $discountText).labelsHidden()
                    .accessibilityIdentifier("pay-discount-amount")
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
            }
        }
    }

    @ViewBuilder
    private func splitSection(total: Int) -> some View {
        let paid = splits.compactMap(\.amount).reduce(0, +)
        HStack {
            Text("Split equally").font(.subheadline)
            Spacer()
            ForEach(2...4, id: \.self) { ways in
                Button("\(ways)") { splitEqually(total: total, ways: ways) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pay-split-\(ways)")
            }
        }
        ForEach($splits) { $part in
            HStack {
                Text("₹").foregroundStyle(.secondary)
                TextField("Amount", value: $part.amount, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 110)
                Picker("Method", selection: $part.method) {
                    ForEach(Self.paymentMethods, id: \.self) { Text(methodName($0)).tag($0) }
                }
                .pickerStyle(.menu)
                Spacer()
                if splits.count > 1 {
                    Button(role: .destructive) {
                        splits.removeAll { $0.id == part.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                }
            }
        }
        HStack {
            Button {
                splits.append(SplitPart(amount: max(total - paid, 0), method: "UPI"))
            } label: { Label("Add a payment", systemImage: "plus.circle") }
            Spacer()
            let remaining = total - paid
            Text(remaining == 0 ? "Adds up" : remaining > 0 ? "\((remaining).rupees) left" : "\((-remaining).rupees) too much")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(remaining == 0 ? .green : .red)
        }
    }

    /// Equal parts in whole rupees; the first person pays any odd rupees
    private func splitEqually(total: Int, ways: Int) {
        let share = total / ways
        splits = (0..<ways).map { i in
            SplitPart(amount: share + (i == 0 ? total - share * ways : 0), method: i == 0 ? "CASH" : "UPI")
        }
    }

    private func canPay(total: Int) -> Bool {
        if splitting {
            return !splits.isEmpty && splits.allSatisfy { ($0.amount ?? 0) > 0 }
                && splits.compactMap(\.amount).reduce(0, +) == total
        }
        return selectedMethod != nil
    }

    private func payButtonTitle(total: Int) -> String {
        if splitting { return "Pay \((total).rupees) in \(splits.count) parts" }
        return selectedMethod.map { "Pay \((total).rupees) via \(methodName($0))" } ?? "Select Payment Method"
    }

    private func methodName(_ method: String) -> String {
        method == "UPI" ? "UPI" : method.capitalized
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
        let tenders = splitting ? splits.map { POSStore.Tender(amount: $0.amount ?? 0, method: $0.method) } : nil
        // A split payment is filed under the tender that covered most of it
        guard let method = tenders?.max(by: { $0.amount < $1.amount })?.method ?? selectedMethod else { return }
        // What's being paid for, for the receipt (captured before the table clears)
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
                discountCode: appliedCode?.code, tenders: tenders)
            // "₹513 cash, ₹513 UPI" (as the web receipt lists split tenders)
            let spoken = { (m: String) in m == "UPI" ? "UPI" : m.lowercased() }
            let paidBy = tenders.map { $0.map { "\(($0.amount).rupees) \(spoken($0.method))" }.joined(separator: ", ") }
                ?? spoken(method)
            receipt = PaidReceipt(items: items, tableNumber: table.number, bill: settled, paidBy: paidBy)
        } catch let APIError.server(code, body) where code == 409 {
            await store.loadTables()  // show the current bill
            errorMessage = APIError.server(code: code, body: body).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyCode(table: POSTable) async {
        let code = codeText.trimmingCharacters(in: .whitespaces).uppercased()
        let gross = store.grossByTax(for: table)
        checkingCode = true
        defer { checkingCode = false }
        do {
            let amount = try await store.discountCodeValue(code: code, orderTotal: gross.gst + gross.vat)
            appliedCode = AppliedCode(code: code, amount: amount)
            discountText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Receipt after a table is paid

/// The bill the server recorded, laid out like a Bill Generator bill, ready to
/// print or share as a PDF
private struct PaidReceiptSheet: View {
    let receipt: OrderDetailView.PaidReceipt
    let config: BillingConfig
    let identity: RestaurantIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var pdfURL: URL?

    private var taxes: ReceiptTaxes {
        let b = receipt.bill
        return ReceiptTaxes(amounts: BillAmounts(gross: b.gross, discount: b.discount, subtotal: b.subtotal,
                                                 tax: b.tax, gstTax: b.gstTax, vatTax: b.vatTax, total: b.total),
                            config: config)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let pages = BillRenderer.pages(receipt.items)
                VStack(spacing: DesignTokens.spacingL) {
                    Label("Paid \((receipt.bill.total).rupees)", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("receipt-paid")
                    ForEach(pages.indices, id: \.self) { index in
                        BillRenderer.page(index, of: pages, tableNumber: receipt.tableNumber,
                                          finalTotal: receipt.bill.total, taxes: taxes,
                                          identity: identity, paidBy: receipt.paidBy)
                            .shadow(radius: 2)
                    }
                }
                .padding()
            }
            .background(Color.gray.opacity(0.15))
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Print or share", systemImage: "printer") }
                    } else {
                        ProgressView()
                    }
                }
            }
            .task {
                pdfURL = await BillRenderer.renderPDF(items: receipt.items, tableNumber: receipt.tableNumber,
                                                      finalTotal: receipt.bill.total, taxes: taxes,
                                                      identity: identity, paidBy: receipt.paidBy,
                                                      fileName: "Receipt-Table-\(receipt.tableNumber).pdf")
            }
        }
    }
}
