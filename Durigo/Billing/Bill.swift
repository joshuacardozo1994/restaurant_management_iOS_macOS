//
//  Bill.swift
//  pdf test
//
//  Created by Joshua Cardozo on 14/10/23.
//

import SwiftUI

struct ThankYouMessages {
    static let messages = [
        "We're grateful for your visit and look forward to serving you again.",
        "Thank you for choosing us for your meal today.",
        "It was a pleasure to host you at our table.",
        "We hope you enjoyed your dining experience with us.",
        "Your patronage is appreciated. We can't wait to welcome you back!",
        "Thank you for your support. We hope to delight you again soon.",
        "We're thrilled you dined with us. Thank you!",
        "Thank you for being our guest. We hope your experience was memorable.",
        "Thank you for allowing us to serve you today.",
        "We value your visit and hope to see you again very soon."
    ]
    
    static let christmasMessages = [
        "Thanks for joining us during this special season. Merry Christmas! 🎄",
        "Merry Christmas! Your choice brightened our day. 🎄",
        "We truly enjoyed hosting you during this festive time. Merry Christmas! 🎄",
        "We hope your dining experience was wonderful. Merry Christmas! 🎄",
        "Your visit means a lot to us, especially during this holiday. Merry Christmas! 🎄",
        "We extend our heartfelt thanks for your support. Merry Christmas! 🎄",
        "We're absolutely thrilled that you dined with us this Christmas season. Merry Christmas! 🎄",
        "Merry Christmas! We hope your experience with us was truly memorable. 🎄",
        "Thanks for choosing us to celebrate this Christmas. Merry Christmas! 🎄",
        "Your visit is a gift to us this holiday season. Merry Christmas! 🎄"
    ]
    
    static let newYearMessages = [
        "Thank you for ringing in the New Year with us! Cheers to a wonderful year ahead. 🎉",
        "Happy New Year! Your presence made our celebration even more special. 🎊",
        "We're delighted to have hosted you as we welcomed the New Year. Cheers to new beginnings! 🎉",
        "May your New Year be filled with joy and prosperity. Thank you for celebrating with us! 🎊",
        "Your visit added sparkle to our New Year's celebration. Wishing you a year of happiness! 🎉",
        "We're grateful for your support and company as we step into the New Year. Happy New Year! 🎊",
        "Celebrating the New Year was more memorable with you. Wishing you all the best in the year to come! 🎉",
        "Happy New Year! We hope your time with us was the perfect start to a fantastic year. 🎊",
        "Thank you for choosing to welcome the New Year with us. May it bring you endless joy and success! 🎉",
        "Your presence was the highlight of our New Year's celebration. Wishing you a prosperous year ahead! 🎊"
    ]

    
    static func getRandomMessage() -> String {
        messages.randomElement() ?? "Thank you for dining with us"
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        return path
    }
}

extension Bill {
    struct SnowFlake: View {
        var body: some View {
            Image(systemName: "snowflake")
                .foregroundStyle(Color(hex: "#6889b8"))
                .opacity(0.2)
                .font(.system(size: 50))
        }
    }
}

/// The tax lines printed above the total on a bill's last page
struct ReceiptTaxes {
    let amounts: BillAmounts
    let config: BillingConfig

    private static func percent(_ rate: Double) -> String {
        let p = rate * 100
        return p == p.rounded() ? "\(Int(p))%" : String(format: "%.1f%%", p)
    }
    /// GST is split equally between the state and the centre (odd rupee to SGST)
    var cgst: Int { amounts.gstTax / 2 }
    var sgst: Int { amounts.gstTax - cgst }
    var halfGstRate: String { Self.percent(config.taxRate / 2) }
    var vatRate: String { Self.percent(config.liquorTaxRate) }
    var inclusive: String { config.taxInclusive ? " (incl.)" : "" }
}

struct Bill: View {
    let currentMenuItems: [MenuItem]
    let tableNumber: Int?
    var first = true
    var finalTotal: Int?
    /// GST/VAT breakdown, shown on the last page with the total
    var taxes: ReceiptTaxes? = nil
    /// Name, address, phone and tax numbers printed at the top
    var identity: RestaurantIdentity = .durigos
    /// How it was paid ("₹513 cash, ₹513 UPI"), shown under the total
    var paidBy: String? = nil
    @State private var maxWidth: CGFloat = 0
    #if os(iOS)
    @State private var qrCodeImage: UIImage? = nil
    #endif
    
    func itemText(item: MenuItem) -> Text {
        var textArr = [Text("")]
        
        if item.servingSize?.shouldDisplay == true {
            textArr.append(Text(" \(item.servingSize?.name ?? "")").bold())
        }
        
        if let prefix = item.prefix {
            textArr.append(Text(" \(prefix)").bold())
        }
        
        textArr.append(Text(" \(item.name)"))
        
        return textArr.reduce(Text("")) { $0 + $1 }
    }
    
