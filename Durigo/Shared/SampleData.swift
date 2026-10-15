//
//  SampleData.swift
//  Durigo
//
//  Stand-in data for skeleton loaders: what a screen draws, redacted, while
//  its real data loads. Written as the server's JSON so each sample goes
//  through the same decoders as the real thing. The values never show (they
//  are placeholder bars); they only give the layout realistic lengths.
//  DurigoTests checks that every sample decodes.
//

import Foundation

enum SampleData {
    /// Decodes a sample; a sample that no longer matches its model is empty
    /// rather than a crash (the unit tests catch it)
    static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) -> T? {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            #if DEBUG
            print("SampleData: \(T.self) doesn't decode: \(error)")
            #endif
            return nil
        }
    }

    /// An ISO-8601 time `minutes` ago, as the server sends it
    static func ago(_ minutes: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(TimeInterval(-minutes * 60)))
    }

    /// Today's date (yyyy-MM-dd) plus `days`
    static func day(_ days: Int = 0) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date().addingTimeInterval(TimeInterval(days * 86_400)))
    }
}

// MARK: - Dashboard

extension ServiceNight {
    static let sample: ServiceNight? = SampleData.decode("""
    {
      "generatedAt": "\(SampleData.ago(0))", "date": "\(SampleData.day())",
      "takings": { "total": 48250, "bills": 23, "average": 2098, "sameTimeLastWeek": 41200,
        "hourly": [{"hour": 12, "total": 6200}, {"hour": 13, "total": 9800}, {"hour": 14, "total": 5400},
                   {"hour": 19, "total": 8700}, {"hour": 20, "total": 11250}, {"hour": 21, "total": 6900}] },
      "paidBy": [{"method": "UPI", "total": 26400}, {"method": "CASH", "total": 14100}, {"method": "CARD", "total": 7750}],
      "orderTypes": [{"type": "DINE_IN", "count": 19}, {"type": "TAKEAWAY", "count": 4}],
      "floor": { "seated": 5, "total": 12, "tables": [
        {"id": "s1", "number": 1, "capacity": 4, "state": "seated", "seatedSince": "\(SampleData.ago(42))"},
        {"id": "s2", "number": 2, "capacity": 2, "state": "free"},
        {"id": "s3", "number": 3, "capacity": 4, "state": "bill", "seatedSince": "\(SampleData.ago(75))"},
        {"id": "s4", "number": 4, "capacity": 6, "state": "seated", "seatedSince": "\(SampleData.ago(18))"},
        {"id": "s5", "number": 5, "capacity": 4, "state": "reserved", "reservedFor": "20:30"},
        {"id": "s6", "number": 6, "capacity": 2, "state": "free"},
        {"id": "s7", "number": 7, "capacity": 4, "state": "seated", "seatedSince": "\(SampleData.ago(55))"},
        {"id": "s8", "number": 8, "capacity": 8, "state": "free"},
        {"id": "s9", "number": 9, "capacity": 4, "state": "seated", "seatedSince": "\(SampleData.ago(9))"},
        {"id": "s10", "number": 10, "capacity": 2, "state": "free"},
        {"id": "s11", "number": 11, "capacity": 4, "state": "free"},
        {"id": "s12", "number": 12, "capacity": 6, "state": "free"}] },
      "kitchen": { "todo": 4, "cooking": 3, "ready": 1, "oldest": {
        "orderNumber": "ORD-0142", "table": 4, "type": "DINE_IN", "status": "PREPARING",
        "since": "\(SampleData.ago(16))", "waiter": "Pedro", "cooks": ["Anthony"],
        "items": [{"name": "Chicken Cafreal", "quantity": 2, "cooking": true}, {"name": "Prawn Rava Fry", "quantity": 1, "cooking": false}] } },
      "billRequested": [3],
      "lowStock": [{"name": "Kingfish", "unit": "kg", "currentStock": 2, "minimumStock": 5},
                   {"name": "Coconut", "unit": "pcs", "currentStock": 8, "minimumStock": 20}],
      "reservations": [{"guestName": "Fernandes", "guestCount": 4, "time": "20:30", "table": 5},
                       {"guestName": "D'Souza", "guestCount": 6, "time": "21:00", "table": 8}],
      "topDishes": [{"name": "Fish Curry Rice", "quantity": 14, "revenue": 4900},
                    {"name": "Chicken Xacuti", "quantity": 9, "revenue": 3420},
                    {"name": "Kingfisher Beer", "quantity": 22, "revenue": 3960},
                    {"name": "Bebinca", "quantity": 7, "revenue": 1260}]
    }
    """)
}

