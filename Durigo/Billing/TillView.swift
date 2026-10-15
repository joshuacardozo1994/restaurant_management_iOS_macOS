//
//  TillView.swift
//  Durigo
//
//  The Billing tab ("Till"): who is waiting to pay, the selected bill, and the
//  pay pad; "Bills" (the ledger) one segment away.
//
//  Layout follows the width it is given: three columns (queue · bill · pad)
//  on a wide iPad or the Mac, queue + bill-and-pad on an iPad in portrait or
//  beside the sidebar, and on an iPhone the queue is the screen and a bill
//  pushes its own screen with the pad under it.
//

import SwiftUI
import SwiftData

enum BillingMode: Hashable {
    case waiting
    /// The ledger: admins and cashiers only (the server refuses others)
    case bills
    /// Waiters: the Bill Generator's bills, as the old bill history
    case appBills
}

extension Session {
    /// Admins and cashiers see the day's bills (GET /api/billing/ledger)
    var seesLedger: Bool { ["ADMIN", "CASHIER"].contains(user?.role.uppercased() ?? "") }
}

enum BillingRoute: Hashable {
    /// A bill waiting to be paid (by its key)
    case till(String)
    /// A bill in the ledger
    case ledger(LedgerBill)
    /// A Bill Generator bill on this device (by its id)
    case appBill(UUID)
}

/// One draft per bill, so switching between bills keeps what was chosen
@MainActor
final class PayDraftBook {
    private var drafts: [String: PayDraft] = [:]
    func draft(for key: String) -> PayDraft {
        if let d = drafts[key] { return d }
        let d = PayDraft()
        drafts[key] = d
        return d
    }
    func reset(_ key: String) { drafts[key] = nil }
}

struct BillingView: View {
    @Environment(Session.self) private var session
    @EnvironmentObject private var menuLoader: MenuLoader
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: TillStore?
    @State private var mode: BillingMode = .waiting
    @State private var path: [BillingRoute] = []
    /// The bill in the middle column (wide layouts)
    @State private var selectedKey: String?
    @State private var drafts = PayDraftBook()
    @State private var payingKey: String?
    @State private var receipt: PaidReceipt?
    @State private var errorMessage: String?
    @State private var layoutWidth: CGFloat = 0

    static let wideWidth: CGFloat = 900
    static let mediumWidth: CGFloat = 600

