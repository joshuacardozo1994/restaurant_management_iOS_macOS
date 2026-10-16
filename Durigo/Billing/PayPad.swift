//
//  PayPad.swift
//  Durigo
//
//  The one payment UI, used by the Till and by Pay on the POS floor: how the
//  guest pays (Cash / UPI / Card / Split, Wallet under More), a discount (a
//  code, or ₹ / % off; cashiers and admins only), the cash handed over with
//  the change, and the Pay button. The bill's figures come from BillMath, the
//  same arithmetic the server records the payment with.
//

import SwiftUI

// MARK: - What the cashier has chosen so far

@MainActor
@Observable
final class PayDraft {
    struct AppliedCode: Equatable {
        let code: String
        let amount: Int
    }

    struct SplitPart: Identifiable, Equatable {
        let id = UUID()
        var amount: Int?
        var method: String
    }

    enum DiscountMode: Hashable { case rupees, percent }

    /// CASH, UPI, CARD or WALLET; nil until chosen
    var method: String?
    var splitting = false
    var splits: [SplitPart] = []

    /// "QA10" (a code), or a number of rupees / percent
    var discountText = ""
    var discountMode: DiscountMode = .rupees
    var appliedCode: AppliedCode?
    var checkingCode = false

    /// The note or notes handed over, for the change
    var cashGiven: Int?

    private var trimmed: String { discountText.trimmingCharacters(in: .whitespaces) }

    /// The field holds a number (₹ or % off) rather than a code
    var discountIsNumber: Bool { !trimmed.isEmpty && Double(trimmed) != nil }
    var discountIsCode: Bool { !trimmed.isEmpty && Double(trimmed) == nil }

    /// Rupees off a bill of `gross`: an applied code, else the ₹ or % typed
    func discount(gross: Int, allowed: Bool) -> Int {
        guard allowed else { return 0 }
        if let appliedCode { return appliedCode.amount }
        guard let value = Double(trimmed), value > 0 else { return 0 }
        switch discountMode {
        case .rupees: return min(Int(value.rounded()), gross)
        case .percent: return Int((Double(gross) * min(value, 100) / 100).rounded())
        }
    }

    func amounts(gst: Int, vat: Int, config: BillingConfig, discountAllowed: Bool) -> BillAmounts {
        BillMath.computeBill(gst: gst, vat: vat, discount: discount(gross: gst + vat, allowed: discountAllowed),
                             config: config)
    }

    /// "Discount (QA10)", "Discount (10%)", "Discount"
    var discountLabel: String {
        if let appliedCode { return "Discount (\(appliedCode.code))" }
        if discountMode == .percent, discountIsNumber { return "Discount (\(trimmed)%)" }
        return "Discount"
    }

    func chooseMethod(_ m: String) {
        method = m
        splitting = false
        if m != "CASH" { cashGiven = nil }
    }

    /// Equal parts in whole rupees; the first person pays any odd rupees
    func splitEqually(total: Int, ways: Int) {
        let share = total / ways
        splits = (0..<ways).map { i in
            SplitPart(amount: share + (i == 0 ? total - share * ways : 0), method: i == 0 ? "CASH" : "UPI")
        }
    }

    func splitRemaining(total: Int) -> Int { total - splits.compactMap(\.amount).reduce(0, +) }

    func canPay(total: Int) -> Bool {
        if splitting {
            return !splits.isEmpty && splits.allSatisfy { ($0.amount ?? 0) > 0 } && splitRemaining(total: total) == 0
        }
        return method != nil
    }

    func payTitle(total: Int) -> String {
        if splitting { return "Pay \(total.rupees) in \(splits.count) parts" }
        guard let method else { return "Choose how they pay" }
        return "Pay \(total.rupees) by \(PayMethod.name(method))"
    }

    var tenders: [POSStore.Tender]? {
        splitting ? splits.map { POSStore.Tender(amount: $0.amount ?? 0, method: $0.method) } : nil
    }

    /// A split payment is filed under the tender that covered most of it
    var filedMethod: String? {
        tenders?.max(by: { $0.amount < $1.amount })?.method ?? method
    }

    /// "₹513 cash, ₹513 UPI" for a split bill, "cash" otherwise
    var paidBy: String {
        if let tenders {
            return tenders.map { "\($0.amount.rupees) \(PayMethod.spoken($0.method))" }.joined(separator: ", ")
        }
        return method.map(PayMethod.spoken) ?? ""
    }