// MARK: - Floor

extension POSTable {
    static let sample: [POSTable] = SampleData.decode("""
    [
      {"id": "t1", "number": 1, "capacity": 4, "status": "OCCUPIED", "orders": [\(sampleOrder("t1", minutes: 42))]},
      {"id": "t2", "number": 2, "capacity": 2, "status": "AVAILABLE", "orders": []},
      {"id": "t3", "number": 3, "capacity": 4, "status": "BILL_REQUESTED", "orders": [\(sampleOrder("t3", minutes: 75))]},
      {"id": "t4", "number": 4, "capacity": 6, "status": "OCCUPIED", "orders": [\(sampleOrder("t4", minutes: 18))]},
      {"id": "t5", "number": 5, "capacity": 4, "status": "RESERVED", "orders": []},
      {"id": "t6", "number": 6, "capacity": 2, "status": "AVAILABLE", "orders": []},
      {"id": "t7", "number": 7, "capacity": 4, "status": "OCCUPIED", "orders": [\(sampleOrder("t7", minutes: 55))]},
      {"id": "t8", "number": 8, "capacity": 8, "status": "AVAILABLE", "orders": []},
      {"id": "t9", "number": 9, "capacity": 4, "status": "AVAILABLE", "orders": []},
      {"id": "t10", "number": 10, "capacity": 2, "status": "AVAILABLE", "orders": []},
      {"id": "t11", "number": 11, "capacity": 4, "status": "AVAILABLE", "orders": []},
      {"id": "t12", "number": 12, "capacity": 6, "status": "AVAILABLE", "orders": []}
    ]
    """) ?? []

    private static func sampleOrder(_ table: String, minutes: Int) -> String {
        """
        {"id": "o-\(table)", "orderNumber": "ORD-\(table)", "tableId": "\(table)", "type": "DINE_IN",
         "status": "PREPARING", "createdAt": "\(SampleData.ago(minutes))", "waiter": {"id": "w1", "name": "Pedro"},
         "items": [
           {"id": "\(table)-a", "quantity": 2, "unitPrice": 420, "status": "SERVED", "itemName": "Fish Curry Rice"},
           {"id": "\(table)-b", "quantity": 1, "unitPrice": 380, "status": "PREPARING", "itemName": "Chicken Xacuti"},
           {"id": "\(table)-c", "quantity": 3, "unitPrice": 180, "status": "PENDING", "itemName": "Kingfisher Beer"}]}
        """
    }
}

// MARK: - Till and Bills

extension TillBill {
    static let sample: [TillBill] = SampleData.decode("""
    [
      {"key": "k3", "anchorOrderId": "o3", "orderIds": ["o3"], "orderNumbers": ["ORD-0131"], "tableId": "t3",
       "tableNumber": 3, "type": "DINE_IN", "state": "bill", "waiter": "Pedro", "since": "\(SampleData.ago(75))",
       "billAskedAt": "\(SampleData.ago(6))", "lines": [\(lines)]},
      {"key": "k7", "anchorOrderId": "o7", "orderIds": ["o7"], "orderNumbers": ["ORD-0135"], "tableId": "t7",
       "tableNumber": 7, "type": "DINE_IN", "state": "served", "waiter": "Maria", "since": "\(SampleData.ago(55))",
       "lines": [\(lines)]},
      {"key": "k1", "anchorOrderId": "o1", "orderIds": ["o1"], "orderNumbers": ["ORD-0138"], "tableId": "t1",
       "tableNumber": 1, "type": "DINE_IN", "state": "cooking", "waiter": "Pedro", "since": "\(SampleData.ago(42))",
       "lines": [\(lines)]},
      {"key": "kp", "anchorOrderId": "op", "orderIds": ["op"], "orderNumbers": ["ORD-0140"],
       "type": "TAKEAWAY", "state": "cooking", "customer": {"name": "Rodrigues"}, "since": "\(SampleData.ago(12))",
       "lines": [\(lines)]}
    ]
    """) ?? []