    private func taxRow(_ label: String, _ amount: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount < 0 ? "−\((-amount).rupees)" : "\((amount).rupees)")
        }
    }

    var body: some View {
            VStack() {
                if first {
                    HStack {
                        Spacer()
                        Text(identity.name)
                            .font(.dancingScriptBold(size: 40))
//                            .overlay {
//                                Image(.christmasBells)
//                                    .resizable()
//                                    .aspectRatio(contentMode: .fit)
//                                    .offset(x: -100)
//                            }
//                            .overlay {
//                                Image(.christmasBells)
//                                    .resizable()
//                                    .aspectRatio(contentMode: .fit)
//                                    .offset(x: 100)
//                            }
                        Spacer()
                        
                    }
                    .overlay(alignment: .topTrailing) {
                        Text("Date: \(Date().getTimeInFormat(dateStyle: .short, timeStyle: .none))")
                            .font(.system(size: 11))
                    }
                    .overlay(alignment: .topLeading) {
                        if let tableNumber {
                            if tableNumber == 0 {
                                Text("Parcel")
                                    .font(.system(size: 11))
                            } else {
                                Text("Table: \(tableNumber)")
                                    .font(.system(size: 11))
                            }
                            
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        Text("GSTIN: \(identity.gstin)")
                            .font(.system(size: 10))
                            .padding(.top)
                    }
                    
                    .overlay(alignment: .topTrailing) {
                            Text("VAT TIN: \(identity.vatTin)")
                                .font(.system(size: 10))
                                .padding(.top)
                            
                        
                    }
                    
                    Text(identity.phone)
                        .font(.system(size: 11))
                    Text(identity.address)
                        .font(.system(size: 11))
                        .padding(.bottom)
                } else {
                    Spacer()
                        .frame(height: 60)
                }
                VStack(spacing: 4) {
                    ForEach(currentMenuItems) { item in
                        HStack(alignment: .bottom) {
                                Text("\(item.quantity.formatNumberWithFraction())").bold()
                                .background(
                                                            GeometryReader { geometry in
                                                                Color.clear.onAppear {
                                                                    let textWidth = geometry.size.width
                                                                    if textWidth > maxWidth {
                                                                        maxWidth = textWidth
                                                                    }
                                                                }
                                                            }
                                                        )
                                                        .frame(minWidth: maxWidth, alignment: .leading)
                            
                                
                                
                            itemText(item: item)
                                .layoutPriority(1)
                            VStack{
                                Line()
                                    .stroke(style: StrokeStyle(lineWidth: 0.5, dash: [5]))
                                    .frame(height: 0.5)
                                    .opacity(0.4)
                                    .padding(.bottom, 3)
                                
                            }
                            Text("\((item.lineTotal).rupees)")
                        }
                    }
                    .font(.system(size: 12))
                }
                
                if let finalTotal {
                    if let taxes {
                        VStack(spacing: 1) {
                            if taxes.amounts.discount > 0 {
                                taxRow("Items", taxes.amounts.gross)
                                taxRow("Discount", -taxes.amounts.discount)
                            }
                            taxRow("Taxable value", taxes.amounts.subtotal)
                            if taxes.amounts.gstTax > 0 {
                                taxRow("CGST @ \(taxes.halfGstRate)\(taxes.inclusive)", taxes.cgst)
                                taxRow("SGST @ \(taxes.halfGstRate)\(taxes.inclusive)", taxes.sgst)
                            }
                            if taxes.amounts.vatTax > 0 {
                                taxRow("VAT on liquor @ \(taxes.vatRate)\(taxes.inclusive)", taxes.amounts.vatTax)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.black.opacity(0.6))
                        .padding(.top, 6)
                    }
                        HStack(alignment: .center) {
                            Text("Total: \((finalTotal).rupees)")
                                .font(.system(size: 20))
                                .bold()
                            #if os(iOS)
                            if let uiImage = qrCodeImage {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .frame(width: 50, height: 50)
                            }
                            #endif
//                            Image(.snowman)
//                                .resizable()
//                                .aspectRatio(contentMode: .fit)
//                                .frame(width: 50, height: 50)
                        }
                        
                        
                    
                    if let paidBy {
                        Text("Paid by \(paidBy)")
                            .font(.system(size: 10))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                    Spacer()
                    Text(ThankYouMessages.getRandomMessage())
                        .font(.dancingScriptRegular(size: 18))
                        .padding(.bottom, 8)
                    
                } else {
                    Spacer()
                }
                
            }
            .padding()
            .foregroundColor(.black)
            .onAppear {
                #if os(iOS)
                if qrCodeImage == nil {
                    qrCodeImage = "upi://pay?ver=01&mode=1&pa=88117166@idfcbank&pn=DURIGOBARANDRESTAURANT&tr=STQ241211070222532I024331&mc=5812&qrMedium=03".getQRCodeImage()
                }
                #endif
            }
//            VStack(spacing: 40) {
//                Spacer()
//                    .frame(height: 70)
//                ForEach(0...currentMenuItems.count/6, id: \.self) { _ in
//                    
//                    SnowFlake()
//                        .offset(x: CGFloat(Int.random(in: -100...100)))
//                }
//                Spacer()
//            }
        
    }
}

/// Lays a bill out on A5-ish pages and renders them to a PDF, for printing
/// or sharing. Used by the Bill Generator and for POS table receipts.
/// A bill page shrunk to fit the space it's shown in (a phone is narrower than
/// the 420pt page). Only for on-screen previews; PDFs render at full size.
struct FittedBillPage<Page: View>: View {
    let page: Page

    var body: some View {
        GeometryReader { geo in
            let size = BillRenderer.pageSize
            let scale = min(1, geo.size.width / size.width, geo.size.height / size.height)
            page
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum BillRenderer {
    static let pageSize = CGSize(width: 420, height: 595)
    static let itemsPerPage = 19
    /// The last page also carries the total and up to six tax/discount lines
    static let itemsOnLastPage = 13

    static func pages(_ items: [MenuItem]) -> [[MenuItem]] {
        var pages = stride(from: 0, to: items.count, by: itemsPerPage).map {
            Array(items[$0 ..< min($0 + itemsPerPage, items.count)])
        }
        // Move the overflow of a full last page onto a page of its own
        if let last = pages.last, last.count > itemsOnLastPage {
            pages[pages.count - 1] = Array(last.prefix(itemsOnLastPage))
            pages.append(Array(last.dropFirst(itemsOnLastPage)))
        }
        return pages.isEmpty ? [[]] : pages
    }

    @MainActor
    static func page(_ index: Int, of pages: [[MenuItem]], tableNumber: Int?, finalTotal: Int,
                     taxes: ReceiptTaxes?, identity: RestaurantIdentity = .durigos,
                     paidBy: String? = nil) -> some View {
        let isLast = index == pages.count - 1
        return Bill(currentMenuItems: pages[index], tableNumber: tableNumber, first: index == 0,
                    finalTotal: isLast ? finalTotal : nil, taxes: isLast ? taxes : nil,
                    identity: identity, paidBy: isLast ? paidBy : nil)
            .frame(width: pageSize.width, height: pageSize.height)
            .background(Color.white)
    }

    @MainActor
    static func renderPDF(items: [MenuItem], tableNumber: Int?, finalTotal: Int, taxes: ReceiptTaxes?,
                          identity: RestaurantIdentity = .durigos, paidBy: String? = nil,
                          fileName: String = "Bill.pdf") async -> URL {
        let url = URL.documentsDirectory.appending(path: fileName)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
        let all = pages(items)
        for index in all.indices {
            pdf.beginPDFPage(nil)
            let renderer = ImageRenderer(content: page(index, of: all, tableNumber: tableNumber,
                                                       finalTotal: finalTotal, taxes: taxes,
                                                       identity: identity, paidBy: paidBy))
            renderer.scale = 1.0 // match PDF points exactly
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, context in context(pdf) }
            pdf.endPDFPage()
            if index < all.count - 1 { await Task.yield() }
        }
        pdf.closePDF()
        return url
    }
}

struct Bill_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            HStack { Spacer() }
            Spacer()
            Bill(currentMenuItems: [
                MenuItem(id: UUID(), name: "Soda", quantity: 1.5, price: 20),
                MenuItem(id: UUID(), name: "Fresh Lemon Soda", quantity: 2, price: 90),
                MenuItem(id: UUID(), name: "Virgin Mojito", quantity: 1, price: 220),
                MenuItem(id: UUID(), name: "Chonok", quantity: 1, price: 500),
                MenuItem(id: UUID(), name: "Chilli Chicken", quantity: 2.5, price: 250),
                MenuItem(id: UUID(), name: "Chicken Pulao", quantity: 1, price: 200),
                MenuItem(id: UUID(), name: "Ice Cream (Single scoop)", quantity: 1, price: 160),
                MenuItem(id: UUID(), name: "Chocolate Brownie (With ice-cream)", quantity: 2, price: 180),
                MenuItem(id: UUID(), name: "Chicken Soup", prefix: "1 by 2", quantity: 2, price: 180),
                MenuItem(id: UUID(), name: "Some drink", prefix: nil, suffix: nil, quantity: 2.5, price: 40, servingSize: Category.Item.ServingSize(id: UUID(), name: "peg", expression: "x", description: "something", shouldDisplay: true))
//                MenuItem(id: UUID(), name: "Ice Cream", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Caramel Pudding", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Pankcakes", quantity: 2, price: 100),
//                MenuItem(id: UUID(), name: "Item 12", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 13", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 14", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 15", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 16", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 17", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 18", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 19", quantity: 1, price: 100),
//                MenuItem(id: UUID(), name: "Item 20", quantity: 1, price: 100)
            ], tableNumber: 9, first: true, finalTotal: 420)
                .frame(width: 420, height: 595)
                .background(Color.white)
            Spacer()
        }
        .background(Color.gray)
    }
}
