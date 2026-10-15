//
//  LedgerView.swift
//  Durigo
//
//  Billing's "Bills": the day's bills (or yesterday's, or a range), searchable
//  and filtered, with the day's takings, how they were paid, the tax and the
//  discounts. A bill opens beside the list on a wide screen and as its own
//  screen on an iPhone: its totals and tenders, Print / share receipt, Change
//  method, and for an unpaid Bill Generator bill Mark paid.
//
//  Bill Generator bills still live on the device too (SwiftData): the ones
//  not uploaded yet are listed with Upload, and Sync All Unsynced is in the
//  toolbar menu, as in the old bill history.
//

import SwiftUI
import SwiftData

private enum RangeChoice: Hashable { case today, yesterday, pick }

/// Finds the device's copy of a Bill Generator bill. The server keeps the
/// bill's time to the millisecond (its paid or made time), so the times match.
struct LocalBillIndex {
    private var bySecond: [Int: [BillHistoryItem]] = [:]

    init(_ bills: [BillHistoryItem]) {
        for b in bills { bySecond[Int(b.date.timeIntervalSince1970), default: []].append(b) }
    }

    func bill(for ledger: LedgerBill) -> BillHistoryItem? {
        guard ledger.fromApp, let date = ledger.date else { return nil }
        let s = Int(date.timeIntervalSince1970)
        let candidates = (s - 2...s + 2).flatMap { bySecond[$0] ?? [] }
            .filter { abs($0.date.timeIntervalSince(date)) < 2 }
        return candidates.first { $0.tableNumber == (ledger.tableNumber ?? 0) } ?? candidates.first
    }
}

struct LedgerView: View {
    @Bindable var store: TillStore
    @Binding var mode: BillingMode
    let width: CGFloat
    @Binding var path: [BillingRoute]
    let openTill: (String) -> Void

