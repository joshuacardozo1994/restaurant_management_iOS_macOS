//
//  SwiftDataModels.swift
//  Durigo
//
//  Created by Joshua Cardozo on 20/12/23.
//

import Foundation
import SwiftData

enum BillHistoryItemsSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [BillHistoryItem.self]
    }
    
    enum Status: String, Codable {
        case paid
        case pending
    }
    
    struct MenuItem: Identifiable, Equatable, Hashable, Codable {
        var id: UUID
        var name: String
        var prefix: String?
        var suffix: String?
        var quantity: Int
        var price: Int
        var servingSize: Category.Item.ServingSize?
    }

    @Model
    class BillHistoryItem: Identifiable {
        var id: UUID
        var date: Date
        var tableNumber: Int?
        var items: [MenuItem]
        var paymentStatus: Status
        
        init(id: UUID, items: [MenuItem], tableNumber: Int) {
            self.id = id
            self.date = Date()
            self.items = items
            self.tableNumber = tableNumber
            self.paymentStatus = Status.pending
        }
    }
}

enum BillHistoryItemsSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 1)

    static var models: [any PersistentModel.Type] {
        [BillHistoryItem.self]
    }
    
    enum Status: String, Codable, Equatable {
        case paidByCash
        case paidByUPI
        case paidByCard
        case pending
    }
    
    struct MenuItem: Identifiable, Equatable, Hashable, Codable {
        var id: UUID
        var name: String
        var prefix: String?
        var suffix: String?
        var quantity: Double
        var price: Double
        var servingSize: Category.Item.ServingSize?
    }

    @Model
    class BillHistoryItem: Identifiable {
        var id: UUID
        var date: Date
        var tableNumber: Int
        var items: [MenuItem]
        var paymentStatus: Status
        var waiter: String
        
        init(id: UUID, date: Date = Date(), items: [MenuItem], tableNumber: Int, paymentStatus: Status = .pending,  waiter: String) {
            self.id = id
            self.date = date
            self.items = items
            self.tableNumber = tableNumber
            self.paymentStatus = paymentStatus
            self.waiter = waiter
        }
        
        var totalAmount: Double {
            return items.reduce(0) { $0 + $1.price * $1.quantity }
        }
    }
}

enum BillHistoryItemsSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 2)

    static var models: [any PersistentModel.Type] {
        [BillHistoryItem.self]
    }
    
    enum Status: String, Codable, Equatable {
        case paidByCash
        case paidByUPI
        case paidByCard
        case pending
    }
    
    struct MenuItem: Identifiable, Equatable, Hashable, Codable {
        var id: UUID
        var name: String
        var prefix: String?
        var suffix: String?
        var quantity: Double
        var price: Double
        var servingSize: Category.Item.ServingSize?
        var tags: [String]?
    }

    @Model
    class BillHistoryItem: Identifiable {
        var id: UUID
        var date: Date
        var tableNumber: Int
        var items: [MenuItem]
        var paymentStatus: Status
        var waiter: String
        
        init(id: UUID, date: Date = Date(), items: [MenuItem], tableNumber: Int, paymentStatus: Status = .pending,  waiter: String) {
            self.id = id
            self.date = date
            self.items = items
            self.tableNumber = tableNumber
            self.paymentStatus = paymentStatus
            self.waiter = waiter
        }
        
        var totalAmount: Double {
            return items.reduce(0) { $0 + $1.price * $1.quantity }
        }
    }
}

enum BillHistoryItemsSchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 3)

    static var models: [any PersistentModel.Type] {
        [BillHistoryItem.self]
    }

    enum Status: String, Codable, Equatable {
        case paidByCash
        case paidByUPI
        case paidByCard
        case pending
    }

    struct MenuItem: Identifiable, Equatable, Hashable, Codable {
        var id: UUID
        var name: String
        var prefix: String?
        var suffix: String?
        var quantity: Double
        var price: Double
        var servingSize: Category.Item.ServingSize?
        var tags: [String]?
    }

    /// V4 originally had: id/date/tableNumber/items/paymentStatus/waiter/syncedAt.
    /// `discount` and `discountReason` were added in-place (without bumping
    /// the schema version) — SwiftData lightweight-migrates by adding them
    /// as nullable columns. A custom V5 stage was attempted but iOS 26's
    /// SwiftData crashes in NSCustomMigrationStage.init even for trivial
    /// "add optional field" cases when both versions declare distinct
    /// nested @Model classes.
    @Model
    class BillHistoryItem: Identifiable {
        var id: UUID
        var date: Date
        var tableNumber: Int
        var items: [MenuItem]
        var paymentStatus: Status
        var waiter: String
        var syncedAt: Date?
        var discount: Double?
        var discountReason: String?

        init(id: UUID, date: Date = Date(), items: [MenuItem], tableNumber: Int,
             paymentStatus: Status = .pending, waiter: String, syncedAt: Date? = nil,
             discount: Double? = nil, discountReason: String? = nil) {
            self.id = id
            self.date = date
            self.items = items
            self.tableNumber = tableNumber
            self.paymentStatus = paymentStatus
            self.waiter = waiter
            self.syncedAt = syncedAt
            self.discount = discount
            self.discountReason = discountReason
        }

        var subtotalAmount: Double {
            items.reduce(0) { $0 + $1.price * $1.quantity }
        }
        var totalAmount: Double {
            max(0, subtotalAmount - (discount ?? 0))
        }
    }
}