    private static let lines = """
    {"id": "l1", "name": "Fish Curry Rice", "quantity": 2, "unitPrice": 420, "status": "SERVED", "taxClass": "GST"},
    {"id": "l2", "name": "Chicken Xacuti", "quantity": 1, "unitPrice": 380, "status": "SERVED", "taxClass": "GST"},
    {"id": "l3", "name": "Kingfisher Beer", "quantity": 3, "unitPrice": 180, "status": "SERVED", "taxClass": "VAT"}
    """
}

extension LedgerBill {
    static let sample: [LedgerBill] = SampleData.decode("""
    [
      \(row("b1", "0128", table: 4, waiter: "Pedro", method: "UPI", total: 2140, minutes: 20)),
      \(row("b2", "0127", table: 9, waiter: "Maria", method: "CASH", total: 980, minutes: 48)),
      \(row("b3", "0126", table: 2, waiter: "Pedro", method: "CARD", total: 3460, minutes: 75)),
      \(row("b4", "0125", table: 11, waiter: "Anil", method: "UPI", total: 1520, minutes: 96)),
      \(row("b5", "0124", table: 6, waiter: "Maria", method: "UPI", total: 760, minutes: 130)),
      \(row("b6", "0123", table: 1, waiter: "Anil", method: "CASH", total: 2890, minutes: 170))
    ]
    """) ?? []

    private static func row(_ id: String, _ no: String, table: Int, waiter: String, method: String, total: Int, minutes: Int) -> String {
        """
        {"id": "\(id)", "billNo": "\(no)", "orderIds": ["o\(id)"], "at": "\(SampleData.ago(minutes))",
         "where": "Table \(table)", "tableNumber": \(table), "waiter": "\(waiter)", "paid": true, "fromApp": false,
         "tenders": [{"method": "\(method)", "amount": \(total)}], "items": 5,
         "dishes": "Fish Curry Rice, Chicken Xacuti, Kingfisher Beer", "gross": \(total), "discount": 0,
         "gstTax": \(total / 20), "vatTax": 0, "total": \(total)}
        """
    }
}

extension LedgerSummary {
    static let sample = LedgerSummary(bills: 23, takings: 48250,
                                      byMethod: [.init(method: "UPI", amount: 26400), .init(method: "CASH", amount: 14100),
                                                 .init(method: "CARD", amount: 7750)],
                                      gstTax: 1980, vatTax: 2140, discount: 350, unpaid: 0)
}

// MARK: - Reports

extension CustomersReportData {
    static let sample: CustomersReportData? = SampleData.decode("""
    {"period": "30d", "totalCustomers": 214, "newCustomers": 61, "returningCustomers": 153, "avgCustomerValue": 1840,
     "retentionRate": 71.5, "avgVisitDays": 12,
     "topSpenders": [{"id": "c1", "name": "Fernandes", "orders": 9, "totalSpent": 21400, "avgOrder": 2378},
                     {"id": "c2", "name": "D'Souza", "orders": 7, "totalSpent": 16800, "avgOrder": 2400},
                     {"id": "c3", "name": "Rodrigues", "orders": 6, "totalSpent": 11200, "avgOrder": 1867}],
     "frequencyDistribution": [{"bucket": "1 visit", "customerCount": 61}, {"bucket": "2-3 visits", "customerCount": 98},
                               {"bucket": "4+ visits", "customerCount": 55}],
     "orderTypePreferences": [{"type": "DINE_IN", "uniqueCustomers": 180, "totalOrders": 410, "revenue": 742000},
                              {"type": "TAKEAWAY", "uniqueCustomers": 52, "totalOrders": 88, "revenue": 96400}]}
    """)
}

