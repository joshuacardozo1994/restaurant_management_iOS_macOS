//
//  DurigoTests.swift
//  DurigoTests
//
//  Created by Joshua Cardozo on 27/10/23.
//

import XCTest
import SwiftUI
@testable import Durigo

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

        // Case 5: Similar string but beyond threshold
        XCTAssertFalse(Helper.shouldFilterMenuWithQuery(searchQuery: "CheeseBurger", itemName: "CheeseBur", itemSuffix: nil))

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
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "receipt-review"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }
    
}