    /// Exact, then the next round ₹100 and ₹500, and the next ₹2,000 if that's different
    static func cashSuggestions(total: Int) -> [Int] {
        guard total > 0 else { return [] }
        func up(_ step: Int) -> Int { ((total + step - 1) / step) * step }
        var amounts = [total]
        for step in [100, 500, 2000] where !amounts.contains(up(step)) { amounts.append(up(step)) }
        return Array(amounts.prefix(4))
    }

    func paymentBody(amounts: BillAmounts) -> TillStore.PaymentBody? {
        guard let filed = filedMethod else { return nil }
        return TillStore.PaymentBody(method: filed, expectedTotal: amounts.total,
                                     discount: appliedCode == nil && amounts.discount > 0 ? amounts.discount : nil,
                                     discountCode: appliedCode?.code, tenders: tenders)
    }
}

// MARK: - The bill's totals

/// Items, discount, taxable value, CGST, SGST, VAT on liquor and To pay
struct PayBillTotals: View {
    let amounts: BillAmounts
    let config: BillingConfig
    var discountLabel = "Discount"
    var totalLabel = "To pay"

    var body: some View {
        let taxes = ReceiptTaxes(amounts: amounts, config: config)
        VStack(spacing: 6) {
            row("Items", amounts.gross)
            if amounts.discount > 0 {
                row(discountLabel, -amounts.discount)
                    .foregroundStyle(SN.teal)
            }
            row("Taxable value", amounts.subtotal)
            if amounts.gstTax > 0 {
                row("CGST \(taxes.halfGstRate)\(taxes.inclusive)", taxes.cgst)
                row("SGST \(taxes.halfGstRate)\(taxes.inclusive)", taxes.sgst)
            }
            if amounts.vatTax > 0 {
                row("VAT \(taxes.vatRate) on liquor\(taxes.inclusive)", amounts.vatTax)
            }
            Rectangle().fill(SN.line).frame(height: 1).padding(.vertical, 4)
            HStack(alignment: .firstTextBaseline) {
                Text(totalLabel).font(.title2.weight(.bold))
                Spacer()
                Text(amounts.total.rupees)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .accessibilityIdentifier("bill-to-pay")
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func row(_ label: String, _ amount: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount < 0 ? "−\((-amount).rupees)" : amount.rupees).monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(SN.mut)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The pad

/// The pad as Form sections (the host is a Form or a List): the total, how
/// they pay, a discount and the cash handed over
struct PayPadControls: View {
    @Bindable var draft: PayDraft
    let amounts: BillAmounts
    let canDiscount: Bool
    /// Shows the big "To pay" figure at the top
    var showsTotal = true
    let applyCode: (String) -> Void

    @State private var editingSplit = false
    @FocusState private var discountFocused: Bool

    var body: some View {
        Group {
            if showsTotal {
                Section {
                    LabeledContent("To pay") {
                        Text(amounts.total.rupees)
                            .font(.largeTitle.weight(.bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .foregroundStyle(SN.ink)
                            .accessibilityIdentifier("pay-total")
                    }
                }
            }
            methods
            if canDiscount { discount }
            if !draft.splitting { cashGiven }
        }
        .sheet(isPresented: $editingSplit) {
            SplitEditorSheet(draft: draft, total: amounts.total)
        }
    }

    // MARK: Pay with

    /// Cash, UPI, Card or Split; nothing chosen until the cashier picks
    private var methodChoice: Binding<String> {
        Binding(
            get: { draft.splitting ? "SPLIT" : (draft.method.flatMap { PayMethod.main.contains($0) ? $0 : nil } ?? "") },
            set: { m in
                discountFocused = false
                if m == "SPLIT" {
                    if draft.splits.isEmpty { draft.splitEqually(total: amounts.total, ways: 2) }
                    draft.splitting = true
                    draft.cashGiven = nil
                    editingSplit = true
                } else {
                    draft.chooseMethod(m)
                }
            })
    }

    private var methods: some View {
        Section {
            Picker("Pay with", selection: methodChoice) {
                ForEach(PayMethod.main, id: \.self) { Text(PayMethod.name($0)).tag($0) }
                Text("Split").tag("SPLIT")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("pay-method")
            if draft.splitting {
                Button {
                    editingSplit = true
                } label: {
                    LabeledContent("Split \(draft.splits.count) ways",
                                   value: draft.splits.map { ($0.amount ?? 0).rupees + " " + PayMethod.name($0.method) }.joined(separator: " · "))
                }
                .accessibilityIdentifier("pay-split-edit")
            }
            Picker("Other ways to pay", selection: Binding(
                get: { draft.splitting ? "" : (draft.method.flatMap { PayMethod.more.contains($0) ? $0 : nil } ?? "") },
                set: { if !$0.isEmpty { draft.chooseMethod($0) } }
            )) {
                Text("None").tag("")
                ForEach(PayMethod.more, id: \.self) { m in
                    Label(PayMethod.name(m), systemImage: PayMethod.icon(m)).tag(m)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("pay-method-more")
        } header: {
            Text("Pay with")
        }
    }

    // MARK: Discount

    private var discount: some View {
        Section {
            if let code = draft.appliedCode {
                LabeledContent {
                    Button("Remove", role: .destructive) { draft.appliedCode = nil }
                } label: {
                    Label("\(code.code): −\(code.amount.rupees)", systemImage: "ticket")
                        .foregroundStyle(SN.teal)
                }
            } else {
                HStack(spacing: DesignTokens.spacingS) {
                    TextField("Code, or ₹ / % off", text: $draft.discountText)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if draft.discountIsCode { applyCode(draft.discountText) } }
                        .focused($discountFocused)
                        .accessibilityIdentifier("pay-discount-field")
                    if draft.discountIsCode {
                        Button(draft.checkingCode ? "Checking…" : "Apply") { applyCode(draft.discountText) }
                            .buttonStyle(.bordered)
                            .disabled(draft.checkingCode)
                            .accessibilityIdentifier("pay-code-apply")
                    } else {
                        Picker("Discount in", selection: $draft.discountMode) {
                            Text("₹").tag(PayDraft.DiscountMode.rupees)
                            Text("%").tag(PayDraft.DiscountMode.percent)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("pay-discount-mode")
                    }
                }
            }
        } header: {
            Text("Discount")
        } footer: {
            if draft.appliedCode == nil && amounts.discount > 0 {
                Text("−\(amounts.discount.rupees) off the bill").foregroundStyle(SN.teal)
            }
        }
    }

    // MARK: Cash given

    private var cashGiven: some View {
        let total = amounts.total
        let suggestions = PayDraft.cashSuggestions(total: total)
        return Section {
            Picker("Cash given", selection: Binding<Int>(
                get: { draft.method == "CASH" ? (draft.cashGiven ?? 0) : 0 },
                set: { amount in
                    discountFocused = false
                    draft.chooseMethod("CASH")
                    draft.cashGiven = amount
                })) {
                ForEach(suggestions, id: \.self) { amount in
                    Text(amount == total ? "Exact" : amount.rupees)
                        .monospacedDigit()
                        .tag(amount)
                        .accessibilityLabel(amount == total ? "Exact cash, \(amount.rupees)" : "\(amount.rupees) cash given")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("pay-cash")
            if let given = draft.cashGiven, draft.method == "CASH" {
                LabeledContent(given > total ? "Change" : "No change") {
                    if given > total {
                        Text((given - total).rupees)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(SN.teal)
                            .accessibilityIdentifier("pay-change")
                    }
                }
            }
        } header: {
            Text("Cash given")
        } footer: {
            Text("For cash: picking an amount chooses Cash and works out the change.")
        }
    }
}

/// The Pay button: "Pay ₹1,770 by UPI"
struct PayButton: View {
    let draft: PayDraft
    let total: Int
    let submitting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if submitting {
                ProgressView().tint(SN.page)
            } else {
                Text(draft.payTitle(total: total))
            }
        }
        .buttonStyle(POSActionStyle(kind: .prominent))
        .controlSize(.large)
        .disabled(!draft.canPay(total: total) || submitting)
        .accessibilityIdentifier("pay-button")
    }
}

// MARK: - Split editor

/// Split the bill: equally 2/3/4 ways or by hand; Done once the parts add up
struct SplitEditorSheet: View {
    @Bindable var draft: PayDraft
    let total: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To pay", value: total.rupees).monospacedDigit()
                    HStack {
                        Text("Split equally")
                        Spacer()
                        ForEach(2...4, id: \.self) { ways in
                            Button("\(ways)") { draft.splitEqually(total: total, ways: ways) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Split \(ways) ways")
                                .accessibilityIdentifier("pay-split-\(ways)")
                        }
                    }
                }
                Section("Payments") {
                    ForEach($draft.splits) { $part in
                        HStack {
                            Text("₹").foregroundStyle(.secondary)
                            TextField("Amount", value: $part.amount, format: .number)
                                .keyboardType(.numberPad)
                                .monospacedDigit()
                                .frame(maxWidth: 110)
                            Picker("Method", selection: $part.method) {
                                ForEach(PayMethod.correctable, id: \.self) { Text(PayMethod.name($0)).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                    .onDelete { offsets in
                        if draft.splits.count > 1 { draft.splits.remove(atOffsets: offsets) }
                    }
                    Button {
                        draft.splits.append(.init(amount: max(draft.splitRemaining(total: total), 0), method: "UPI"))
                    } label: {
                        Label("Add a payment", systemImage: "plus.circle")
                    }
                }
                Section {
                    let remaining = draft.splitRemaining(total: total)
                    Text(remaining == 0 ? "Adds up" : remaining > 0 ? "\(remaining.rupees) left" : "\((-remaining).rupees) too much")
                        .font(.headline)
                        .foregroundStyle(remaining == 0 ? SN.teal : SN.red)
                        .accessibilityIdentifier("pay-split-remaining")
                }
            }
            .navigationTitle("Split the bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't split") {
                        draft.splitting = false
                        draft.splits = []
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(!draft.canPay(total: total))
                        .accessibilityIdentifier("pay-split-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Receipt

/// A bill laid out like a Bill Generator bill, for printing or sharing
struct PaidReceipt: Identifiable {
    let id = UUID()
    let items: [MenuItem]
    let tableNumber: Int?
    let bill: SettledBill
    /// "₹513 cash, ₹513 UPI" for a split bill, "cash" otherwise; nil while unpaid
    let paidBy: String?
    /// A bill not paid yet (printed for the table to check)
    var preBill = false
    /// When it was paid, so a receipt printed later carries the bill's date
    var date: Date? = nil
}

extension SettledBill {
    init(_ a: BillAmounts) {
        self.init(gross: a.gross, discount: a.discount, subtotal: a.subtotal, tax: a.tax,
                  gstTax: a.gstTax, vatTax: a.vatTax, total: a.total)
    }

    var amounts: BillAmounts {
        BillAmounts(gross: gross, discount: discount, subtotal: subtotal, tax: tax,
                    gstTax: gstTax, vatTax: vatTax, total: total)
    }
}

/// The receipt, ready to print or share as a PDF
struct PaidReceiptSheet: View {
    let receipt: PaidReceipt
    let config: BillingConfig
    let identity: RestaurantIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var pdfURL: URL?

    private var taxes: ReceiptTaxes { ReceiptTaxes(amounts: receipt.bill.amounts, config: config) }

    private var fileName: String {
        let where_ = receipt.tableNumber.map { "Table-\($0)" } ?? "Parcel"
        return "\(receipt.preBill ? "Bill" : "Receipt")-\(where_).pdf"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let pages = BillRenderer.pages(receipt.items)
                VStack(spacing: DesignTokens.spacingL) {
                    if receipt.preBill {
                        Label("Not paid yet · \(receipt.bill.total.rupees)", systemImage: "doc.text")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else if receipt.paidBy != nil {
                        Label("Paid \(receipt.bill.total.rupees)", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("receipt-paid")
                    } else {
                        Label("Unpaid · \(receipt.bill.total.rupees)", systemImage: "exclamationmark.circle")
                            .font(.headline)
                            .foregroundStyle(.red)
                    }
                    ForEach(pages.indices, id: \.self) { index in
                        BillRenderer.page(index, of: pages, tableNumber: receipt.tableNumber ?? 0,
                                          finalTotal: receipt.bill.total, taxes: taxes,
                                          identity: identity, paidBy: receipt.paidBy, date: receipt.date)
                            .shadow(radius: 2)
                    }
                }
                .padding()
            }
            .background(Color.gray.opacity(0.15))
            .navigationTitle(receipt.preBill ? "Bill" : "Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("receipt-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Print or share", systemImage: "printer") }
                            .accessibilityIdentifier("receipt-share")
                    } else {
                        ProgressView()
                    }
                }
            }
            .task {
                pdfURL = await BillRenderer.renderPDF(items: receipt.items, tableNumber: receipt.tableNumber ?? 0,
                                                      finalTotal: receipt.bill.total, taxes: taxes,
                                                      identity: identity, paidBy: receipt.paidBy, date: receipt.date,
                                                      fileName: fileName)
            }
        }
    }
}