extension InventoryReportData {
    static let sample: InventoryReportData? = SampleData.decode("""
    {"totalItems": 48, "totalValue": 186400, "lowStockCount": 3, "overstockedCount": 1,
     "lowStockItems": [{"id": "i1", "name": "Kingfish", "unit": "kg", "currentStock": 2, "minimumStock": 5},
                       {"id": "i2", "name": "Coconut", "unit": "pcs", "currentStock": 8, "minimumStock": 20}],
     "topConsumed": [{"id": "i3", "name": "Rice", "unit": "kg", "totalConsumed": 42.5, "timesUsed": 160},
                     {"id": "i4", "name": "Onion", "unit": "kg", "totalConsumed": 31, "timesUsed": 210}],
     "suppliers": [{"supplier": "Mapusa Market", "itemCount": 18, "totalValue": 64200},
                   {"supplier": "Goa Fisheries", "itemCount": 6, "totalValue": 48800}]}
    """)
}

extension CAReportData {
    static let sample: CAReportData? = SampleData.decode("""
    {"year": 2026, "month": 9, "monthLabel": "September 2026", "totalSales": 1248600, "totalItems": 4312,
     "totalBills": 612, "totalGst": 41200, "totalVat": 38900,
     "categories": [{"type": "FOOD", "revenue": 842000, "percentage": 67.4},
                    {"type": "ALCOHOL", "revenue": 301600, "percentage": 24.2},
                    {"type": "BEVERAGE", "revenue": 105000, "percentage": 8.4}]}
    """)
}

// MARK: - Admin lists

extension AdminUserModel {
    static let sample: [AdminUserModel] = [
        .init(id: "u1", email: "", username: "admin", name: "Joshua Cardozo", role: "ADMIN", active: true),
        .init(id: "u2", email: "", username: "pedro", name: "Pedro Fernandes", role: "WAITER", active: true),
        .init(id: "u3", email: "", username: "maria", name: "Maria D'Souza", role: "WAITER", active: true),
        .init(id: "u4", email: "", username: "anil", name: "Anil Naik", role: "WAITER", active: true),
        .init(id: "u5", email: "", username: "anthony", name: "Anthony Rodrigues", role: "KITCHEN", active: true),
        .init(id: "u6", email: "", username: "cashier", name: "Sonia Pereira", role: "CASHIER", active: true),
    ]
}

extension AdminDiscount {
    static let sample: [AdminDiscount] = SampleData.decode("""
    [
      {"id": "d1", "code": "MONSOON10", "name": "Monsoon 10% off", "description": "On food", "type": "PERCENTAGE", "value": 10,
       "applicableTo": [], "usageCount": 42, "validFrom": "\(SampleData.ago(43_200))", "active": true},
      {"id": "d2", "code": "FLAT200", "name": "₹200 off over ₹1,500", "type": "FIXED", "value": 200, "minOrderValue": 1500,
       "applicableTo": [], "usageCount": 17, "validFrom": "\(SampleData.ago(20_000))", "active": true},
      {"id": "d3", "code": "STAFF", "name": "Staff meal", "type": "PERCENTAGE", "value": 50,
       "applicableTo": [], "usageCount": 88, "validFrom": "\(SampleData.ago(90_000))", "active": true}
    ]
    """) ?? []
}

extension AdminModifier {
    static let sample: [AdminModifier] = [
        .init(id: "m1", name: "Extra cheese", description: nil, price: 40, type: "ADD", categoryId: nil, category: nil, active: true, sortOrder: 0),
        .init(id: "m2", name: "Extra gravy", description: nil, price: 30, type: "ADD", categoryId: nil, category: nil, active: true, sortOrder: 1),
        .init(id: "m3", name: "Fried egg", description: nil, price: 25, type: "ADD", categoryId: nil, category: nil, active: true, sortOrder: 2),
        .init(id: "m4", name: "No onion", description: nil, price: 0, type: "REMOVE", categoryId: nil, category: nil, active: true, sortOrder: 0),
        .init(id: "m5", name: "Less spicy", description: nil, price: 0, type: "SPECIAL", categoryId: nil, category: nil, active: true, sortOrder: 0),
    ]
}

