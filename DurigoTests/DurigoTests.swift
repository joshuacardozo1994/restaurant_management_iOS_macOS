//
//  DurigoTests.swift
//  DurigoTests
//
//  Created by Joshua Cardozo on 27/10/23.
//

import XCTest
import SwiftUI
import SwiftData
@testable import Durigo

// The rendering tests run on iPhone and on the Mac
extension ImageRenderer {
    @MainActor var platformImage: PlatformImage? {
        #if os(iOS)
        uiImage
        #else
        nsImage
        #endif
    }
}
#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

final class DurigoTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }
    
    func testShouldFilterMenuWithQuery() {
        // Case 1: Exact match
        XCTAssertTrue(Helper.shouldFilterMenuWithQuery(searchQuery: "Pizza", itemName: "Pizza", itemSuffix: nil))

        // Case 2: Item name contains the search string
        XCTAssertTrue(Helper.shouldFilterMenuWithQuery(searchQuery: "Burger", itemName: "Cheeseburger", itemSuffix: nil))

        // Case 3: Item name does not contain the search string
        XCTAssertFalse(Helper.shouldFilterMenuWithQuery(searchQuery: "Pasta", itemName: "Pizza", itemSuffix: nil))

        // Case 4: Similar string within threshold
        XCTAssertTrue(Helper.shouldFilterMenuWithQuery(searchQuery: "CheeseBurgeri", itemName: "CheeseBurger", itemSuffix: nil))

        // Case 5: Longer searches tolerate one typo per four letters (Helper's
        // dynamic threshold, Feb 2026): 12 letters allow 3 edits, not 4+
        XCTAssertTrue(Helper.shouldFilterMenuWithQuery(searchQuery: "CheeseBurger", itemName: "CheeseBur", itemSuffix: nil))
        XCTAssertFalse(Helper.shouldFilterMenuWithQuery(searchQuery: "CheeseBurger", itemName: "Chees", itemSuffix: nil))
        XCTAssertFalse(Helper.shouldFilterMenuWithQuery(searchQuery: "CheeseBurger", itemName: "Chicken Pulao", itemSuffix: nil))

        // Case 6: Suffix matches the search string
        XCTAssertTrue(Helper.shouldFilterMenuWithQuery(searchQuery: "Special", itemName: "Pizza", itemSuffix: "Pizza Special"))

        // Case 7: Neither item name nor suffix match
        XCTAssertFalse(Helper.shouldFilterMenuWithQuery(searchQuery: "Special", itemName: "Burger", itemSuffix: "Burger Deluxe"))

        // Add more test cases to cover different scenarios
    }
    
    func testQuantityAndStringExtraction() {
        // Case 1: "4 sanna"
        var result = Helper.extractNumberAndString(from: "4 sanna")
        XCTAssertEqual(result.0, 4)
        XCTAssertEqual(result.1, "sanna")
        
        // Case 2: "4"
        result = Helper.extractNumberAndString(from: "4")
        XCTAssertEqual(result.0, 4)
        XCTAssertNil(result.1)
        
        // Case 3: "sanna"
        result = Helper.extractNumberAndString(from: "sanna")
        XCTAssertNil(result.0)
        XCTAssertEqual(result.1, "sanna")
        
        // Case 4: "sanna 4"
        result = Helper.extractNumberAndString(from: "sanna 4")
        XCTAssertEqual(result.0, 4)
        XCTAssertEqual(result.1, "sanna")
        
        // Case 5: Empty String
        result = Helper.extractNumberAndString(from: "")
        XCTAssertNil(result.0)
        XCTAssertNil(result.1)
        
        // Add more test cases as needed
        
    }
    
    // Bill maths: the same cases as the server's tests/billing/bill-math.test.ts,
    // so a receipt printed here matches what the server records on upload
    func testBillMathMatchesServer() {
        let durigos = BillingConfig(taxRate: 0.05, liquorTaxRate: 0.22, taxInclusive: true)
        let inclusive18 = BillingConfig(taxRate: 0.18, liquorTaxRate: 0.22, taxInclusive: true)
        let exclusive18 = BillingConfig(taxRate: 0.18, liquorTaxRate: 0.22, taxInclusive: false)

        XCTAssertEqual(BillMath.computeBill(gst: 1180, vat: 0, discount: 0, config: inclusive18),
                       BillAmounts(gross: 1180, discount: 0, subtotal: 1000, tax: 180, gstTax: 180, vatTax: 0, total: 1180))
        XCTAssertEqual(BillMath.computeBill(gst: 1180, vat: 0, discount: 118, config: inclusive18),
                       BillAmounts(gross: 1180, discount: 118, subtotal: 900, tax: 162, gstTax: 162, vatTax: 0, total: 1062))
        XCTAssertEqual(BillMath.computeBill(gst: 1000, vat: 0, discount: 100, config: exclusive18),
                       BillAmounts(gross: 1000, discount: 100, subtotal: 900, tax: 162, gstTax: 162, vatTax: 0, total: 1062))
        XCTAssertEqual(BillMath.computeBill(gst: 840, vat: 610, discount: 0, config: durigos),
                       BillAmounts(gross: 1450, discount: 0, subtotal: 1300, tax: 150, gstTax: 40, vatTax: 110, total: 1450))

        let discounted = BillMath.computeBill(gst: 840, vat: 610, discount: 145, config: durigos)
        XCTAssertEqual(discounted.total, 1305)
        XCTAssertEqual(discounted.gstTax, 36)
        XCTAssertEqual(discounted.vatTax, 99)

        XCTAssertEqual(BillMath.computeBill(gst: 500, vat: 0, discount: 5000, config: inclusive18).total, 0)
        XCTAssertEqual(BillMath.computeBill(gst: 500, vat: 0, discount: -50, config: inclusive18).total, 500)
    }

    func testBillMathAllocateAndTaxClass() {
        XCTAssertEqual(BillMath.allocate(100, weights: [1, 1, 1]).sorted(), [33, 33, 34])
        XCTAssertEqual(BillMath.allocate(118, weights: [600, 400]), [71, 47])
        XCTAssertEqual(BillMath.allocate(50, weights: [0, 0]), [50, 0])

        XCTAssertEqual(BillMath.taxClass(categoryType: "ALCOHOL", name: "Mojito"), .vat)
        XCTAssertEqual(BillMath.taxClass(categoryType: "BEVERAGE", name: "Beer"), .gst)
        XCTAssertEqual(BillMath.taxClass(categoryType: nil, name: "Kingfisher Ultra"), .vat)
        XCTAssertEqual(BillMath.taxClass(categoryType: nil, name: "Prawn curry"), .gst)
        for food in ["Virgin Mojito", "Ginger Chicken", "Chicken Drumsticks", "Half portion", "Original Thali"] {
            XCTAssertEqual(BillMath.taxClass(categoryType: nil, name: food), .gst, food)
        }
        for liquor in ["Kingfisher Beers", "Gin & Tonic", "Old Monk Rum", "Port wine", "Cashew feni"] {
            XCTAssertEqual(BillMath.taxClass(categoryType: nil, name: liquor), .vat, liquor)
        }
    }

    func testBillGeneratorBillMatchesItemsToMenu() {
        let menu = [
            Category(id: UUID(), type: .food, name: "Mains",
                     items: [Category.Item(id: UUID(), name: "Fish Thali", price: 420, prefix: nil, suffix: nil,
                                           visibilityScope: .both, description: nil, servingSizes: nil, tags: nil)],
                     taxType: "FOOD"),
            Category(id: UUID(), type: .drinks, name: "Cocktails",
                     items: [Category.Item(id: UUID(), name: "Mojito", price: 305, prefix: nil, suffix: nil,
                                           visibilityScope: .both, description: nil, servingSizes: nil, tags: nil)],
                     taxType: "ALCOHOL"),
        ]
        let items = [
            MenuItem(id: UUID(), name: "Fish Thali", quantity: 2, price: 420),
            MenuItem(id: UUID(), name: "mojito ", quantity: 2, price: 305),  // matched case- and space-insensitively
            MenuItem(id: UUID(), name: "Half portion", quantity: 0.5, price: 155), // rounds to ₹78, like the server
        ]
        let bill = BillMath.computeBill(items: items, menu: menu, config: .default)
        XCTAssertEqual(bill.gross, 840 + 610 + 78)
        XCTAssertEqual(bill.vatTax, 110)
        XCTAssertEqual(bill.gstTax, 44) // (840 + 78) × 5/105
        XCTAssertEqual(items.getTotal(), bill.total)
    }

    /// Renders a sample receipt (food, soft drink, liquor, a custom item) to an
    /// image attached to the test results, for reviewing the GST/VAT lines
    @MainActor
    func testRenderReceiptForReview() throws {
        let menu = [
            Category(id: UUID(), type: .food, name: "Mains",
                     items: [Category.Item(id: UUID(), name: "Chonok", price: 750, prefix: nil, suffix: nil,
                                           visibilityScope: .both, description: nil, servingSizes: nil, tags: nil)],
                     taxType: "FOOD"),
            Category(id: UUID(), type: .drinks, name: "Beverages",
                     items: [Category.Item(id: UUID(), name: "Fresh Ginger Lemon Soda", price: 120, prefix: nil, suffix: nil,
                                           visibilityScope: .both, description: nil, servingSizes: nil, tags: nil)],
                     taxType: "BEVERAGE"),
            Category(id: UUID(), type: .drinks, name: "Cocktails",
                     items: [Category.Item(id: UUID(), name: "Mojito", price: 320, prefix: nil, suffix: nil,
                                           visibilityScope: .both, description: nil, servingSizes: nil, tags: nil)],
                     taxType: "ALCOHOL"),
        ]
        let items = [
            MenuItem(id: UUID(), name: "Chonok", quantity: 1, price: 750),
            MenuItem(id: UUID(), name: "Fresh Ginger Lemon Soda", quantity: 2, price: 120),
            MenuItem(id: UUID(), name: "Mojito", quantity: 2, price: 320),
            MenuItem(id: UUID(), name: "Kingfisher pint", quantity: 1, price: 200), // custom item, liquor by name
        ]
        let config = BillingConfig.default
        let amounts = BillMath.computeBill(items: items, menu: menu, config: config)
        // Food+soft drinks ₹990 → GST 47; liquor ₹840 → VAT 151
        XCTAssertEqual(amounts.total, 1830)
        XCTAssertEqual(amounts.gstTax, 47)
        XCTAssertEqual(amounts.vatTax, 151)

        let view = Bill(currentMenuItems: items, tableNumber: 7, first: true, finalTotal: items.getTotal(),
                        taxes: ReceiptTaxes(amounts: amounts, config: config))
            .frame(width: 420, height: 595)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.platformImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "receipt-review"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A bill the app can't read (here a POS order's "pos-order:…" id) is
    /// skipped; it used to fail the whole page and empty the bill history
    func testBillsPageSkipsAnUnreadableBill() throws {
        let json = """
        {"items":[
          {"id":"pos-order:abc","date":813704511,"tableNumber":0,"items":[],"paymentStatus":"paidByCash","waiter":"QA"},
          {"id":"E6728DC6-CE50-5387-813E-033A2255C76B","date":813704511,"tableNumber":4,
           "items":[{"id":"96F1330B-AA72-51A4-8624-69702063C26F","name":"Soda","quantity":1,"price":20}],
           "paymentStatus":"pending","waiter":"QA"}
        ],"nextCursor":"2026-10-14T21:00:00.000Z"}
        """
        let page = try JSONDecoder().decode(BillsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.tableNumber, 4)
        XCTAssertEqual(page.nextCursor, "2026-10-14T21:00:00.000Z")
    }

    /// The Reports screen's data as the server sends it (a cashier's has no waiters)
    func testReportOverviewDecodesTheServersShape() throws {
        let json = """
        {"period":{"range":"month","from":"2026-10-01","to":"2026-10-15","prevFrom":"2026-09-01","prevTo":"2026-09-15",
          "label":"October 2026","prevLabel":"September at this point","month":"2026-10"},
         "figures":{"takings":1700,"bills":2,"averageBill":850,"discounts":100,"cancelledDishes":2,"cancelledValue":1200},
         "previous":{"takings":0,"bills":0,"averageBill":0,"discounts":0,"cancelledDishes":0,"cancelledValue":0},
         "days":[{"date":"2026-10-15","takings":1700,"bills":2,"topDish":"Thali"}],"previousDays":[0],
         "bestDay":{"date":"2026-10-15","takings":1700,"bills":2,"topDish":"Thali"},
         "heat":{"hours":[13],"cells":[[0],[0],[0],[2],[0],[0],[0]]},
         "dishes":[{"name":"Thali","quantity":3,"takings":1800}],"tenders":[{"method":"UPI","amount":1500}],
         "splitBills":1,"codes":[{"code":"FENI10","uses":1}],"waiters":null,
         "ca":{"year":2026,"month":10,"monthLabel":"October 2026","totalSales":1700,"totalItems":3,"totalBills":2,"totalGst":81,"totalVat":0,
           "categories":[{"type":"FOOD","revenue":1700,"percentage":100}]}}
        """
        let r = try JSONDecoder().decode(ReportOverview.self, from: Data(json.utf8))
        XCTAssertNil(r.waiters)
        XCTAssertEqual(r.figures.takings, 1700)
        XCTAssertEqual(ReportDate.weekdayIndex(r.days[0].date), 3) // Thursday
        XCTAssertTrue(CAText.text(r.ca).contains("Total Bills: 2"))
        XCTAssertEqual(ReportCSV.cell("=SUM(A1)"), "'=SUM(A1)")
    }

    /// The sign-in screen, rendered offscreen (on the Mac this is the Mac
    /// layout: brand panel beside the form), for the screen review
    @MainActor
    func testRenderLoginForReview() throws {
        for (name, size) in [("login-wide", CGSize(width: 1100, height: 700)), ("login-narrow", CGSize(width: 402, height: 874))] {
            let view = LoginView()
                .environment(Session())
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.platformImage, "\(name) didn't render")
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }


    /// Money reads the same as on the web: whole rupees, Indian grouping,
    /// whatever region the device is set to
    func testRupeesAreWholeWithIndianGrouping() {
        XCTAssertEqual(102610.0.rupees, "₹1,02,610")
        XCTAssertEqual(500.0.rupees, "₹500")
        XCTAssertEqual(77.5.rupees, "₹78")
        XCTAssertEqual(1234567.rupees, "₹12,34,567")
        XCTAssertEqual(500.0.asCurrencyString(locale: Locale(identifier: "en_US")), "₹500")
    }

    /// 2.8: a long bill runs over several pages; only the last carries the
    /// total and tax lines, so it holds fewer items (13) than the others (19)
    @MainActor
    func testLongBillSplitsAcrossPages() throws {
        func items(_ n: Int) -> [MenuItem] {
            (1...n).map { MenuItem(id: UUID(), name: "Item \($0) with a fairly long name", quantity: 1, price: 100) }
        }
        XCTAssertEqual(BillRenderer.pages(items(13)).map(\.count), [13])
        XCTAssertEqual(BillRenderer.pages(items(14)).map(\.count), [13, 1])
        XCTAssertEqual(BillRenderer.pages(items(19)).map(\.count), [13, 6])
        XCTAssertEqual(BillRenderer.pages(items(25)).map(\.count), [19, 6])
        XCTAssertEqual(BillRenderer.pages(items(32)).map(\.count), [19, 13])
        XCTAssertEqual(BillRenderer.pages(items(40)).map(\.count), [19, 19, 2])
        // Every item lands on exactly one page, in order
        let long = items(40)
        XCTAssertEqual(BillRenderer.pages(long).flatMap { $0 }.map(\.id), long.map(\.id))

        // Render the 25-item bill page by page for review
        let pages = BillRenderer.pages(items(25))
        for index in pages.indices {
            let renderer = ImageRenderer(content: BillRenderer.page(index, of: pages, tableNumber: 4, finalTotal: 2500,
                                                                    taxes: nil))
            renderer.scale = 2
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.platformImage))
            attachment.name = "long-bill-page-\(index + 1)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Renders a kitchen ticket (with item and order notes) to an image
    /// attached to the test results, for reviewing the 80mm layout
    @MainActor
    func testRenderKitchenTicketForReview() throws {
        let json = """
        {"id":"o1","orderNumber":"ORD-320394-6773","status":"PENDING","type":"DELIVERY",
         "createdAt":"2026-10-14T12:18:00.000Z","table":null,"waiter":{"id":"w","name":"QA Waiter"},
         "notes":"Ring the bell twice | Customer: Maria | Phone: 9876500000 | Address: House 12, Colva beach road",
         "items":[{"id":"i1","quantity":1,"status":"PENDING","notes":"no nuts, less spicy","menuItem":{"id":"m1","name":"Veg. Soup"},"itemName":null,"preparedBy":null,"assignedTo":null},
                  {"id":"i2","quantity":2,"status":"PENDING","notes":null,"menuItem":{"id":"m2","name":"Coca-cola"},"itemName":null,"preparedBy":null,"assignedTo":null},
                  {"id":"i3","quantity":1,"status":"CANCELLED","notes":null,"menuItem":{"id":"m3","name":"Cancelled thing"},"itemName":null,"preparedBy":null,"assignedTo":null}]}
        """
        let order = try JSONDecoder().decode(KitchenOrder.self, from: Data(json.utf8))
        XCTAssertFalse(KitchenPrinter.pdf(for: order).isEmpty)

        let renderer = ImageRenderer(content: KitchenTicketView(order: order))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.platformImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "kitchen-ticket"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Settings fill in the receipt header, but never the setup wizard's
    /// example values or blanks: those keep Durigo's own details
    func testRestaurantIdentityIgnoresPlaceholders() {
        let fromPlaceholders = RestaurantIdentity.durigos.merging(
            name: "Spice Garden Restaurant", address: " ", phone: "+91 98765 43210",
            gstin: "29ABCDE1234F1Z5", vatTin: nil)
        XCTAssertEqual(fromPlaceholders, .durigos)

        let real = RestaurantIdentity.durigos.merging(
            name: "Durigo's Bar & Restaurant", address: "Colva Beach Road", phone: nil,
            gstin: "30AEJPR6889P1ZI", vatTin: "30031114703")
        XCTAssertEqual(real.name, "Durigo's Bar & Restaurant")
        XCTAssertEqual(real.address, "Colva Beach Road")
        XCTAssertEqual(real.phone, RestaurantIdentity.durigos.phone)
    }

    /// Every skeleton's sample data still decodes into its model (a sample
    /// that drifted from the model would leave that skeleton empty)
    func testSkeletonSamplesDecode() {
        XCTAssertNotNil(ServiceNight.sample)
        XCTAssertEqual(ReportOverview.sample(range: .week).days.count, 7)
        XCTAssertNotNil(CustomersReportData.sample)
        XCTAssertNotNil(InventoryReportData.sample)
        XCTAssertNotNil(CAReportData.sample)
        XCTAssertEqual(POSTable.sample.count, 12)
        XCTAssertFalse(POSTable.sample[0].liveOrders.isEmpty)
        XCTAssertEqual(TillBill.sample.count, 4)
        XCTAssertEqual(LedgerBill.sample.count, 6)
        XCTAssertEqual(KitchenOrder.sample.count, 5)
        XCTAssertEqual(AdminDiscount.sample.count, 3)
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }
    
}
