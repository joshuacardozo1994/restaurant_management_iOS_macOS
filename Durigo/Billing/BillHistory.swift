//
//  BillHistory.swift
//  Durigo
//
//  Detail view for a single bill. Lets the user change the payment status
//  (mark as paid via Cash / UPI / Card, or back to Pending) and re-upload
//  the change to the server.
//

import SwiftUI

struct BillHistory: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(Session.self) private var session
    @EnvironmentObject private var menuLoader: MenuLoader
    @EnvironmentObject private var navigation: Navigation

    @State private var showingBillRegenerateAlert = false
    @State private var uploader: BillUploader?
    @State private var changingPayment = false
    @State private var paymentError: String?
    @State private var showingDiscountSheet = false

    let billHistoryItem: BillHistoryItem

    var body: some View {
        VStack(spacing: 0) {
            paymentHeader
            List {
                ForEach(billHistoryItem.items) { menuItem in
                    HStack {
                        // "2×", "½×": portions as on the printed bill
                        Text("\(menuItem.quantity.formatNumberWithFraction())× ").monospacedDigit()
                        +
                        Text(menuItem.servingSize?.shouldDisplay == true ? "\(menuItem.servingSize?.name ?? "") " : "").bold()
                        +
                        Text("\(menuItem.name)")
                        Spacer()
                        Text((menuItem.price * menuItem.quantity).rupees).monospacedDigit()
                    }
                }
            }
            totalSection
        }
        .alert("Are you sure you want to regenerate the bill", isPresented: $showingBillRegenerateAlert) {
            Button("Regenerate", role: .destructive) {
                menuLoader.billItems = billHistoryItem.items
                menuLoader.tableNumber = billHistoryItem.tableNumber
                menuLoader.waiter = billHistoryItem.waiter
                menuLoader.waiterId = billHistoryItem.waiterId
                menuLoader.customerName = billHistoryItem.customerName ?? ""
                menuLoader.customerPhone = billHistoryItem.customerPhone ?? ""
                menuLoader.billID = billHistoryItem.id
                navigation.showBillGenerator = true
                navigation.selection = .pos
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Couldn't sync payment change",
            isPresented: Binding(
                get: { paymentError != nil },
                set: { if !$0 { paymentError = nil } }
            ),
            presenting: paymentError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .navigationTitle("\(billHistoryItem.tableNumber == 0 ? "Parcel Bill" : "Table \(billHistoryItem.tableNumber) Bill")")
        .toolbar {
            paymentMenuButton
            regenerateButton
        }
        .onAppear {
            if uploader == nil { uploader = BillUploader(session: session) }
        }
    }

    // MARK: - Payment header (status chip + change menu)

    private var paymentHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Payment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusChip
            }
            Spacer()
            if changingPayment {
                ProgressView()
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var statusChip: some View {
        let (label, color) = paymentStatusDisplay(billHistoryItem.paymentStatus)
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(.body, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
    }

    private func paymentStatusDisplay(_ status: BillHistoryItemStatus) -> (String, Color) {
        switch status {
        case .paidByCash: ("Cash", .green)
        case .paidByUPI:  ("UPI", .purple)
        case .paidByCard: ("Card", .blue)
        case .pending:    ("Pending", .orange)
        }
    }

    // MARK: - Toolbar buttons

    private var paymentMenuButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { setPaymentStatus(.paidByCash) } label: {
                    if billHistoryItem.paymentStatus == .paidByCash {
                        Label("Cash", systemImage: "checkmark")
                    } else {
                        Text("Cash")
                    }
                }
                Button { setPaymentStatus(.paidByUPI) } label: {
                    if billHistoryItem.paymentStatus == .paidByUPI {
                        Label("UPI", systemImage: "checkmark")
                    } else {
                        Text("UPI")
                    }
                }
                Button { setPaymentStatus(.paidByCard) } label: {
                    if billHistoryItem.paymentStatus == .paidByCard {
                        Label("Card", systemImage: "checkmark")
                    } else {
                        Text("Card")
                    }
                }
                Divider()
                Button { setPaymentStatus(.pending) } label: {
                    if billHistoryItem.paymentStatus == .pending {
                        Label("Pending", systemImage: "checkmark")
                    } else {
                        Text("Pending")
                    }
                }
            } label: {
                Label("Payment", systemImage: "creditcard")
            }
            .disabled(changingPayment)
            .accessibilityIdentifier("bill-payment-menu")
        }
    }

    private var regenerateButton: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Button {
                showingBillRegenerateAlert.toggle()
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Total

    private var totalSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(billHistoryItem.items.count) Items").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\((billHistoryItem.items.getTotal()).rupees)").font(.subheadline).foregroundStyle(.secondary)
            }
            if let d = billHistoryItem.discount, d > 0 {
                HStack {
                    Text(billHistoryItem.discountReason ?? "Discount")
                        .font(.subheadline).foregroundStyle(.green)
                    Spacer()
                    Text("−\(d.rupees)").font(.subheadline).foregroundStyle(.green)
                }
            }
            Divider()
            HStack {
                Text("Total")
                Spacer()
                Text(billHistoryItem.totalAmount.rupees)
            }
            .font(.title2.weight(.bold))
            // Discounts are for the cashier and admin (the server refuses a
            // discounted bill from anyone else)
            if ["ADMIN", "CASHIER"].contains(session.user?.role.uppercased() ?? "") {
                HStack(spacing: 12) {
                    Button {
                        showingDiscountSheet = true
                    } label: {
                        Label((billHistoryItem.discount ?? 0) > 0 ? "Edit discount" : "Apply discount",
                              systemImage: "ticket")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("bill-detail-apply-discount")
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .sheet(isPresented: $showingDiscountSheet) {
            DiscountSheet(
                subtotal: billHistoryItem.items.getTotal(),
                initialAmount: billHistoryItem.discount ?? 0,
                initialReason: billHistoryItem.discountReason ?? ""
            ) { amount, reason in
                applyDiscount(amount: amount, reason: reason)
            }
        }
    }

    private func applyDiscount(amount: Double, reason: String) {
        let previousAmount = billHistoryItem.discount
        let previousReason = billHistoryItem.discountReason
        billHistoryItem.discount = amount > 0 ? amount : nil
        billHistoryItem.discountReason = amount > 0 ? (reason.isEmpty ? nil : reason) : nil
        billHistoryItem.syncedAt = nil
        try? modelContext.save()
        guard let uploader else { return }
        Task { @MainActor in
            changingPayment = true
            defer { changingPayment = false }
            do {
                try await uploader.uploadOne(billHistoryItem)
            } catch {
                billHistoryItem.discount = previousAmount
                billHistoryItem.discountReason = previousReason
                try? modelContext.save()
                paymentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: - Apply payment change

    private func setPaymentStatus(_ status: BillHistoryItemStatus) {
        guard billHistoryItem.paymentStatus != status else { return }
        let previous = billHistoryItem.paymentStatus

        billHistoryItem.paymentStatus = status
        billHistoryItem.syncedAt = nil
        try? modelContext.save()

        guard let uploader else { return }
        Task { @MainActor in
            changingPayment = true
            defer { changingPayment = false }
            do {
                try await uploader.uploadOne(billHistoryItem)
            } catch {
                // Roll back on network/server failure so SwiftData stays
                // consistent with the server.
                billHistoryItem.paymentStatus = previous
                try? modelContext.save()
                paymentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Discount entry sheet

/// Reusable discount-entry sheet — used by BillHistory detail and the
/// BillGenerator total bar. Returns (amount, reason) via `onApply`. Lets the
/// user pick a percentage shortcut (5/10/15%), enter a fixed ₹ amount, or
/// clear an existing discount.
struct DiscountSheet: View {
    let subtotal: Int
    let initialAmount: Double
    let initialReason: String
    let onApply: (Double, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: DiscountMode = .percent
    @State private var percentValue: Double = 10
    @State private var fixedValue: Double = 0
    @State private var reason: String = ""

    enum DiscountMode: String, CaseIterable, Identifiable {
        case percent, fixed
        var id: String { rawValue }
        var label: String { self == .percent ? "%" : "₹" }
    }

    private var computedAmount: Double {
        switch mode {
        case .percent: return min(Double(subtotal), Double(subtotal) * percentValue / 100)
        case .fixed:   return min(Double(subtotal), fixedValue)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Subtotal") {
                    LabeledContent("Bill subtotal", value: "\((subtotal).rupees)")
                }
                Section("Discount") {
                    Picker("Mode", selection: $mode) {
                        Text("Percentage").tag(DiscountMode.percent)
                        Text("Fixed (₹)").tag(DiscountMode.fixed)
                    }
                    .pickerStyle(.segmented)
                    if mode == .percent {
                        HStack {
                            Stepper(value: $percentValue, in: 0...100, step: 1) {
                                Text(String(format: "%.0f%% off", percentValue))
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach([5, 10, 15, 20, 25] as [Int], id: \.self) { v in
                                Button("\(v)%") { percentValue = Double(v) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        HStack {
                            Text("Amount")
                            Spacer()
                            Text("₹")
                            TextField("0", value: $fixedValue, format: .number).labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                            #if os(iOS)
                                .keyboardType(.numberPad)
                            #endif
                        }
                    }
                }
                Section("Reason (optional)") {
                    TextField("e.g. Loyalty, Promo code WELCOME10", text: $reason)
                        .accessibilityIdentifier("discount-reason-field")
                }
                Section {
                    LabeledContent("Discount") { Text("−\((computedAmount).rupees)").foregroundStyle(.green) }
                    LabeledContent("Final total") { Text("\((max(0, subtotal - Int(computedAmount))).rupees)").font(.headline) }
                }
                if initialAmount > 0 {
                    Section {
                        Button("Clear discount", role: .destructive) {
                            onApply(0, "")
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Apply Discount")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(computedAmount, reason)
                        dismiss()
                    }
                    .disabled(computedAmount <= 0)
                    .accessibilityIdentifier("discount-apply-button")
                }
            }
            .onAppear {
                if initialAmount > 0 {
                    mode = .fixed
                    fixedValue = initialAmount
                    reason = initialReason
                }
            }
        }
        .interactiveDismissDisabled(false)
    }
}

#Preview {
    BillHistory(billHistoryItem: BillHistoryItem(id: UUID(), items: [MenuItem](), tableNumber: 1, waiter: "anthony"))
}