extension AdminIngredient {
    static let sample: [AdminIngredient] = [
        .init(id: "i1", name: "Kingfish", unit: "kg", currentStock: 2, minimumStock: 5, maximumStock: 20, costPerUnit: 900, supplier: "Goa Fisheries"),
        .init(id: "i2", name: "Basmati rice", unit: "kg", currentStock: 24, minimumStock: 10, maximumStock: 50, costPerUnit: 110, supplier: "Mapusa Market"),
        .init(id: "i3", name: "Coconut", unit: "pcs", currentStock: 8, minimumStock: 20, maximumStock: 60, costPerUnit: 35, supplier: "Mapusa Market"),
        .init(id: "i4", name: "Onion", unit: "kg", currentStock: 18, minimumStock: 8, maximumStock: 40, costPerUnit: 40, supplier: "Mapusa Market"),
        .init(id: "i5", name: "Kingfisher Beer", unit: "bottles", currentStock: 96, minimumStock: 48, maximumStock: 240, costPerUnit: 95, supplier: "United Breweries"),
    ]
}

extension AdminReservation {
    static let sample: [AdminReservation] = [
        .init(id: "r1", tableId: "t5", guestName: "Fernandes", guestPhone: "9800000000", guestCount: 4, date: SampleData.day(), time: "20:30",
              duration: 90, status: "CONFIRMED", notes: nil, table: .init(id: "t5", number: 5, capacity: 4, status: "RESERVED")),
        .init(id: "r2", tableId: "t8", guestName: "D'Souza", guestPhone: "9800000000", guestCount: 6, date: SampleData.day(), time: "21:00",
              duration: 120, status: "CONFIRMED", notes: "Birthday", table: .init(id: "t8", number: 8, capacity: 8, status: "AVAILABLE")),
        .init(id: "r3", tableId: "t2", guestName: "Rodrigues", guestPhone: "9800000000", guestCount: 2, date: SampleData.day(1), time: "13:00",
              duration: 90, status: "CONFIRMED", notes: nil, table: .init(id: "t2", number: 2, capacity: 2, status: "AVAILABLE")),
    ]
}

extension KitchenBoard {
    /// The rail's sample: food and drinks, a note, dishes at each stage
    static let sample: KitchenBoard = {
        let dishes = ["Fish Curry Rice", "Sanna", "Chicken Xacuti", "Prawn Balchão", "Pork Vindaloo", "Bombil Fry", "Kingfisher pint", "Fresh lime soda"]
        let states = ["PENDING", "PREPARING", "READY"]
        let tickets = [4, 9, 12, 7, 15, 2].enumerated().map { i, table in
            Ticket(id: "k\(i)", number: String(4812 + i), where: i == 2 ? "Takeaway" : "T\(table)", createdAt: "2026-01-01T13:00:00.000Z",
                   waiter: "Pedro", note: i == 1 ? "Birthday, bring a candle with the dessert" : nil,
                   lines: (0..<(2 + i % 3)).map { j in
                       Line(id: "k\(i)-\(j)", quantity: 1 + j % 2, name: dishes[(i + j) % 6], status: states[(i + j) % 3],
                            station: "kitchen", notes: nil, extras: [], cook: j == 0 ? "Rosa" : nil, assigned: false)
                   } + (i % 2 == 0 ? [Line(id: "k\(i)-b", quantity: 2, name: dishes[6 + i % 2], status: "PENDING", station: "bar", notes: nil, extras: [], cook: nil, assigned: false)] : []),
                   sentAt: nil)
        }
        return KitchenBoard(tickets: tickets, recent: [], barCategoryIds: nil, categories: [], generatedAt: "2026-01-01T13:00:00.000Z")
    }()
}

extension AdminCategory {
    static let sample: [AdminCategory] = [
        .init(id: "c1", name: "Starters", description: nil, sortOrder: 0, active: true, type: "FOOD"),
        .init(id: "c2", name: "Mains", description: nil, sortOrder: 1, active: true, type: "FOOD"),
        .init(id: "c3", name: "Beer", description: nil, sortOrder: 2, active: true, type: "ALCOHOL"),
    ]
}

