//
//  ContentView.swift
//  pdf test
//
//  Created by Joshua Cardozo on 09/10/23.
//

import SwiftUI
import SwiftData



struct GroupedMenu: Identifiable, Equatable {
    let id: Int
    let items: [MenuItem]
}

struct BillPreview: View {
    @Query var billHistoryItems: [BillHistoryItem]
    @Environment(\.modelContext) var modelContext
    @Environment(Session.self) private var session
    @EnvironmentObject private var menuLoader: MenuLoader
    let tableNumber: Int?
    let waiter: String
    let maxItemCount = 19
    let billID: UUID
    let billItems: [MenuItem]
    @State private var pdfURL: URL?
    @State private var isGeneratingPDF = false
    /// Created lazily on first appear — needs `session`, which @Environment
    /// only resolves inside the view tree (not in init).
    @State private var uploader: BillUploader?

    /// The last page also carries up to four tax lines, so it holds fewer items
    private let lastPageItemCount = 15

    private var groupedArray: [GroupedMenu] {
        var groups = stride(from: 0, to: billItems.count, by: maxItemCount).map { index in
            GroupedMenu(id: index, items: Array(billItems[index ..< min(index + maxItemCount, billItems.count)]))
        }
        // Move the overflow of a full last page onto a page of its own
        if let last = groups.last, last.items.count > lastPageItemCount {
            groups[groups.count - 1] = GroupedMenu(id: last.id, items: Array(last.items.prefix(lastPageItemCount)))
            groups.append(GroupedMenu(id: last.id + lastPageItemCount, items: Array(last.items.dropFirst(lastPageItemCount))))
        }
        return groups
    }

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
                ForEach(groupedArray) { group in
                    Bill(currentMenuItems: group.items, tableNumber: tableNumber, first: groupedArray.first == group,
                         finalTotal: groupedArray.last == group ? billItems.getTotal() : nil,
                         taxes: groupedArray.last == group ? taxes : nil)
                            .frame(width: 420, height: 595)
                            .background(Color.white)
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
        // 1: Save it to our documents directory
        let url = URL.documentsDirectory.appending(path: "Bill.pdf")

        // 2: PDF size - must match the frame size used in preview
        let pageWidth: CGFloat = 420
        let pageHeight: CGFloat = 595
        var box = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        // 3: Create the CGContext for our PDF pages
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else {
            return url
        }

        // 4: Render each page - use Task.yield() to prevent blocking
        for (index, group) in groupedArray.enumerated() {
            pdf.beginPDFPage(nil)

            let billView = Bill(
                currentMenuItems: group.items,
                tableNumber: tableNumber,
                first: groupedArray.first == group,
                finalTotal: groupedArray.last == group ? billItems.getTotal() : nil,
                taxes: groupedArray.last == group ? taxes : nil
            )
            .frame(width: pageWidth, height: pageHeight)
            .background(Color.white)

            let renderer = ImageRenderer(content: billView)
            // Set scale to 1.0 to match PDF point size exactly
            renderer.scale = 1.0
            // Set proposed size to ensure consistent layout
            renderer.proposedSize = ProposedViewSize(width: pageWidth, height: pageHeight)

            renderer.render { size, context in
                context(pdf)
            }

            pdf.endPDFPage()

            // Yield to allow UI updates between pages
            if index < groupedArray.count - 1 {
                await Task.yield()
            }
        }
        pdf.closePDF()

        return url
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