enum BillHistoryItemsSchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 4)

    static var models: [any PersistentModel.Type] {
        [BillHistoryItem.self]
    }

    enum Status: String, Codable, Equatable {
        case paidByCash
        case paidByUPI
        case paidByCard
        case pending
    }

    struct MenuItem: Identifiable, Equatable, Hashable, Codable {
        var id: UUID
        var name: String
        var prefix: String?
        var suffix: String?
        var quantity: Double
        var price: Double
        var servingSize: Category.Item.ServingSize?
        var tags: [String]?
    }

    /// V5 = V4 plus waiterId / customerName / customerPhone. A new version
    /// (not fields added to V4 in place): an in-place change makes every
    /// existing store need a migration that matches no declared version.
    @Model
    class BillHistoryItem: Identifiable {
        var id: UUID
        var date: Date
        var tableNumber: Int
        var items: [MenuItem]
        var paymentStatus: Status
        var waiter: String
        var syncedAt: Date?
        var discount: Double?
        var discountReason: String?
        /// V5: the picked waiter's user id, and the customer (if taken), so the
        /// server's staff and customer reports can count the bill
        var waiterId: String?
        var customerName: String?
        var customerPhone: String?

        init(id: UUID, date: Date = Date(), items: [MenuItem], tableNumber: Int,
             paymentStatus: Status = .pending, waiter: String, syncedAt: Date? = nil,
             discount: Double? = nil, discountReason: String? = nil,
             waiterId: String? = nil, customerName: String? = nil, customerPhone: String? = nil) {
            self.id = id
            self.date = date
            self.items = items
            self.tableNumber = tableNumber
            self.paymentStatus = paymentStatus
            self.waiter = waiter
            self.syncedAt = syncedAt
            self.discount = discount
            self.discountReason = discountReason
            self.waiterId = waiterId
            self.customerName = customerName
            self.customerPhone = customerPhone
        }

        var subtotalAmount: Double {
            items.reduce(0) { $0 + $1.price * $1.quantity }
        }
        var totalAmount: Double {
            max(0, subtotalAmount - (discount ?? 0))
        }
    }
}

typealias MenuItem = BillHistoryItemsSchemaV5.MenuItem
typealias BillHistoryItem = BillHistoryItemsSchemaV5.BillHistoryItem
typealias BillHistoryItemStatus = BillHistoryItemsSchemaV5.Status

enum BillHistoryItemsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        // V2 is left out: its BillHistoryItem hashes the same as V3's, and
        // SwiftData refuses a plan with two identical versions the moment any
        // migration runs ("Duplicate version checksums across stages").
        // A V1 store goes straight to V3, which is what V2 was on disk.
        [BillHistoryItemsSchemaV1.self, BillHistoryItemsSchemaV3.self, BillHistoryItemsSchemaV4.self, BillHistoryItemsSchemaV5.self]
    }

    static var savedV1BillHistoryItems = [BillHistoryItemsSchemaV1.BillHistoryItem]()
    
    static let migrateV1toV3 = MigrationStage.custom(
        fromVersion: BillHistoryItemsSchemaV1.self,
        toVersion: BillHistoryItemsSchemaV3.self,
        willMigrate: { context in
            let oldBillHistoryItems = try context.fetch(FetchDescriptor<BillHistoryItemsSchemaV1.BillHistoryItem>())
            savedV1BillHistoryItems = oldBillHistoryItems
            oldBillHistoryItems.forEach { oldBillHistoryItem in
                context.delete(oldBillHistoryItem)
            }
            try context.save()
        }, didMigrate: { context in
            savedV1BillHistoryItems.forEach { oldBillHistoryItem in
                let items = oldBillHistoryItem.items.map { oldMenuItem in
                    BillHistoryItemsSchemaV3.MenuItem(id: oldMenuItem.id, name: oldMenuItem.name, prefix: oldMenuItem.prefix, suffix: oldMenuItem.suffix, quantity: Double(oldMenuItem.quantity), price: Double(oldMenuItem.price), servingSize: oldMenuItem.servingSize, tags: nil)
                }
                context.insert(BillHistoryItemsSchemaV3.BillHistoryItem(id: oldBillHistoryItem.id, items: items, tableNumber: oldBillHistoryItem.tableNumber ?? 0, paymentStatus: oldBillHistoryItem.paymentStatus == .pending ? .pending : .paidByCash, waiter: "unknown"))
            }
            
            try context.save()
        }
    )
    
    // V3 added `tags` only inside the non-@Model `MenuItem` struct (a JSON blob
    // from SwiftData's perspective) and a Status enum that's structurally identical
    // to V2's. The @Model fields are unchanged. SwiftData on iOS 26 hashes V2 and
    // V3 BillHistoryItem identically and refuses to construct an
    // NSCustomMigrationStage for them — so this has to be lightweight.
    // The `tags` optional decodes as nil for old rows automatically.
    
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: BillHistoryItemsSchemaV3.self,
        toVersion: BillHistoryItemsSchemaV4.self
    )

    // Three optional columns: lightweight
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: BillHistoryItemsSchemaV4.self,
        toVersion: BillHistoryItemsSchemaV5.self
    )

    static var stages: [MigrationStage] {
        [migrateV1toV3, migrateV3toV4, migrateV4toV5]
    }
}