extension AdminMenuItem {
    static let sample: [AdminMenuItem] = {
        let rows: [(String, String, Int)] = [
            ("c1", "Prawn Rava Fry", 420), ("c1", "Chicken Cafreal", 380), ("c1", "Beef Croquettes", 260),
            ("c2", "Fish Curry Rice", 420), ("c2", "Chicken Xacuti", 380), ("c2", "Pork Vindaloo", 400), ("c2", "Mushroom Xacuti", 300),
            ("c3", "Kingfisher Beer", 180), ("c3", "Tuborg Strong", 200),
        ]
        return rows.enumerated().map { i, r in
            let cat = AdminCategory.sample.first { $0.id == r.0 }!
            return AdminMenuItem(id: "m\(i)", name: r.1, description: "House recipe, served with bread", price: r.2,
                                 categoryId: r.0, category: AdminCategoryRef(id: cat.id, name: cat.name, type: cat.type),
                                 available: true, tags: [], sortOrder: i, variantTemplates: [])
        }
    }()
}

// MARK: - Settings

extension AppSettings {
    static let sample = AppSettings(
        restaurant: .init(name: "Durigo's Restaurant", address: "Main Road, Panjim, Goa", phone: "0832 000 0000",
                          email: "", gstin: "30AAAAA0000A1Z5", vatTin: "30000000000", socialHandle: ""),
        business: .init(openingTime: "11:00", closingTime: "23:00", orderPrefix: "ORD"),
        billing: .init(taxRate: 0.05, liquorTaxRate: 0.22, taxInclusive: true, taxLabel: "GST", currency: "INR",
                       locale: "en-IN", acceptCash: true, acceptCard: true, acceptUPI: true, acceptDigitalWallet: false,
                       printReceipt: true),
        inventory: .init(lowStockThreshold: 0.2, autoReorder: false, trackExpiry: false)
    )
}

extension ReportOverview {
    /// The Reports screen's sample, shaped to the period being loaded
    static func sample(range: ReportRange) -> ReportOverview {
        let today = ReportDate.today
        let count: Int
        let from: String
        switch range {
        case .today: count = 1; from = today
        case .month, .quarter: count = ReportDate.dayOfMonth(today); from = String(today.prefix(8)) + "01"
        case .week, .pick: count = 7; from = ReportDate.add(today, days: -6)
        }
        let takings = { (i: Int) in Double(28000 + (i * 7919) % 50000) }
        let figures = Figures(takings: 330620, bills: 412, averageBill: 802, discounts: 6240, cancelledDishes: 9, cancelledValue: 3180)
        let days = (0..<count).map { Day(date: ReportDate.add(from, days: $0), takings: takings($0), bills: 40 + ($0 % 9) * 3, topDish: "Fish Curry Rice") }
        return ReportOverview(
            period: Period(range: range == .pick ? "7d" : range.rawValue, from: from, to: today, prevFrom: from, prevTo: today,
                           label: "Fri 9 – Thu 15 Oct", prevLabel: "the week before", month: String(today.prefix(7))),
            figures: figures, previous: figures,
            days: days, previousDays: (0..<count).map { takings($0 + 3) }, bestDay: days.first,
            heat: Heat(hours: Array(12...23), cells: (0..<7).map { d in (0..<12).map { h in ((d + 1) * (h + 3)) % 11 } }),
            dishes: ["Fish Curry Rice", "Kingfisher pint", "Prawn Balchão", "Chicken Xacuti", "Cashew Feni peg", "Pork Vindaloo"].enumerated()
                .map { Dish(name: $1, quantity: Double(214 - $0 * 30), takings: Double(68480 - $0 * 10000)) },
            tenders: [Tender(method: "UPI", amount: 191800), Tender(method: "CASH", amount: 102500), Tender(method: "CARD", amount: 36320)],
            splitBills: 23, codes: [Code(code: "FENI10", uses: 14)],
            waiters: [Waiter(name: "Pedro", bills: 118, takings: 112400), Waiter(name: "Maria", bills: 104, takings: 98600), Waiter(name: "Anthony", bills: 77, takings: 61900)],
            ca: CAReportData.sample ?? CAReportData(year: 2026, month: 10, monthLabel: "October 2026", totalSales: 0, totalItems: 0, totalBills: 0, totalGst: 0, totalVat: 0, categories: [])
        )
    }
}