    private var role: String { session.user?.role.uppercased() ?? "" }
    private var canDiscount: Bool { ["ADMIN", "CASHIER"].contains(role) }
    private var config: BillingConfig { store?.config ?? menuLoader.billingConfig }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                Group {
                    if let store, store.tillLoaded || mode != .waiting {
                        switch mode {
                        case .waiting: till(store: store, width: geo.size.width)
                        case .bills where session.seesLedger:
                            LedgerView(store: store, mode: $mode, width: geo.size.width, path: $path,
                                       openTill: openTill)
                        case .bills, .appBills:
                            AppBillsList(mode: $mode)
                        }
                    } else {
                        // Loading: the till with sample bills, as placeholders
                        till(store: .placeholder(session: session), width: geo.size.width, loading: true)
                    }
                }
                .onAppear { layoutWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in layoutWidth = w }
            }
            .background(SN.page)
            .foregroundStyle(SN.ink)
            .navigationTitle(mode == .waiting ? "Till" : mode == .bills ? "Bills" : "Bill Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LiveBadgeItem(isLive: store?.isLive ?? false)
            }
            .navigationDestination(for: BillingRoute.self) { route in
                if let store { destination(route, store: store) }
            }
            .alert("Couldn't take the payment", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $receipt, onDismiss: afterReceipt) { paid in
                PaidReceiptSheet(receipt: paid, config: config, identity: menuLoader.identity)
            }
        }
        .task(id: session.isSignedIn) {
            guard session.isSignedIn else { return }
            if store == nil { store = TillStore(session: session) }
            await store?.loadTill()
            store?.startLive()
        }
        .onDisappear { store?.stopLive() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store?.startLive() } else if phase == .background { store?.stopLive() }
        }
        .onChange(of: mode) { _, m in store?.watchingLedger = m == .bills && session.seesLedger }
        .lockWithBiometric()
    }

    @ViewBuilder
    private func destination(_ route: BillingRoute, store: TillStore) -> some View {
        switch route {
        case .till(let key):
            if let bill = store.bill(key: key) {
                TillPhoneBillScreen(bill: bill, draft: drafts.draft(for: key), config: config,
                                    canDiscount: canDiscount, paying: payingKey == key,
                                    applyCode: { applyCode($0, bill: bill) },
                                    pay: { amounts in pay(bill, amounts: amounts) },
                                    printBill: { amounts in printBill(bill, amounts: amounts) })
            } else {
                ContentUnavailableView("Paid", systemImage: "checkmark.circle",
                                       description: Text("This bill isn't waiting any more."))
            }
        case .ledger(let bill):
            LedgerDetailScreen(store: store, bill: bill, path: $path)
        case .appBill(let id):
            AppBillDestination(id: id)
        }
    }

    // MARK: Till layouts

    /// `loading`: a skeleton of sample bills, with the mode picker still live
    @ViewBuilder
    private func till(store: TillStore, width: CGFloat, loading: Bool = false) -> some View {
        if width >= Self.wideWidth {
            HStack(spacing: 0) {
                queueColumn(store: store, selectable: true, loading: loading)
                    .frame(width: min(340, width * 0.28))
                Rectangle().fill(SN.line).frame(width: 1)
                if let bill = selectedBill(store) {
                    ScrollView {
                        TillBillColumn(bill: bill, amounts: amounts(bill), config: config,
                                       discountLabel: drafts.draft(for: bill.key).discountLabel,
                                       printBill: { printBill(bill, amounts: amounts(bill)) })
                            .padding(DesignTokens.spacingXL)
                    }
                    .frame(maxWidth: .infinity)
                    .skeleton(loading)
                    Rectangle().fill(SN.line).frame(width: 1)
                    ScrollView {
                        padStack(bill)
                            .padding(DesignTokens.spacingXL)
                    }
                    .frame(width: min(400, width * 0.33))
                    .background(SN.panel, ignoresSafeAreaEdges: [])
                    .skeleton(loading)
                    .id(bill.key)
                } else {
                    emptyDetail(store).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if width >= Self.mediumWidth {
            HStack(spacing: 0) {
                queueColumn(store: store, selectable: true, loading: loading)
                    .frame(width: min(320, width * 0.42))
                Rectangle().fill(SN.line).frame(width: 1)
                if let bill = selectedBill(store) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignTokens.spacingXL) {
                            TillBillColumn(bill: bill, amounts: amounts(bill), config: config,
                                           discountLabel: drafts.draft(for: bill.key).discountLabel,
                                           printBill: { printBill(bill, amounts: amounts(bill)) })
                            Rectangle().fill(SN.line).frame(height: 1)
                            padStack(bill)
                        }
                        .padding(DesignTokens.spacingL)
                    }
                    .frame(maxWidth: .infinity)
                    .skeleton(loading)
                    .id(bill.key)
                } else {
                    emptyDetail(store).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            queueColumn(store: store, selectable: false, loading: loading)
        }
    }

    private func padStack(_ bill: TillBill) -> some View {
        let draft = drafts.draft(for: bill.key)
        let a = amounts(bill)
        return VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            PayPadControls(draft: draft, amounts: a, canDiscount: canDiscount) { applyCode($0, bill: bill) }
            PayButton(draft: draft, total: a.total, submitting: payingKey == bill.key) { pay(bill, amounts: a) }
            Text("The receipt opens next, ready to print or share")
                .font(.footnote)
                .foregroundStyle(SN.mut)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private func amounts(_ bill: TillBill) -> BillAmounts {
        let g = bill.gross
        return drafts.draft(for: bill.key).amounts(gst: g.gst, vat: g.vat, config: config, discountAllowed: canDiscount)
    }

    /// The chosen bill, or the first one waiting
    private func selectedBill(_ store: TillStore) -> TillBill? {
        selectedKey.flatMap(store.bill(key:)) ?? store.till.first
    }

    @ViewBuilder
    private func emptyDetail(_ store: TillStore) -> some View {
        if store.till.isEmpty {
            Color.clear
        } else {
            Text("Choose a bill").foregroundStyle(SN.mut)
        }
    }

    // MARK: Queue

    @ViewBuilder
    private func queueColumn(store: TillStore, selectable: Bool, loading: Bool = false) -> some View {
        let current = selectable ? selectedBill(store)?.key : nil
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            List {
                Section {
                    if store.till.isEmpty {
                        emptyQueue(store)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(store.till) { bill in
                        let amount = BillMath.computeBill(gst: bill.gross.gst, vat: bill.gross.vat, discount: 0, config: config).total
                        let row = TillQueueRow(bill: bill, amount: amount, now: tl.date, selected: current == bill.key)
                        Group {
                            if selectable {
                                Button { selectedKey = bill.key } label: { row }
                                    .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: BillingRoute.till(bill.key)) { row }
                            }
                        }
                        .skeleton(loading)
                        .listRowBackground(selectable ? Color.clear : SN.panel)
                        .listRowSeparator(selectable ? .hidden : .visible)
                        .listRowInsets(selectable ? EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12) : nil)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Waiting to pay")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(SN.ink)
                            .textCase(nil)
                        Spacer()
                        Text("\(store.till.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(SN.mut)
                            .accessibilityLabel("\(store.till.count) waiting")
                    }
                    .skeleton(loading)
                }
                if let msg = store.tillError {
                    Section {
                        Label("Showing the last list: \(msg)", systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(SN.red)
                    }
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
            .refreshable { await store.loadTill() }
        }
    }

    /// Only once loaded: until then the whole till is a skeleton
    private func emptyQueue(_ store: TillStore) -> some View {
        ContentUnavailableView("Nothing waiting to be paid", systemImage: "checkmark.circle",
                               description: Text("Tables and takeaways show up here as soon as they order."))
            .accessibilityIdentifier("till-empty")
    }

    // MARK: Actions

    private func openTill(_ key: String) {
        mode = .waiting
        selectedKey = key
        path = isCompact ? [.till(key)] : []
    }

    /// iPhone (and narrow windows): a bill is its own screen
    private var isCompact: Bool { layoutWidth > 0 && layoutWidth < Self.mediumWidth }

    private func applyCode(_ text: String, bill: TillBill) {
        guard let store else { return }
        let draft = drafts.draft(for: bill.key)
        let code = text.trimmingCharacters(in: .whitespaces).uppercased()
        let g = bill.gross
        Task {
            draft.checkingCode = true
            defer { draft.checkingCode = false }
            do {
                let amount = try await store.discountCodeValue(code: code, orderTotal: g.gst + g.vat)
                draft.appliedCode = .init(code: code, amount: amount)
                draft.discountText = ""
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func pay(_ bill: TillBill, amounts: BillAmounts) {
        guard let store else { return }
        let draft = drafts.draft(for: bill.key)
        guard let body = draft.paymentBody(amounts: amounts) else { return }
        // What's being paid for, captured before the bill leaves the till:
        // every order of the table
        let items = bill.receiptItems
        let paidBy = draft.paidBy
        Task {
            payingKey = bill.key
            defer { payingKey = nil }
            do {
                let settled = try await store.pay(bill, body)
                drafts.reset(bill.key)
                if selectedKey == bill.key { selectedKey = nil }
                receipt = PaidReceipt(items: items, tableNumber: bill.tableNumber, bill: settled, paidBy: paidBy)
            } catch let APIError.server(code, body) where code == 409 {
                await store.loadTill()  // show the bill as it is now
                errorMessage = APIError.server(code: code, body: body).localizedDescription
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func printBill(_ bill: TillBill, amounts: BillAmounts) {
        receipt = PaidReceipt(items: bill.receiptItems, tableNumber: bill.tableNumber,
                              bill: SettledBill(amounts), paidBy: nil, preBill: true)
    }

    /// Back to the queue once a bill is paid (iPhone)
    private func afterReceipt() {
        if case .till(let key)? = path.last, store?.bill(key: key) == nil { path.removeLast() }
    }
}

// MARK: - Waiting / Bills

struct BillingModePicker: View {
    @Binding var mode: BillingMode
    @Environment(Session.self) private var session
    var body: some View {
        Picker("Show", selection: $mode) {
            Text("Waiting").tag(BillingMode.waiting)
            if session.seesLedger {
                Text("Bills").tag(BillingMode.bills)
            } else {
                Text("Bill Generator").tag(BillingMode.appBills)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("billing-mode")
    }
}

// MARK: - Queue row

struct TillQueueRow: View {
    let bill: TillBill
    let amount: Int
    let now: Date
    let selected: Bool
    @ScaledMetric(relativeTo: .headline) private var tileSize: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 12) {
            Text(bill.tileText)
                .font(.headline.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: tileSize, height: tileSize)
                .background(shape.fill(TileLook.fill(bill.tileStatus)))
                .overlay(shape.strokeBorder(TileLook.stroke(bill.tileStatus), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.title).font(.headline)
                Text(bill.subtitle(now: now))
                    .font(.subheadline)
                    .foregroundStyle(bill.state == "bill" ? SN.amber : SN.mut)
            }
            Spacer(minLength: 8)
            Text(amount.rupees)
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, selected ? 10 : 0)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SN.panel)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SN.teal, lineWidth: 2))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("till-row-\(bill.tableNumber.map(String.init) ?? bill.anchorOrderId)")
    }

    /// "Table 12, ₹1,770, all served, Pedro"
    private var accessibilityText: String {
        var parts = [bill.title, amount.rupees]
        switch bill.state {
        case "bill":
            parts.append("asked for the bill" + ((bill.askedDate ?? bill.sinceDate).map { " \(POSTime.elapsed(since: $0, now: now)) ago" } ?? ""))
        case "served": parts.append("all served")
        default: parts.append("\(bill.cookingCount) dishes cooking")
        }
        if let waiter = bill.waiter { parts.append(waiter) }
        if let customer = bill.customer { parts.append(customer.name) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The selected bill

/// "BILL 7431 · PEDRO · SEATED 52M · 2 ORDERS", the table, every line and the totals
struct TillBillColumn: View {
    let bill: TillBill
    let amounts: BillAmounts
    let config: BillingConfig
    let discountLabel: String
    let printBill: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                HStack(alignment: .top) {
                    TillBillHeading(bill: bill, now: tl.date)
                    Spacer()
                    Button("Print bill", action: printBill)
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityLabel("Print the bill before paying")
                        .accessibilityIdentifier("till-print-bill")
                }
                TillLines(lines: bill.lines)
                PayBillTotals(amounts: amounts, config: config, discountLabel: discountLabel)
            }
        }
    }
}

struct TillBillHeading: View {
    let bill: TillBill
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelLabel(text: headline)
                .lineLimit(2)
            Text(bill.title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var headline: String {
        var parts: [String] = []
        if let n = bill.billNumber { parts.append("Bill \(n)") }
        if let waiter = bill.waiter { parts.append(waiter) }
        if let customer = bill.customer { parts.append(customer.name) }
        if let since = bill.sinceDate { parts.append("seated \(POSTime.elapsed(since: since, now: now))") }
        let n = bill.orderIds.count
        parts.append("\(n) order\(n == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

/// The bill's lines in a card, each dot coloured by where the dish is
struct TillLines: View {
    let lines: [TillBill.Line]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { Rectangle().fill(SN.line).frame(height: 1) }
                POSBillLine(color: DishStage(itemStatus: line.status).color, quantity: Int(line.quantity.rounded()),
                            name: line.name, note: line.notes, amount: line.unitPrice * line.quantity)
            }
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).fill(SN.panel))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium, style: .continuous).stroke(SN.line, lineWidth: 1))
    }
}

// MARK: - iPhone: one bill and the pad

struct TillPhoneBillScreen: View {
    let bill: TillBill
    let draft: PayDraft
    let config: BillingConfig
    let canDiscount: Bool
    let paying: Bool
    let applyCode: (String) -> Void
    let pay: (BillAmounts) -> Void
    let printBill: (BillAmounts) -> Void

    @State private var expanded = false
    private static let shownLines = 3

    var body: some View {
        let g = bill.gross
        let amounts = draft.amounts(gst: g.gst, vat: g.vat, config: config, discountAllowed: canDiscount)
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingXL) {
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    TillBillHeading(bill: bill, now: tl.date)
                }
                summary(amounts)
                PayPadControls(draft: draft, amounts: amounts, canDiscount: canDiscount, applyCode: applyCode)
            }
            .padding(DesignTokens.spacingL)
        }
        .background(SN.page)
        .safeAreaInset(edge: .bottom) {
            PayButton(draft: draft, total: amounts.total, submitting: paying) { pay(amounts) }
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.vertical, DesignTokens.spacingS)
                .background(.bar)
        }
        .navigationTitle(bill.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { printBill(amounts) } label: { Label("Print bill", systemImage: "printer") }
                    .accessibilityIdentifier("till-print-bill")
            }
        }
    }

    /// The first lines and "+N more"; tap for every line and the tax
    @ViewBuilder
    private func summary(_ amounts: BillAmounts) -> some View {
        let hidden = bill.lines.count - Self.shownLines
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            if expanded || hidden <= 0 {
                TillLines(lines: bill.lines)
            } else {
                TillLines(lines: Array(bill.lines.prefix(Self.shownLines)))
            }
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    Text(expanded ? "Fewer details"
                         : hidden > 0 ? "+\(hidden) more · CGST, SGST, VAT included" : "Tax details")
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.subheadline)
                .foregroundStyle(SN.mut)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("till-expand")
            if expanded {
                PayBillTotals(amounts: amounts, config: config, discountLabel: draft.discountLabel, totalLabel: "Total")
            }
        }
    }
}

// MARK: - A Bill Generator bill on this device

/// The existing Bill Generator detail (mark paid, discount, regenerate)
struct AppBillDestination: View {
    @Query private var bills: [BillHistoryItem]

    init(id: UUID) {
        _bills = Query(filter: #Predicate<BillHistoryItem> { $0.id == id })
    }

    var body: some View {
        if let bill = bills.first {
            BillHistory(billHistoryItem: bill)
        } else {
            ContentUnavailableView("Not on this device", systemImage: "iphone.slash",
                                   description: Text("This bill was made on another device."))
        }
    }
}