    @Environment(Session.self) private var session
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BillHistoryItem.date, order: .reverse) private var appBills: [BillHistoryItem]

    @State private var choice: RangeChoice = .today
    @State private var pickingDates = false
    @State private var pickFrom = Date()
    @State private var pickTo = Date()
    @State private var search = ""
    @State private var waiter: String?
    @State private var method: String?
    @State private var unpaidOnly = false
    @State private var appOnly = false
    @State private var selectedId: String?

    @State private var uploader: BillUploader?
    @State private var syncMessage: String?
    /// Bills from the Bill Generator last looked for on the server
    @State private var lastMissing: Set<String> = []
    /// A Bill Generator bill being marked paid from its row (asks how)
    @State private var markingPaid: BillHistoryItem?

    static let sideBySideWidth: CGFloat = 700

    private var wide: Bool { width >= Self.sideBySideWidth }
    private var detailWidth: CGFloat { min(400, width * 0.36) }
    /// Rows as a table (Bill · Time · Where · Waiter · Paid by · Amount) when the list has room
    private var tableRows: Bool { wide && width - detailWidth >= 640 }

    // MARK: Data

    private var filtered: [LedgerBill] {
        store.ledger.filter { b in
            if unpaidOnly && b.paid { return false }
            if appOnly && !b.fromApp { return false }
            if let waiter, b.waiter != waiter { return false }
            if let method {
                if method == "UNPAID" { if b.paid { return false } }
                else if !b.tenders.contains(where: { $0.method == method }) { return false }
            }
            return b.matches(search)
        }
    }

    private var waiters: [String] {
        Array(Set(store.ledger.compactMap(\.waiter))).sorted()
    }

    private var methods: [String] {
        let used = Set(store.ledger.flatMap { $0.tenders.map(\.method) })
        return PayMethod.correctable.filter(used.contains) + used.subtracting(PayMethod.correctable).sorted()
    }

    /// Bill Generator bills made in these dates, on this device
    private var appBillsInRange: [BillHistoryItem] {
        let window = store.range.window
        return appBills.filter { window.contains($0.date) }
    }

    /// Bill Generator bills not on the server yet
    private var notUploaded: [BillHistoryItem] {
        appBillsInRange.filter { $0.syncedAt == nil && $0.matches(search) }
    }

    private var unsyncedCount: Int { appBills.count { $0.syncedAt == nil } }

    /// The bill in the detail panel: the chosen one, else the newest
    private var shownId: String? {
        filtered.first(where: { $0.id == selectedId })?.id ?? filtered.first?.id
    }

    private var filtersOn: Bool { waiter != nil || method != nil || unpaidOnly || appOnly }

    // MARK: Body

    var body: some View {
        let index = LocalBillIndex(appBillsInRange)
        Group {
            if wide {
                HStack(spacing: 0) {
                    list(index: index)
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(SN.line).frame(width: 1)
                    detailPanel(index: index)
                        .frame(width: detailWidth)
                        .background(SN.panel, ignoresSafeAreaEdges: [])
                }
            } else {
                list(index: index)
            }
        }
        #if os(iOS)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Bill number, table, waiter, customer, dish")
        #else
        .searchable(text: $search, prompt: "Bill number, table, waiter, customer, dish")
        #endif
        .toolbar { toolbar }
        .sheet(isPresented: $pickingDates) { datesSheet }
        .confirmationDialog("How was it paid?", isPresented: Binding(
            get: { markingPaid != nil }, set: { if !$0 { markingPaid = nil } }
        ), titleVisibility: .visible, presenting: markingPaid) { bill in
            Button("Cash") { markPaid(bill, .paidByCash) }
            Button("UPI") { markPaid(bill, .paidByUPI) }
            Button("Card") { markPaid(bill, .paidByCard) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Bills", isPresented: Binding(get: { syncMessage != nil }, set: { if !$0 { syncMessage = nil } })) {
            Button("OK") { syncMessage = nil }
        } message: {
            Text(syncMessage ?? "")
        }
        .task {
            store.watchingLedger = true
            if uploader == nil { uploader = BillUploader(session: session) }
            await store.loadLedger()
            await syncDevice(silent: true)
        }
        .onDisappear { store.watchingLedger = false }
        .onChange(of: store.ledger) { _, bills in
            // A bill made on another device: fetch the latest Bill Generator
            // bills so this device has a copy to mark paid or regenerate
            let index = LocalBillIndex(appBillsInRange)
            let missing = Set(bills.filter { $0.fromApp && index.bill(for: $0) == nil }.map(\.id))
            if !missing.isEmpty, missing != lastMissing {
                lastMissing = missing
                Task { await refreshDeviceCopies() }
            }
        }
    }

    // MARK: List

    private func list(index: LocalBillIndex) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
                    rangePicker
                    // While searching on a phone, the results come first
                    if wide || search.isEmpty {
                        LedgerSummaryCards(summary: store.summary, wide: wide)
                        waitingStrip
                    }
                    if let msg = store.ledgerError {
                        Label("Showing the last list: \(msg)", systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(SN.red)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }

            if !notUploaded.isEmpty {
                Section {
                    ForEach(notUploaded) { bill in
                        NavigationLink(value: BillingRoute.appBill(bill.id)) {
                            NotUploadedRow(bill: bill) { Task { await upload([bill]) } }
                        }
                        .listRowBackground(SN.panel)
                    }
                } header: {
                    HStack {
                        Text("On this device, not uploaded")
                        Spacer()
                        Button("Upload all") { Task { await syncDevice(silent: false) } }
                            .font(.footnote.weight(.semibold))
                            .disabled(uploader?.isUploading ?? false)
                            .accessibilityIdentifier("ledger-upload-all")
                    }
                }
            }

            Section {
                if tableRows { LedgerHeaderRow() }
                ForEach(filtered) { bill in
                    let local = index.bill(for: bill)
                    row(bill, local: local)
                        .listRowBackground(wide && shownId == bill.id ? SN.teal.opacity(0.12) : SN.panel)
                        .swipeActions(edge: .trailing) {
                            if !bill.paid, let local {
                                Button("Mark paid", systemImage: "checkmark.circle") { markingPaid = local }
                                    .tint(SN.teal)
                            }
                        }
                }
                if filtered.isEmpty {
                    emptyRow.listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            BillingModePicker(mode: $mode)
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.vertical, DesignTokens.spacingS)
                .background(SN.page)
        }
        .refreshable {
            await store.loadLedger()
            await refreshDeviceCopies()
        }
    }

    @ViewBuilder
    private func row(_ bill: LedgerBill, local: BillHistoryItem?) -> some View {
        let content = LedgerRow(bill: bill, wide: tableRows, unsynced: local.map { $0.syncedAt == nil } ?? false)
            .accessibilityIdentifier(local.map { "BillHistoryList-Item-\($0.id.uuidString)" } ?? "ledger-row-\(bill.billNo)")
        if wide {
            Button { selectedId = bill.id } label: { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shownId == bill.id ? .isSelected : [])
        } else {
            NavigationLink(value: BillingRoute.ledger(bill)) { content }
        }
    }

    @ViewBuilder
    private var emptyRow: some View {
        if !store.ledgerLoaded {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if store.ledger.isEmpty {
            ContentUnavailableView("No bills", systemImage: "doc.text",
                                   description: Text("Bills paid \(store.range == .today ? "today" : "on these dates") show up here."))
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private var rangePicker: some View {
        Picker("Dates", selection: Binding(get: { choice }, set: { setChoice($0) })) {
            Text("Today").tag(RangeChoice.today)
            Text("Yesterday").tag(RangeChoice.yesterday)
            Text(choice == .pick ? store.range.title : "Pick dates").tag(RangeChoice.pick)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("ledger-range")
    }

    private func setChoice(_ c: RangeChoice) {
        switch c {
        case .today: choice = .today; reload(.today)
        case .yesterday: choice = .yesterday; reload(.yesterday)
        case .pick: pickingDates = true
        }
    }

    private func reload(_ range: LedgerRange) {
        store.range = range
        store.ledgerLoaded = false
        selectedId = nil
        Task { await store.loadLedger() }
    }

    /// "2 tables waiting: Table 4 ₹3,420 · Table 9 ₹2,210", each a way into the Till
    @ViewBuilder
    private var waitingStrip: some View {
        let asked = store.till.filter { $0.state == "bill" }
        let shown = asked.isEmpty ? Array(store.till.prefix(3)) : Array(asked.prefix(4))
        if !shown.isEmpty, let config = store.config {
            let count = asked.isEmpty ? store.till.count : asked.count
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(SN.amber).frame(width: 8, height: 8)
                    Text(asked.isEmpty
                         ? "\(count) waiting to pay"
                         : "\(count) table\(count == 1 ? "" : "s") asked for the bill")
                        .font(.subheadline.weight(.semibold))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shown) { bill in
                            let total = BillMath.computeBill(gst: bill.gross.gst, vat: bill.gross.vat, discount: 0, config: config).total
                            Button("\(bill.title) \(total.rupees)") { openTill(bill.key) }
                                .buttonStyle(QuietButtonStyle())
                                .monospacedDigit()
                                .accessibilityHint("Opens the bill in the till")
                                .accessibilityIdentifier("ledger-waiting-\(bill.tileText)")
                        }
                        if count > shown.count {
                            Button("+\(count - shown.count) more") { mode = .waiting }
                                .buttonStyle(QuietButtonStyle())
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SN.amber.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SN.amber.opacity(0.6), lineWidth: 1))
        }
    }

    // MARK: Detail (wide)

    @ViewBuilder
    private func detailPanel(index: LocalBillIndex) -> some View {
        if let bill = filtered.first(where: { $0.id == selectedId }) ?? filtered.first {
            ScrollView {
                LedgerDetailContent(store: store, bill: bill, local: index.bill(for: bill), path: $path)
                    .padding(DesignTokens.spacingXL)
            }
            .id(bill.id)
        } else {
            Text("Choose a bill").foregroundStyle(SN.mut).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Waiter", selection: $waiter) {
                    Text("Every waiter").tag(String?.none)
                    ForEach(waiters, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                Picker("Method", selection: $method) {
                    Text("Every method").tag(String?.none)
                    ForEach(methods, id: \.self) { Text(PayMethod.name($0)).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                Toggle("Unpaid only", isOn: $unpaidOnly)
                Toggle("From the Bill Generator", isOn: $appOnly)
                if filtersOn {
                    Divider()
                    Button("Clear filters", systemImage: "xmark.circle") {
                        waiter = nil; method = nil; unpaidOnly = false; appOnly = false
                    }
                }
            } label: {
                Label("Filter", systemImage: filtersOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityIdentifier("ledger-filter")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await syncDevice(silent: false) }
                } label: {
                    Label(unsyncedCount > 0 ? "Sync All Unsynced (\(unsyncedCount))" : "Sync All Unsynced",
                          systemImage: "icloud.and.arrow.up")
                }
                .disabled(uploader?.isUploading ?? false)
                Button {
                    Task { await refreshDeviceCopies() }
                } label: {
                    Label("Fetch Bill Generator bills", systemImage: "icloud.and.arrow.down")
                }
            } label: {
                if uploader?.isUploading == true || uploader?.isDownloading == true {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sync", systemImage: unsyncedCount > 0 ? "exclamationmark.icloud" : "icloud")
                }
            }
            .accessibilityIdentifier("ledger-sync-menu")
        }
    }

    private var datesSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $pickFrom, in: ...Date(), displayedComponents: .date)
                DatePicker("To", selection: $pickTo, in: pickFrom...max(pickFrom, Date()), displayedComponents: .date)
            }
            .navigationTitle("Pick dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingDates = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") {
                        pickingDates = false
                        choice = .pick
                        reload(.custom(from: pickFrom, to: max(pickFrom, pickTo)))
                    }
                    .accessibilityIdentifier("ledger-dates-show")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Device bills

    private func syncDevice(silent: Bool) async {
        guard let uploader else { return }
        do {
            let summary = try await uploader.syncAllUnsynced(in: modelContext)
            if !silent || summary.attempted > 0 {
                syncMessage = summary.attempted == 0
                    ? "Every bill on this device is uploaded."
                    : "\(summary.succeeded.count) of \(summary.attempted) bills uploaded.\(summary.failed.isEmpty ? "" : " \(summary.failed.count) failed.")"
            }
            if summary.attempted > 0 { await store.loadLedger() }
        } catch {
            if !silent { syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func upload(_ bills: [BillHistoryItem]) async {
        guard let uploader else { return }
        do {
            try await uploader.uploadMany(bills)
            try? modelContext.save()
            await store.loadLedger()
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The latest Bill Generator bills from the server into this device
    private func refreshDeviceCopies() async {
        guard let uploader, !uploader.isDownloading else { return }
        _ = try? await uploader.downloadPage(cursor: nil, into: modelContext, pageSize: 50)
    }

    private func markPaid(_ bill: BillHistoryItem, _ status: BillHistoryItemStatus) {
        Task {
            if let message = await AppBillPayment.set(bill, status, uploader: uploader, context: modelContext) {
                syncMessage = message
            }
            await store.loadLedger()
        }
    }
}

// MARK: - Changing a Bill Generator bill's payment

@MainActor
enum AppBillPayment {
    /// Mark the device's copy paid (or change its method) and upload it; the
    /// change is rolled back if the upload fails. Returns the error to show.
    static func set(_ bill: BillHistoryItem, _ status: BillHistoryItemStatus,
                    uploader: BillUploader?, context: ModelContext) async -> String? {
        guard bill.paymentStatus != status else { return nil }
        let previous = bill.paymentStatus
        bill.paymentStatus = status
        bill.syncedAt = nil
        try? context.save()
        guard let uploader else { return nil }
        do {
            try await uploader.uploadOne(bill)
            try? context.save()
            return nil
        } catch {
            bill.paymentStatus = previous
            try? context.save()
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Cash / UPI / Card, for marking a Bill Generator bill paid
struct MarkPaidMenu: View {
    let title: String
    let choose: (BillHistoryItemStatus) -> Void
    var body: some View {
        Menu {
            Button("Cash", systemImage: "banknote") { choose(.paidByCash) }
            Button("UPI", systemImage: "qrcode") { choose(.paidByUPI) }
            Button("Card", systemImage: "creditcard") { choose(.paidByCard) }
        } label: {
            Label(title, systemImage: "checkmark.circle")
        }
    }
}

extension BillHistoryItem {
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return ["table \(tableNumber)", waiter, customerName ?? ""].contains { $0.lowercased().contains(q) }
            || items.contains { $0.name.lowercased().contains(q) }
    }
}

// MARK: - Summary

struct LedgerSummaryCards: View {
    let summary: LedgerSummary
    let wide: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            card("Takings · \(summary.bills) bill\(summary.bills == 1 ? "" : "s")", summary.takings.rupees, id: "ledger-takings")
            card("Cash · UPI · Card",
                 [summary.amount(for: "CASH"), summary.amount(for: "UPI"), summary.amount(for: "CARD")].map(\.rupees).joined(separator: " · "),
                 small: true)
            card("GST · VAT", "\(summary.gstTax.rupees) · \(summary.vatTax.rupees)", small: true)
            if summary.unpaid > 0 && !wide {
                card("Unpaid", "\(summary.unpaid)", tint: SN.red)
            } else {
                card("Discounts", summary.discount.rupees)
            }
        }
    }

    private func card(_ label: String, _ value: String, small: Bool = false, tint: Color = SN.ink, id: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundStyle(SN.mut)
            Text(value)
                .font(small ? .headline.monospacedDigit() : .title2.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier(id ?? "")
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SN.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SN.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

private enum LedgerColumns {
    static let bill: CGFloat = 76
    static let time: CGFloat = 86
    static let waiter: CGFloat = 110
    static let paid: CGFloat = 120
    static let amount: CGFloat = 96
}

private struct LedgerHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            PanelLabel(text: "Bill").frame(width: LedgerColumns.bill, alignment: .leading)
            PanelLabel(text: "Time").frame(width: LedgerColumns.time, alignment: .leading)
            PanelLabel(text: "Where").frame(maxWidth: .infinity, alignment: .leading)
            PanelLabel(text: "Waiter").frame(width: LedgerColumns.waiter, alignment: .leading)
            PanelLabel(text: "Paid by").frame(width: LedgerColumns.paid, alignment: .leading)
            PanelLabel(text: "Amount").frame(width: LedgerColumns.amount, alignment: .trailing)
        }
        .listRowBackground(Color.clear)
        .accessibilityHidden(true)
    }
}

struct LedgerRow: View {
    let bill: LedgerBill
    let wide: Bool
    /// A Bill Generator bill changed on this device and not uploaded yet
    let unsynced: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var time: String { bill.date?.formatted(date: .omitted, time: .shortened) ?? "" }
    private var whereText: String { bill.fromApp ? "\(bill.where) · app" : bill.where }

    var body: some View {
        Group {
            if wide && !typeSize.isAccessibilitySize {
                HStack(spacing: 8) {
                    Text("#\(bill.billNo)").font(.subheadline.monospacedDigit())
                        .frame(width: LedgerColumns.bill, alignment: .leading)
                    Text(time).font(.subheadline.monospacedDigit())
                        .frame(width: LedgerColumns.time, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(whereText).font(.subheadline)
                        if unsynced { syncMark }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(bill.waiter ?? "—").font(.subheadline)
                        .frame(width: LedgerColumns.waiter, alignment: .leading)
                    MethodPills(bill: bill).frame(width: LedgerColumns.paid, alignment: .leading)
                    Text(bill.total.rupees).font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: LedgerColumns.amount, alignment: .trailing)
                }
                .lineLimit(1)
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(whereText).font(.headline)
                            if unsynced { syncMark }
                        }
                        Text(["#\(bill.billNo)", time, bill.waiter ?? bill.customer].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(SN.mut)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(bill.total.rupees).font(.headline.monospacedDigit())
                        MethodPills(bill: bill)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var syncMark: some View {
        Image(systemName: "icloud.and.arrow.up")
            .font(.caption)
            .foregroundStyle(SN.amber)
            .accessibilityLabel("Not uploaded")
    }

    /// "Bill 7431, Table 12, ₹1,770, paid by UPI, 9:42 PM, Pedro"
    private var accessibilityText: String {
        var parts = ["Bill \(bill.billNo)", whereText, bill.total.rupees]
        parts.append(bill.paid ? "paid by \(bill.paidBy ?? "—")" : "unpaid")
        parts.append(time)
        if let w = bill.waiter { parts.append(w) }
        if unsynced { parts.append("not uploaded") }
        return parts.joined(separator: ", ")
    }
}

/// "UPI", "Cash + UPI", or "Unpaid" in red
struct MethodPills: View {
    let bill: LedgerBill
    var body: some View {
        if !bill.paid {
            pill("Unpaid", SN.red)
        } else if bill.tenders.count > 1 {
            pill(bill.tenders.map { PayMethod.name($0.method) }.joined(separator: " + "), SN.ink)
        } else if let t = bill.tenders.first {
            pill(PayMethod.name(t.method), PayMethod.color(t.method))
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.08)))
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
    }
}

/// A Bill Generator bill not on the server yet, with Upload
private struct NotUploadedRow: View {
    let bill: BillHistoryItem
    let upload: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(bill.tableNumber == 0 ? "Parcel · app" : "Table \(bill.tableNumber) · app").font(.headline)
                Text([bill.date.formatted(date: .omitted, time: .shortened), bill.waiter].joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(SN.mut)
            }
            Spacer()
            // The bill's total after any discount, as on its detail
            Text(bill.totalAmount.rupees).font(.headline.monospacedDigit())
            Button(action: upload) {
                Image(systemName: "icloud.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(SN.amber)
            .accessibilityLabel("Upload")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BillHistoryList-Item-\(bill.id.uuidString)")
    }
}

// MARK: - One bill

/// iPhone: a bill from the ledger as its own screen
struct LedgerDetailScreen: View {
    let store: TillStore
    let bill: LedgerBill
    @Binding var path: [BillingRoute]
    @Query(sort: \BillHistoryItem.date, order: .reverse) private var appBills: [BillHistoryItem]

    var body: some View {
        // The list may have reloaded since: show the bill as it is now
        let current = store.ledger.first { $0.id == bill.id } ?? bill
        ScrollView {
            LedgerDetailContent(store: store, bill: current,
                                local: bill.fromApp ? LocalBillIndex(appBills).bill(for: current) : nil, path: $path)
                .padding(DesignTokens.spacingL)
        }
        .background(SN.page)
        .navigationTitle("Bill #\(bill.billNo)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LedgerDetailContent: View {
    let store: TillStore
    let bill: LedgerBill
    /// The device's copy of a Bill Generator bill
    let local: BillHistoryItem?
    @Binding var path: [BillingRoute]

    @Environment(Session.self) private var session
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var menuLoader: MenuLoader
    @State private var receipt: PaidReceipt?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var uploader: BillUploader?

    private var canCorrect: Bool { ["ADMIN", "CASHIER"].contains(session.user?.role.uppercased() ?? "") }
    private var config: BillingConfig { store.config ?? menuLoader.billingConfig }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    PanelLabel(text: heading).lineLimit(2)
                    Text("\(bill.where) · \(bill.total.rupees)")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                MethodPills(bill: bill)
            }
            if let customer = bill.customer {
                Label(customer, systemImage: "person").font(.subheadline).foregroundStyle(SN.mut)
            }
            PayBillTotals(amounts: bill.amounts, config: config, totalLabel: bill.paid ? "Paid" : "To pay")
            if bill.tenders.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    PanelLabel(text: "Paid in parts")
                    ForEach(bill.tenders, id: \.self) { t in
                        HStack {
                            Text(PayMethod.name(t.method))
                            Spacer()
                            Text(t.amount.rupees).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
            actions
            Text(bill.fromApp
                 ? "Made in the Bill Generator\(local == nil ? " on another device" : ""). Every change is kept in the bill's history."
                 : "Every change is kept in the bill's history with who made it.")
                .font(.footnote)
                .foregroundStyle(SN.mut)
        }
        .alert("Bill", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $receipt) { r in
            PaidReceiptSheet(receipt: r, config: config, identity: menuLoader.identity)
        }
        .task { if uploader == nil { uploader = BillUploader(session: session) } }
    }

    private var heading: String {
        var parts = ["Bill \(bill.billNo)"]
        let time = bill.date?.formatted(date: .omitted, time: .shortened) ?? ""
        parts.append(bill.paid ? "paid \(time)" : "made \(time)")
        if let w = bill.waiter { parts.append(w) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
            Button {
                Task { await openReceipt() }
            } label: {
                if working { ProgressView() } else { Label("Print / share", systemImage: "printer") }
            }
            .buttonStyle(POSActionStyle())
            .disabled(working)
            .accessibilityIdentifier("ledger-receipt")

            if bill.paid && canCorrect {
                Menu {
                    ForEach(PayMethod.correctable, id: \.self) { m in
                        Button {
                            Task { await change(to: m) }
                        } label: {
                            if bill.tenders.count == 1, bill.tenders.first?.method == m { Label(PayMethod.name(m), systemImage: "checkmark") }
                            else { Text(PayMethod.name(m)) }
                        }
                        .disabled(bill.fromApp && local != nil && PayMethod.appStatus(m) == nil)
                    }
                } label: {
                    Label("Change method", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(POSActionStyle())
                .disabled(working)
                .accessibilityIdentifier("ledger-change-method")
            }

            if !bill.paid, let local {
                MarkPaidMenu(title: "Mark paid") { status in
                    Task { await setApp(local, status) }
                }
                .buttonStyle(POSActionStyle(kind: .prominent))
                .disabled(working)
                .accessibilityIdentifier("ledger-mark-paid")
            }

            if bill.fromApp, let local {
                Button {
                    path.append(.appBill(local.id))
                } label: {
                    Label("Open bill", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(POSActionStyle())
                .accessibilityHint("Discount, payment and Regenerate in the Bill Generator")
                .accessibilityIdentifier("ledger-open-app-bill")
            }
        }
    }

    private func openReceipt() async {
        working = true
        defer { working = false }
        do {
            let items: [MenuItem]
            if let local { items = local.items } else { items = try await store.receiptItems(for: bill) }
            receipt = PaidReceipt(items: items, tableNumber: bill.tableNumber, bill: SettledBill(bill.amounts),
                                  paidBy: bill.paidBy)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func change(to method: String) async {
        working = true
        defer { working = false }
        // A Bill Generator bill is changed on the device and uploaded, so a
        // later upload of the device's copy doesn't undo it
        if bill.fromApp, let local, let status = PayMethod.appStatus(method) {
            await setApp(local, status)
            return
        }
        do {
            try await store.changeMethod(of: bill, to: method)
        } catch {
            // 409 for a split bill: the server says why
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setApp(_ local: BillHistoryItem, _ status: BillHistoryItemStatus) async {
        working = true
        defer { working = false }
        if let message = await AppBillPayment.set(local, status, uploader: uploader, context: modelContext) {
            errorMessage = message
        }
        await store.loadLedger()
    }
}

// MARK: - Waiters: the Bill Generator's bills

/// For waiters, who don't see the day's takings: the Bill Generator's bills
/// (this device's, and the server's via GET /api/bills), as the old bill
/// history, each opening its detail (payment, Regenerate)
struct AppBillsList: View {
    @Binding var mode: BillingMode
    @Environment(Session.self) private var session
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BillHistoryItem.date, order: .reverse) private var bills: [BillHistoryItem]

    @State private var uploader: BillUploader?
    @State private var cursor: String?
    @State private var hasMore = true
    @State private var loading = false
    @State private var search = ""
    @State private var todayOnly = false
    @State private var pendingOnly = false
    @State private var message: String?

    private var shown: [BillHistoryItem] {
        let start = Calendar.current.startOfDay(for: Date())
        return bills.filter { b in
            if todayOnly && b.date < start { return false }
            if pendingOnly && b.paymentStatus != .pending { return false }
            return b.matches(search)
        }
    }

    var body: some View {
        List {
            ForEach(shown) { bill in
                NavigationLink(value: BillingRoute.appBill(bill.id)) {
                    AppBillRow(bill: bill)
                }
                .listRowBackground(SN.panel)
                .onAppear { if bill.id == shown.last?.id { Task { await loadPage(more: true) } } }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            } else if shown.isEmpty {
                ContentUnavailableView("No bills", systemImage: "doc.text",
                                       description: Text("Bills made in the Bill Generator show up here."))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            BillingModePicker(mode: $mode)
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.vertical, DesignTokens.spacingS)
                .background(SN.page)
        }
        #if os(iOS)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Table, waiter, customer, dish")
        #else
        .searchable(text: $search, prompt: "Table, waiter, customer, dish")
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Today only", isOn: $todayOnly)
                    Toggle("Pending only", isOn: $pendingOnly)
                    Divider()
                    Button("Sync All Unsynced", systemImage: "icloud.and.arrow.up") { Task { await sync() } }
                        .disabled(uploader?.isUploading ?? false)
                } label: {
                    Label("Filter and sync", systemImage: todayOnly || pendingOnly
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("app-bills-menu")
            }
        }
        .refreshable { await loadPage(more: false) }
        .alert("Bills", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .task {
            if uploader == nil { uploader = BillUploader(session: session) }
            await loadPage(more: false)
            if let uploader { _ = try? await uploader.syncAllUnsynced(in: modelContext) }
        }
    }

    private func loadPage(more: Bool) async {
        guard let uploader, !loading, !more || hasMore else { return }
        loading = true
        defer { loading = false }
        if let page = try? await uploader.downloadPage(cursor: more ? cursor : nil, into: modelContext, pageSize: 50) {
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
        }
    }

    private func sync() async {
        guard let uploader else { return }
        do {
            let s = try await uploader.syncAllUnsynced(in: modelContext)
            message = s.attempted == 0 ? "Every bill on this device is uploaded."
                : "\(s.succeeded.count) of \(s.attempted) bills uploaded.\(s.failed.isEmpty ? "" : " \(s.failed.count) failed.")"
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct AppBillRow: View {
    let bill: BillHistoryItem
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(bill.tableNumber == 0 ? "Parcel" : "Table \(bill.tableNumber)").font(.headline)
                    if bill.syncedAt == nil {
                        Image(systemName: "icloud.and.arrow.up").font(.caption).foregroundStyle(SN.amber)
                            .accessibilityLabel("Not uploaded")
                    }
                }
                Text([bill.date.formatted(date: .abbreviated, time: .shortened), bill.waiter].joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(SN.mut)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                // The bill's total after any discount, as on its detail
                Text(bill.totalAmount.rupees).font(.headline.monospacedDigit())
                let method = PayMethod.from(appStatus: bill.paymentStatus)
                Text(method.map(PayMethod.name) ?? "Unpaid")
                    .font(.caption.monospaced().weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(method.map(PayMethod.color) ?? SN.red)
                    .overlay(Capsule().stroke((method.map(PayMethod.color) ?? SN.red).opacity(0.6), lineWidth: 1))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BillHistoryList-Item-\(bill.id.uuidString)")
    }
}
