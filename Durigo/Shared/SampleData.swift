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

extension ReportData {
    static let sample: ReportData? = SampleData.decode("""
    {"period": "7d", "startDate": "\(SampleData.ago(7 * 24 * 60))", "totalRevenue": 312400, "totalOrders": 164,
     "avgOrderValue": 1905,
     "topSellingItems": [{"name": "Fish Curry Rice", "category": "Mains", "quantity": 88, "orders": 71},
                         {"name": "Kingfisher Beer", "category": "Beer", "quantity": 120, "orders": 64},
                         {"name": "Chicken Xacuti", "category": "Mains", "quantity": 52, "orders": 47},
                         {"name": "Bebinca", "category": "Desserts", "quantity": 31, "orders": 29}],
     "categoryBreakdown": [{"category": "Mains", "orders": 120, "itemsSold": 240, "revenue": 168000},
                           {"category": "Beer", "orders": 64, "itemsSold": 120, "revenue": 21600},
                           {"category": "Desserts", "orders": 29, "itemsSold": 31, "revenue": 5580}],
     "hourlyDistribution": [{"hour": 12, "orders": 18}, {"hour": 13, "orders": 26}, {"hour": 19, "orders": 31},
                            {"hour": 20, "orders": 40}, {"hour": 21, "orders": 22}],
     "paymentMethods": [{"method": "UPI", "count": 92, "total": 176000}, {"method": "CASH", "count": 51, "total": 88400},
                        {"method": "CARD", "count": 21, "total": 48000}],
     "staffPerformance": [{"staffName": "Pedro", "role": "WAITER", "ordersHandled": 71, "revenueGenerated": 134000},
                          {"staffName": "Maria", "role": "WAITER", "ordersHandled": 58, "revenueGenerated": 112000}]}
    """)
}

extension SalesReportData {
    static let sample: SalesReportData? = SampleData.decode("""
    {"todayRevenue": 48250, "todayOrders": 23, "avgOrderValue": 2098, "totalCustomers": 61,
     "revenueChange": 12.4, "ordersChange": 6.1,
     "topItems": [{"id": "m1", "name": "Fish Curry Rice", "revenue": 4900, "orders": 14},
                  {"id": "m2", "name": "Chicken Xacuti", "revenue": 3420, "orders": 9},
                  {"id": "m3", "name": "Kingfisher Beer", "revenue": 3960, "orders": 22}],
     "hourlyData": [{"hour": 12, "revenue": 6200, "orders": 4}, {"hour": 13, "revenue": 9800, "orders": 6},
                    {"hour": 19, "revenue": 8700, "orders": 5}, {"hour": 20, "revenue": 11250, "orders": 7}],
     "paymentMethods": [{"method": "UPI", "amount": 26400, "count": 12}, {"method": "CASH", "amount": 14100, "count": 7},
                        {"method": "CARD", "amount": 7750, "count": 4}]}
    """)
}

extension PerformanceReportData {
    static let sample: PerformanceReportData? = SampleData.decode("""
    {"avgOrderTime": 18.5, "kitchenEfficiency": 0, "customerSatisfaction": 0, "staffProductivity": 62.5,
     "tableUtilization": 41.7, "orderAccuracy": 97.2,
     "staffPerformance": [{"name": "Pedro", "role": "WAITER", "ordersHandled": 71, "revenue": 134000},
                          {"name": "Maria", "role": "WAITER", "ordersHandled": 58, "revenue": 112000},
                          {"name": "Anil", "role": "WAITER", "ordersHandled": 35, "revenue": 66400}],
     "busyHours": [{"hour": 13, "orders": 26}, {"hour": 20, "orders": 40}, {"hour": 21, "orders": 22}],
     "alerts": [{"type": "warning", "title": "Slow tickets at 8pm", "message": "Orders took 31 minutes on average"}]}
    """)
}

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

extension StaffReportData {
    static let sample: StaffReportData? = SampleData.decode("""
    {"period": "30d", "activeStaffCount": 6, "totalRevenue": 838400, "totalOrders": 498, "avgRevenuePerStaff": 139733,
     "staffPerformance": [
       {"id": "u1", "name": "Pedro", "role": "WAITER", "ordersHandled": 171, "revenueGenerated": 312000, "avgOrder": 1825, "daysWorked": 26, "lastOrder": "\(SampleData.ago(30))"},
       {"id": "u2", "name": "Maria", "role": "WAITER", "ordersHandled": 158, "revenueGenerated": 288000, "avgOrder": 1823, "daysWorked": 25, "lastOrder": "\(SampleData.ago(50))"},
       {"id": "u3", "name": "Anil", "role": "WAITER", "ordersHandled": 112, "revenueGenerated": 196400, "avgOrder": 1754, "daysWorked": 20, "lastOrder": "\(SampleData.ago(90))"}],
     "roleStats": [{"role": "WAITER", "staffCount": 3, "totalOrders": 441, "totalRevenue": 796400, "avgOrder": 1806},
                   {"role": "CASHIER", "staffCount": 1, "totalOrders": 57, "totalRevenue": 42000, "avgOrder": 737}],
     "topPerformers": [{"name": "Pedro", "role": "WAITER", "recentOrders": 41, "recentRevenue": 78000},
                       {"name": "Maria", "role": "WAITER", "recentOrders": 37, "recentRevenue": 69000}]}
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

extension KitchenOrder {
    static let sample: [KitchenOrder] = SampleData.decode("""
    [
      \(order("k1", "0142", table: 4, status: "PENDING", minutes: 4, item: "PENDING")),
      \(order("k2", "0141", table: 9, status: "PENDING", minutes: 7, item: "PENDING")),
      \(order("k3", "0139", table: 1, status: "PREPARING", minutes: 16, item: "PREPARING")),
      \(order("k4", "0137", table: 7, status: "PREPARING", minutes: 22, item: "PREPARING")),
      \(order("k5", "0135", table: 3, status: "READY", minutes: 31, item: "READY"))
    ]
    """) ?? []

    private static func order(_ id: String, _ no: String, table: Int, status: String, minutes: Int, item: String) -> String {
        """
        {"id": "\(id)", "orderNumber": "ORD-\(no)", "status": "\(status)", "type": "DINE_IN",
         "createdAt": "\(SampleData.ago(minutes))", "table": {"number": \(table)}, "waiter": {"id": "w1", "name": "Pedro"},
         "items": [
           {"id": "\(id)-a", "quantity": 2, "status": "\(item)", "itemName": "Fish Curry Rice"},
           {"id": "\(id)-b", "quantity": 1, "status": "\(item)", "itemName": "Chicken Xacuti"},
           {"id": "\(id)-c", "quantity": 1, "status": "\(item)", "itemName": "Prawn Rava Fry"}]}
        """
    }
}

// MARK: - Menu

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
