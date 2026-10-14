//
//  Models.swift
//  pdf test
//
//  Created by Joshua Cardozo on 14/10/23.
//

import Foundation
import UniformTypeIdentifiers
import CoreTransferable

extension Array where Element == MenuItem {
    /// Bill total in whole rupees. Each line is rounded (half a ₹155 portion
    /// is ₹78), the same way the server values an uploaded bill.
    func getTotal() -> Int {
        self.reduce(0) { $0 + $1.lineTotal }
    }
}

extension MenuItem {
    /// This line's value in whole rupees, rounded like the server does
    var lineTotal: Int { Int((price * quantity).rounded()) }
}

// MARK: - Bill maths (a port of the server's app/lib/bill-math.ts)
//
// The restaurant charges GST on food and soft drinks and VAT on liquor, both
// included in menu prices. The server records the tax when a bill is uploaded;
// this is the same arithmetic, so the printed receipt matches what is filed.
// Keep it in step with bill-math.ts (the test vectors in BillMathTests come
// from tests/billing/bill-math.test.ts).

struct BillingConfig: Codable, Equatable {
    /// GST on food and soft drinks, as a fraction (0.05 = 5%)
    var taxRate: Double
    /// VAT on liquor, as a fraction (0.22 = 22%)
    var liquorTaxRate: Double
    /// Menu prices already include the tax
    var taxInclusive: Bool

    static let `default` = BillingConfig(taxRate: 0.05, liquorTaxRate: 0.22, taxInclusive: true)
}

enum TaxClass { case gst, vat }

struct BillAmounts: Equatable {
    var gross: Int
    var discount: Int
    /// Taxable value
    var subtotal: Int
    var tax: Int
    var gstTax: Int
    var vatTax: Int
    var total: Int
}

enum BillMath {
    private static let alcoholKeywords = [
        "beer", "vodka", "whisky", "rum", "gin", "wine", "brandy", "port", "feni", "tequila",
        "champagne", "smirnoff", "kingfisher", "tuborg", "budweiser", "corona", "heineken",
        "bacardi", "johnnie", "jack daniel", "red label", "black label", "absolut", "grey goose",
        "moet", "dom perignon",
    ]

    /// Whole words only (an optional plural s): "gin" must not match "ginger"
    /// or "virgin", "port" not "portion", "rum" not "drumsticks"
    private static let alcoholPattern = try! NSRegularExpression(
        pattern: "(^|[^a-z])(\(alcoholKeywords.joined(separator: "|")))s?([^a-z]|$)")

    /// VAT if the line's menu category is ALCOHOL; for a line with no menu
    /// category (a custom item), VAT if its name says it's liquor.
    static func taxClass(categoryType: String?, name: String) -> TaxClass {
        if let categoryType { return categoryType == "ALCOHOL" ? .vat : .gst }
        let n = name.lowercased()
        let isLiquor = alcoholPattern.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
        return isLiquor ? .vat : .gst
    }

    /// Split `amount` into whole rupees in proportion to `weights`; the parts
    /// always add back up to `amount` (largest remainder, ties to the first).
    static func allocate(_ amount: Int, weights: [Int]) -> [Int] {
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return weights.indices.map { $0 == 0 ? amount : 0 } }
        let exact = weights.map { Double(amount) * Double($0) / Double(totalWeight) }
        var parts = exact.map { Int($0.rounded(.down)) }
        var remainder = amount - parts.reduce(0, +)
        let byFraction = exact.indices.sorted { a, b in
            let fa = exact[a] - exact[a].rounded(.down), fb = exact[b] - exact[b].rounded(.down)
            return fa != fb ? fa > fb : a < b
        }
        for i in byFraction where remainder > 0 {
            parts[i] += 1
            remainder -= 1
        }
        return parts
    }

    /// The bill for a food (GST) part and a liquor (VAT) part, after a discount
    /// shared between them in proportion.
    static func computeBill(gst: Int, vat: Int, discount: Int, config: BillingConfig) -> BillAmounts {
        let gross = gst + vat
        let applied = min(max(discount, 0), gross)
        let shares = allocate(applied, weights: [gst, vat])
        let gstPart = gst - shares[0], vatPart = vat - shares[1]

        func taxOn(_ amount: Int, _ rate: Double) -> Int {
            let a = Double(amount)
            return Int((config.taxInclusive ? a * rate / (1 + rate) : a * rate).rounded())
        }
        let gstTax = taxOn(gstPart, config.taxRate)
        let vatTax = taxOn(vatPart, config.liquorTaxRate)
        let tax = gstTax + vatTax

        if config.taxInclusive {
            let total = gstPart + vatPart
            return BillAmounts(gross: gross, discount: applied, subtotal: total - tax, tax: tax,
                               gstTax: gstTax, vatTax: vatTax, total: total)
        }
        let subtotal = gstPart + vatPart
        return BillAmounts(gross: gross, discount: applied, subtotal: subtotal, tax: tax,
                           gstTax: gstTax, vatTax: vatTax, total: subtotal + tax)
    }

    /// A Bill Generator bill: each line is matched to the menu by name (as the
    /// server does on upload) to find whether it is liquor.
    static func computeBill(items: [MenuItem], menu: [Category]?, discount: Int = 0,
                            config: BillingConfig) -> BillAmounts {
        var typeByName: [String: String] = [:]
        for category in menu ?? [] {
            guard let type = category.taxType else { continue }
            for item in category.items { typeByName[item.name.lowercased().trimmingCharacters(in: .whitespaces)] = type }
        }
        var gst = 0, vat = 0
        for item in items {
            let type = typeByName[item.name.lowercased().trimmingCharacters(in: .whitespaces)]
            switch taxClass(categoryType: type, name: item.name) {
            case .gst: gst += item.lineTotal
            case .vat: vat += item.lineTotal
            }
        }
        return computeBill(gst: gst, vat: vat, discount: discount, config: config)
    }
}

