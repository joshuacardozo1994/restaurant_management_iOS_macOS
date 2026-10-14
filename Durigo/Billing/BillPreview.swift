//
//  ContentView.swift
//  pdf test
//
//  Created by Joshua Cardozo on 09/10/23.
//

import SwiftUI
import SwiftData




struct BillPreview: View {
    @Query var billHistoryItems: [BillHistoryItem]
    @Environment(\.modelContext) var modelContext
    @Environment(Session.self) private var session
    @EnvironmentObject private var menuLoader: MenuLoader
    let tableNumber: Int?
    let waiter: String
    let billID: UUID
    let billItems: [MenuItem]
    @State private var pdfURL: URL?
    @State private var isGeneratingPDF = false
    /// Created lazily on first appear — needs `session`, which @Environment
    /// only resolves inside the view tree (not in init).
    @State private var uploader: BillUploader?

    private var pages: [[MenuItem]] { BillRenderer.pages(billItems) }

    /// GST on food, VAT on liquor, worked out the way the server will record it
    private var taxes: ReceiptTaxes {
        ReceiptTaxes(
            amounts: BillMath.computeBill(items: billItems, menu: menuLoader.menu, config: menuLoader.billingConfig),
            config: menuLoader.billingConfig
        )
    }

    var body: some View {
        VStack {
            TabView {
                ForEach(pages.indices, id: \.self) { index in
                    FittedBillPage(page: BillRenderer.page(index, of: pages, tableNumber: tableNumber,
                                                           finalTotal: billItems.getTotal(), taxes: taxes,
                                                           identity: menuLoader.identity))
                        .padding(.vertical, 8)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page)
            #endif
            HStack {
                Spacer()
                if isGeneratingPDF {
                    ProgressView()
                        .padding()
                } else if let pdfURL {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        ShareLink("Export PDF", item: pdfURL)
                            .buttonStyle(.glass)
                    } else {
                        ShareLink("Export PDF", item: pdfURL)
                            .buttonStyle(.bordered)
                    }
                } else {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Button("Generate PDF") {
                            generatePDF()
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button("Generate PDF") {
                            generatePDF()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
        .background(Color.gray.opacity(0.5))
        .onAppear {
            let bill = upsertBill()
            try? modelContext.save()

            // Sync the bill to the server immediately when Print is tapped,
            // instead of waiting for someone to open BillHistoryList. The
            // kitchen / billing displays on other devices then see the new
            // order in real time. Failure is non-fatal — the bill is already
            // in SwiftData with syncedAt == nil, so BillHistoryList's normal
            // sync-on-appear path will retry next time the user opens it.
            if let bill {
                Task { @MainActor in
                    if uploader == nil {
                        uploader = BillUploader(session: session)
                    }
                    try? await uploader?.uploadOne(bill)
                    try? modelContext.save()
                }
            }

            // Start generating PDF in background
            generatePDF()
        }
        .onChange(of: billHistoryItems, { oldValue, newValue in
//            let pendingBillsCount = (newValue.filter { $0.paymentStatus == .pending }).count
//            UNUserNotificationCenter.current().setBadgeCount(pendingBillsCount)
        })
    }

    /// Mutate-or-insert the BillHistoryItem for this print preview and return
    /// it. Returns nil only when there's no existing bill AND no tableNumber
    /// to construct one — print is disabled in that case so it's a defensive
    /// guard, not a real path.
    private func upsertBill() -> BillHistoryItem? {
        if let existing = billHistoryItems.first(where: { $0.id == billID }) {
            if let tableNumber {
                existing.tableNumber = tableNumber
            }
            existing.items = billItems
            existing.waiter = waiter
            // The data just changed — mark unsynced so the immediate upload
            // below (and any later retry) sees it as needing a push.
            existing.syncedAt = nil
            return existing
        }
        guard let tableNumber else { return nil }
        let bill = BillHistoryItem(id: billID, items: billItems, tableNumber: tableNumber, waiter: waiter)
        modelContext.insert(bill)
        return bill
    }

    private func generatePDF() {
        guard !isGeneratingPDF else { return }
        isGeneratingPDF = true

        Task {
            let url = await render()
            await MainActor.run {
                pdfURL = url
                isGeneratingPDF = false
            }
        }
    }

    @MainActor func render() async -> URL {
        await BillRenderer.renderPDF(items: billItems, tableNumber: tableNumber,
                                     finalTotal: billItems.getTotal(), taxes: taxes,
                                     identity: menuLoader.identity)
    }
}
#if DEBUG
#Preview {
    do {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BillHistoryItem.self, configurations: config)

        return BillPreview(tableNumber: 1, waiter: "Anthony", billID: UUID(), billItems: PreviewData.menuItems)
            .modelContainer(container)
            .environment(Session())
    } catch {
        fatalError("Failed to create model container.")
    }
}
#endif
