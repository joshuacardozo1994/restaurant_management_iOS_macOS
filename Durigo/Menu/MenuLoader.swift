//
//  MenuLoader.swift
//  pdf test
//
//  Loads the live menu from the web backend (/api/menu/full) and holds the
//  in-progress bill for the Bill Generator.
//

import SwiftUI

@Observable class MenuLoader: ObservableObject {
    private let urlSession = NetworkHelper.shared.currentSession

    var menu: [Category]?
    /// Tax rates for receipts, from the server's settings. Starts from the last
    /// copy saved on this device (or the restaurant's rates), so a bill printed
    /// offline still shows its GST and VAT.
    var billingConfig: BillingConfig = MenuLoader.savedBillingConfig()
    /// Restaurant details for receipts, from settings (saved for offline printing)
    var identity: RestaurantIdentity = MenuLoader.savedIdentity()
    var billID = UUID()
    var tableNumber: Int?
    var waiter: String?
    private var _billItems: [MenuItem] = []
    var billItems: [MenuItem] {
        get { _billItems }
        set { _billItems = newValue.filter { $0.quantity > 0 } }
    }

    /// Holds a weak reference to the auth Session so we can read the current
    /// JWT cookie for menu fetches. Set this from views that have @Environment
    /// access (e.g. Home / BillGenerator).
    weak var authSession: Session?

    #if DEBUG
    func loadFromBundle() {
        self.menu = MockDataLoader.loadCategories()
    }
    #endif

    func resetBill() {
        billItems.removeAll()
        tableNumber = nil
        waiter = nil
        billID = UUID()
    }

    @MainActor
    func loadMenu() async {
        let baseString = Config.shared.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseString)/api/menu/full") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = authSession?.token {
            request.setValue("auth-token=\(token)", forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                authSession?.signOut()
                return
            }
            let decoder = JSONDecoder()
            let menu = try decoder.decode([Category].self, from: data)
            self.menu = menu
        } catch {
            print("MenuLoader.loadMenu error:", error)
        }
        await loadBillingConfig()
    }

    private static let billingConfigKey = "billingConfig"
    private static let identityKey = "restaurantIdentity"

    private static func savedIdentity() -> RestaurantIdentity {
        guard let data = UserDefaults.standard.data(forKey: identityKey),
              let saved = try? JSONDecoder().decode(RestaurantIdentity.self, from: data) else { return .durigos }
        return saved
    }

    private static func savedBillingConfig() -> BillingConfig {
        guard let data = UserDefaults.standard.data(forKey: billingConfigKey),
              let saved = try? JSONDecoder().decode(BillingConfig.self, from: data) else { return .default }
        return saved
    }

    @MainActor
    func loadBillingConfig() async {
        let baseString = Config.shared.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseString)/api/admin/settings") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = authSession?.token {
            request.setValue("auth-token=\(token)", forHTTPHeaderField: "Cookie")
        }
        struct Settings: Decodable {
            struct Billing: Decodable {
                let taxRate: Double?
                let liquorTaxRate: Double?
                let taxInclusive: Bool?
            }
            struct Restaurant: Decodable {
                let name: String?
                let address: String?
                let phone: String?
                let gstin: String?
                let vatTin: String?
            }
            let billing: Billing
            let restaurant: Restaurant?
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            let billing = settings.billing
            if let r = settings.restaurant {
                let merged = RestaurantIdentity.durigos.merging(name: r.name, address: r.address, phone: r.phone,
                                                               gstin: r.gstin, vatTin: r.vatTin)
                identity = merged
                UserDefaults.standard.set(try JSONEncoder().encode(merged), forKey: Self.identityKey)
            }
            let config = BillingConfig(
                taxRate: billing.taxRate ?? BillingConfig.default.taxRate,
                liquorTaxRate: billing.liquorTaxRate ?? BillingConfig.default.liquorTaxRate,
                taxInclusive: billing.taxInclusive ?? BillingConfig.default.taxInclusive
            )
            billingConfig = config
            UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: Self.billingConfigKey)
        } catch {
            print("MenuLoader.loadBillingConfig error:", error)
        }
    }
}