enum ItemType: String, Codable {
    case drinks
    case food
}

struct Category: Codable, Identifiable {
    struct Item: Codable, Identifiable {
        enum VisibilityScope: String, Codable {
            case menu
            case bill
            case both
        }
        
        struct ServingSize: Codable, Identifiable, Equatable, Hashable {
            let id: UUID
            let name: String
            let expression: String
            let description: String
            let shouldDisplay: Bool
            var isSelected = false
            
            
            enum CodingKeys: String, CodingKey {
                case id, name, expression, description, shouldDisplay
            }
        }
        
        let id: UUID
        let name: String
        let price: Double
        let prefix: String?
        let suffix: String?
        let visibilityScope: VisibilityScope
        let description: String?
        let servingSizes: [ServingSize]?
        let tags: [String]?
    }
    
    let id: UUID
    
    let type: ItemType
    let name: String
    let items: [Item]
    /// FOOD / BEVERAGE / ALCOHOL from the server: liquor carries VAT,
    /// everything else GST. Nil from older servers and the bundled mock menu.
    var taxType: String? = nil
    
    static var placeholder: Category {
        let items = (1...7).map { _ in Category.Item(id: UUID(), name: "XXXXX", price: Double.random(in: 1...999), prefix: nil, suffix: nil, visibilityScope: .both, description: nil, servingSizes: nil, tags: nil) }
        let category = Category(id: UUID(), type: .drinks, name: "XXXXXX", items: items)
        return category
    }
}

extension UTType {
    static var durigobills: UTType = UTType(exportedAs: "com.durigo.bills")
}

struct BillHistoryItemCopy: Identifiable, Codable {
    
    enum Status: String, Codable, Equatable {
        case paidByCash
        case paidByUPI
        case paidByCard
        case pending
    }
    
    let id: UUID
    var date: Date
    var tableNumber: Int
    var items: [MenuItem]
    var paymentStatus: Status
    var waiter: String
    var discount: Double?
    var discountReason: String?

    init(id: UUID, date: Date = Date(), items: [MenuItem], tableNumber: Int, paymentStatus: Status = .pending,  waiter: String, discount: Double? = nil, discountReason: String? = nil) {
        self.id = id
        self.date = date
        self.items = items
        self.tableNumber = tableNumber
        self.paymentStatus = paymentStatus
        self.waiter = waiter
        self.discount = discount
        self.discountReason = discountReason
    }

    init(billHistoryItem: BillHistoryItem) {
        self.id = billHistoryItem.id
        self.date = billHistoryItem.date
        self.items = billHistoryItem.items
        self.tableNumber = billHistoryItem.tableNumber
        self.paymentStatus = Status(rawValue: billHistoryItem.paymentStatus.rawValue) ?? .pending
        self.waiter = billHistoryItem.waiter
        self.discount = billHistoryItem.discount
        self.discountReason = billHistoryItem.discountReason
    }

    func convertToBillHistoryItem() -> BillHistoryItem {
        BillHistoryItem(
            id: self.id, date: self.date, items: self.items,
            tableNumber: self.tableNumber,
            paymentStatus: BillHistoryItemStatus(rawValue: self.paymentStatus.rawValue) ?? .pending,
            waiter: self.waiter,
            discount: self.discount,
            discountReason: self.discountReason
        )
    }
}

struct DurigoBills: Codable, Transferable {
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .durigobills)
    }
    let items: [BillHistoryItemCopy]
}


