//
//  BillHistoryList.swift
//  Durigo
//
//  Server-driven, infinite-scroll bill history with SwiftData as a local
//  cache (so the list stays usable offline). Each row matches the web app's
//  card-based design language.
//
//  Architecture:
//   - SwiftData = display source. List binds to BillHistoryItem rows.
//   - On view appear: fetch first page from /api/bills → upsert into SwiftData
//   - On scroll near bottom of cached list: fetch next page (cursor-based)
//   - On pull-to-refresh: reset cursor + re-fetch first page
//   - On scenePhase active: also pushes any local-only bills (syncedAt == nil)
//   - Live: SSE stream on /api/events refreshes the first page when other
//     devices upload or update bills. Local-only bills (syncedAt == nil) are
//     preserved because downloadPage upserts; it doesn't delete.
//

import SwiftUI
import SwiftData
import LocalAuthentication

struct BillHistoryList: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Session.self) private var session

    // Sync state (created in onAppear once Session is available).
    @State private var uploader: BillUploader?

    // Pagination state.
    @State private var serverCursor: String?
    @State private var hasMoreOnServer: Bool = true
    @State private var isLoadingPage: Bool = false
    @State private var lastFetchTriggerID: UUID?

    // UI state.
    @State private var sharingURL: URL?
    @State private var syncErrorMessage: String?
    @State private var lastSyncSummary: UploadSummary?
    @State private var selectedTable: Int?
    @State private var selectedWaiter: String?
    @State private var selectedPaymentStatus: BillHistoryItemStatus?
    @State private var showTodaysBills = false
    @State private var selectedBill: BillHistoryItem?

    // Live updates via SSE.
    @State private var sseTask: Task<Void, Never>?
    @State private var liveConnected: Bool = false
    @State private var pendingRefreshTask: Task<Void, Never>?

    // Bills shown — reads from SwiftData (so offline works).
    @Query(sort: \BillHistoryItem.date, order: .reverse) private var allBills: [BillHistoryItem]

    private var filteredBills: [BillHistoryItem] {
        allBills.filter { bill in
            if showTodaysBills {
                let startOfDay = Calendar.current.startOfDay(for: Date())
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
                if !(bill.date >= startOfDay && bill.date < endOfDay) { return false }
            }
            if let selectedTable, bill.tableNumber != selectedTable { return false }
            if let selectedWaiter, bill.waiter != selectedWaiter { return false }
            if let selectedPaymentStatus, bill.paymentStatus != selectedPaymentStatus { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Billing")
                .navigationDestination(item: $selectedBill) { bill in
                    BillHistory(billHistoryItem: bill)
                }
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
                .alert("Sync Error", isPresented: .init(get: { syncErrorMessage != nil }, set: { if !$0 { syncErrorMessage = nil } })) {
                    Button("OK") { syncErrorMessage = nil }
                } message: {
                    Text(syncErrorMessage ?? "")
                }
                .alert("Sync Complete", isPresented: .init(get: { lastSyncSummary != nil }, set: { if !$0 { lastSyncSummary = nil } })) {
                    Button("OK") { lastSyncSummary = nil }
                } message: {
                    if let s = lastSyncSummary {
                        Text("\(s.succeeded.count) of \(s.attempted) bills uploaded.\(s.failed.isEmpty ? "" : " \(s.failed.count) failed.")")
                    }
                }
                .refreshable { await refresh() }
                .task {
                    if uploader == nil {
                        uploader = BillUploader(session: session)
                    }
                    // Run the initial-page load and the unsynced-bill push
                    // concurrently — they hit different endpoints and
                    // don't share state. On tab-return the page already
                    // exists so the load is a quiet refresh; both still
                    // execute in parallel for snappier reconnection.
                    async let primaryLoad: Void = {
                        if filteredBills.isEmpty || allBills.isEmpty {
                            await loadInitialPage()
                        } else {
                            // Tab-return — pull the latest page so any
                            // bills created on other devices while we
                            // were on POS / Kitchen show up immediately.
                            await refreshFirstPageQuietly()
                        }
                    }()
                    async let pushSync: Void = pushUnsynced(silentIfEmpty: true)
                    _ = await (primaryLoad, pushSync)
                    startLiveStreamIfNeeded()
                }
                .onDisappear { stopLiveStream() }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        if session.isSignedIn {
                            Task {
                                await refreshFirstPageQuietly()
                                await pushUnsynced(silentIfEmpty: true)
                            }
                            startLiveStreamIfNeeded()
                        }
                    case .background, .inactive:
                        // Drop the SSE socket while backgrounded — iOS will
                        // suspend it anyway, and we'd rather reconnect on
                        // resume than have a dangling task.
                        stopLiveStream()
                    @unknown default:
                        break
                    }
                }
        }
        .lockWithBiometric()
    }

    // MARK: - Live (SSE)

    /// Open an SSE stream against `/api/events` and quietly re-fetch the
    /// first bill page when other devices create or update orders. Reconnects
    /// with backoff on drop. Idempotent — calling twice is a no-op.
    private func startLiveStreamIfNeeded() {
        guard sseTask == nil, session.isSignedIn else { return }
        let api = APIClient(session: session)
        sseTask = Task { @MainActor in
            var backoff: UInt64 = 1_000_000_000  // 1s
            while !Task.isCancelled {
                do {
                    let stream = api.eventStream("/api/events")
                    liveConnected = true
                    for try await ev in stream {
                        if Task.isCancelled { break }
                        switch ev.event {
                        case "order_created", "order_updated", "order_status_changed":
                            scheduleQuietRefresh()
                        default:
                            break  // ignore connection / heartbeat / kitchen_update
                        }
                    }
                    backoff = 1_000_000_000  // reset after a clean stream end
                } catch is CancellationError {
                    break
                } catch {
                    liveConnected = false
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 30_000_000_000)
                }
                liveConnected = false
            }
            liveConnected = false
        }
    }

    private func stopLiveStream() {
        sseTask?.cancel()
        sseTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        liveConnected = false
    }

    /// Debounce refreshes — bill bursts (e.g. Sync All Unsynced from another
    /// device) emit several events quickly, and we only need one refresh.
    private func scheduleQuietRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms debounce
            if Task.isCancelled { return }
            await refreshFirstPageQuietly()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if filteredBills.isEmpty && !isLoadingPage {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No bills yet")
                .font(.headline)
            Text("Bills generated on this or any other device will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var list: some View {
        List {
            ForEach(filteredBills) { bill in
                Button {
                    selectedBill = bill
                } label: {
                    BillRowCard(bill: bill, syncIndicator: { syncIndicator(for: bill) })
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if bill.paymentStatus == .pending {
                        Button {
                            markPaid(bill, status: .paidByCash)
                        } label: {
                            Label("Mark Paid", systemImage: "checkmark.circle.fill")
                        }
                        .tint(.green)
                    }
                }
                .onAppear {
                    Task { await loadMoreIfNeeded(currentBill: bill) }
                }
            }

            if isLoadingPage {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 12)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if !hasMoreOnServer && !filteredBills.isEmpty {
                HStack {
                    Spacer()
                    Text("End of history")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .background(Color(.systemBackground))
    }

    // MARK: - Sync indicator

    @ViewBuilder
    private func syncIndicator(for bill: BillHistoryItem) -> some View {
        if bill.syncedAt != nil {
            // Synced — subtle, green checkmark.
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("Synced")
        } else {
            Button {
                Task { await syncOne(bill) }
            } label: {
                Label("Upload", systemImage: "icloud.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Upload pending")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button {
                    showTodaysBills.toggle()
                } label: {
                    Label("\(showTodaysBills ? "● " : "")Show today's bills", systemImage: "calendar")
                }
                TableDropdownSelector(showIfSelected: true, selectedOption: $selectedTable, options: Array(1...20))
                WaiterDropdownSelector(showIfSelected: true, selectedOption: $selectedWaiter, staff: [
                    WaiterRef(id: "fallback-1", name: "Alcin",   role: "WAITER"),
                    WaiterRef(id: "fallback-2", name: "Anthony", role: "WAITER"),
                    WaiterRef(id: "fallback-3", name: "Antone",  role: "WAITER"),
                    WaiterRef(id: "fallback-4", name: "Amanda",  role: "WAITER"),
                    WaiterRef(id: "fallback-5", name: "Monica",  role: "WAITER"),
                    WaiterRef(id: "fallback-6", name: "Joshua",  role: "WAITER"),
                ])
                PaymentStatusDropdownSelector(showIfSelected: true, selectedOption: $selectedPaymentStatus)

                Section {
                    Button {
                        showTodaysBills = false
                        selectedTable = nil
                        selectedWaiter = nil
                        selectedPaymentStatus = nil
                    } label: {
                        Label("Clear filters", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .overlay(alignment: .topTrailing) {
                        let active = showTodaysBills || selectedTable != nil || selectedWaiter != nil || selectedPaymentStatus != nil
                        Circle()
                            .fill(active ? Color.red : Color.clear)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -4)
                    }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await pushUnsynced(silentIfEmpty: false) }
                } label: {
                    Label("Sync All Unsynced", systemImage: "icloud.and.arrow.up")
                }
                .disabled(uploader?.isUploading ?? false)

                Divider()

                Button {
                    session.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                if uploader?.isUploading == true || isLoadingPage {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "icloud")
                }
            }
        }
    }

    // MARK: - Pagination

    private func loadInitialPage() async {
        guard let uploader, session.isSignedIn else { return }
        await loadPage(cursor: nil, uploader: uploader, append: false)
    }

    private func loadMoreIfNeeded(currentBill: BillHistoryItem) async {
        guard let uploader,
              session.isSignedIn,
              hasMoreOnServer,
              !isLoadingPage else { return }
        // Only trigger when within the last few visible items.
        guard let idx = filteredBills.firstIndex(where: { $0.id == currentBill.id }) else { return }
        let triggerThreshold = max(filteredBills.count - 5, 0)
        guard idx >= triggerThreshold else { return }
        // Avoid duplicate fires for the same trigger.
        if lastFetchTriggerID == currentBill.id { return }
        lastFetchTriggerID = currentBill.id

        await loadPage(cursor: serverCursor, uploader: uploader, append: true)
    }

    private func loadPage(cursor: String?, uploader: BillUploader, append: Bool) async {
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let result = try await uploader.downloadPage(cursor: cursor, into: modelContext, pageSize: 50)
            serverCursor = result.nextCursor
            hasMoreOnServer = result.hasMore
        } catch let err as BillSyncError {
            // Silent on auto-load (let the cached list keep showing); only alert on user-initiated.
            if err.errorDescription?.contains("Session expired") == true {
                syncErrorMessage = err.errorDescription
            }
        } catch {
            // Silent
        }
    }

    private func refresh() async {
        guard let uploader else { return }
        serverCursor = nil
        hasMoreOnServer = true
        lastFetchTriggerID = nil
        await loadPage(cursor: nil, uploader: uploader, append: false)
    }

    private func refreshFirstPageQuietly() async {
        guard let uploader else { return }
        // Re-fetch first page silently — picks up new bills uploaded from other devices.
        await loadPage(cursor: nil, uploader: uploader, append: false)
    }

    // MARK: - Sync (push)

    private func syncOne(_ bill: BillHistoryItem) async {
        guard let uploader else { return }
        do {
            try await uploader.uploadOne(bill)
            try? modelContext.save()
        } catch let err as BillSyncError {
            syncErrorMessage = err.errorDescription
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    /// Swipe-action handler: flip a pending bill to a paid status and re-upload.
    /// Rolls back the local change if the upload fails so SwiftData stays
    /// consistent with the server.
    private func markPaid(_ bill: BillHistoryItem, status: BillHistoryItemStatus) {
        let previous = bill.paymentStatus
        bill.paymentStatus = status
        bill.syncedAt = nil
        try? modelContext.save()

        Task { @MainActor in
            guard let uploader else { return }
            do {
                try await uploader.uploadOne(bill)
            } catch let err as BillSyncError {
                bill.paymentStatus = previous
                try? modelContext.save()
                syncErrorMessage = err.errorDescription
            } catch {
                bill.paymentStatus = previous
                try? modelContext.save()
                syncErrorMessage = error.localizedDescription
            }
        }
    }

    private func pushUnsynced(silentIfEmpty: Bool) async {
        guard let uploader else { return }
        do {
            let summary = try await uploader.syncAllUnsynced(in: modelContext)
            if !silentIfEmpty || summary.attempted > 0 {
                lastSyncSummary = summary
            }
        } catch let err as BillSyncError {
            if !silentIfEmpty {
                syncErrorMessage = err.errorDescription
            }
        } catch {
            if !silentIfEmpty {
                syncErrorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Bill row card (web-style)

private struct BillRowCard<Sync: View>: View {
    let bill: BillHistoryItem
    @ViewBuilder let syncIndicator: () -> Sync

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(alignment: .firstTextBaseline) {
                Text(bill.tableNumber == 0 ? "Parcel" : "Table \(bill.tableNumber)")
                    .font(.system(.headline, weight: .semibold))
                syncIndicator()
                Spacer()
                Text(bill.items.getTotal().asCurrencyString() ?? "—")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .accessibilityIdentifier("BillHistoryList-Item-\(bill.id.uuidString)")
            }

            // Status + meta row
            HStack(spacing: 8) {
                PaymentStatusChip(status: bill.paymentStatus)
                Text("•").foregroundStyle(.tertiary)
                Text("\(bill.items.count) item\(bill.items.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("•").foregroundStyle(.tertiary)
                Text(bill.waiter)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Footer date
            Text(bill.date.getTimeInFormat(dateStyle: .medium, timeStyle: .short))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Payment status chip

private struct PaymentStatusChip: View {
    let status: BillHistoryItemStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(color.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(color.opacity(0.3), lineWidth: 0.5)
        )
        .accessibilityIdentifier("paymentStatus-\(status.rawValue)")
    }

    private var label: String {
        switch status {
        case .pending: "Pending"
        case .paidByCard: "Card"
        case .paidByCash: "Cash"
        case .paidByUPI: "UPI"
        }
    }

    private var color: Color {
        switch status {
        case .pending: .red
        case .paidByCard: Color(red: 0.5, green: 0.4, blue: 0.9)
        case .paidByCash: Color(red: 0.2, green: 0.7, blue: 0.3)
        case .paidByUPI: Color(red: 1.0, green: 0.6, blue: 0.2)
        }
    }

    private var textColor: Color {
        status == .pending ? .red : .secondary
    }
}

#if DEBUG
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: BillHistoryItem.self, configurations: config)
    PreviewData.billHistoryItems.forEach { container.mainContext.insert($0) }
    return BillHistoryList()
        .modelContainer(container)
        .environment(Session())
}
#endif
