//
//  MenuList.swift
//  pdf test
//
//  Created by Joshua Cardozo on 15/10/23.
//

import SwiftUI

struct MenuList: View {
    @EnvironmentObject private var menuLoader: MenuLoader
    @Environment(\.dismiss) var dismiss
    @State private var searchQuery = ""
    @State private var isShowingVoiceOrder = false

    func getFilteredResults() -> [Category]? {
        guard let categories = menuLoader.menu else { return nil }
        if searchQuery.isEmpty {
            return categories
        } else {
            let filteredCategories = categories.map { category in
                Category(id: category.id, type: category.type, name: category.name, items: category.items.filter({ item in
                    let matchedCurrentCategory = Helper.shouldFilterMenuWithQuery(searchQuery: searchQuery, itemName: category.name, itemSuffix: nil)
                    let matchedItem = Helper.shouldFilterMenuWithQuery(searchQuery: searchQuery, itemName: item.name, itemSuffix: item.suffix)
                    return matchedCurrentCategory || matchedItem
                }))
                
                
            }
            return filteredCategories.filter { category in
                !category.items.isEmpty
            }
        }
    }
    
    func addToMenu(menuItem: Category.Item) {
        if !menuLoader.billItems.contains(where: { $0.id == menuItem.id
        }) {
            var name = menuItem.name
            if let suffix = menuItem.suffix {
                name += " (\(suffix))"
            }
            let (quantity, _) = Helper.extractNumberAndString(from: searchQuery.lowercased())
            
            menuLoader.billItems.append(MenuItem(id: menuItem.id, name: name, prefix: menuItem.prefix, suffix: menuItem.suffix, quantity: max(1.0, Double(quantity ?? 1) ), price: menuItem.price, tags: menuItem.tags))
        }
        #if os(iOS)
                let impactMed = UIImpactFeedbackGenerator(style: .medium)
                impactMed.impactOccurred()
        #endif
    }
    
    func randomiseServingSizeUUIDs() {
        menuLoader.billItems = menuLoader.billItems.map { billItem in
            var newBillItem = billItem
            if newBillItem.servingSize != nil {
                newBillItem.id = UUID()
            }
            return newBillItem
        }
    }
    
    
    
    /// Picks a serving size for a dish in the bill (adding it first if needed)
    private func choose(_ servingSize: Category.Item.ServingSize, for menuItem: Category.Item) {
        addToMenu(menuItem: menuItem)
        menuLoader.billItems = menuLoader.billItems.map { billItem in
            guard billItem.id == menuItem.id else { return billItem }
            var item = billItem
            item.servingSize = servingSize
            item.price = Double(Helper.evaluateExpression(expression: servingSize.expression, withValue: Double(menuItem.price)) ?? 0)
            return item
        }
    }

    /// Adds the dish, in its first serving size when it has sizes
    private func add(_ menuItem: Category.Item) {
        if let first = menuItem.servingSizes?.first {
            choose(first, for: menuItem)
        } else {
            addToMenu(menuItem: menuItem)
        }
    }

    private func addHalf(_ menuItem: Category.Item) {
        if !menuLoader.billItems.contains(where: { $0.id == menuItem.id }) { add(menuItem); return }
        menuLoader.billItems = menuLoader.billItems.map { item in
            var item = item
            if item.id == menuItem.id { item.quantity += 0.5 }
            return item
        }
    }

    var body: some View {
        NavigationStack {
            let items = getFilteredResults() ?? [Category.placeholder, Category.placeholder]
            List(items) { category in
                Section(category.name) {
                    ForEach(category.items.filter({ [Category.Item.VisibilityScope.bill, Category.Item.VisibilityScope.both].contains($0.visibilityScope) })) { menuItem in
                        row(menuItem)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            // Until the menu arrives the list shows placeholder categories
            .skeleton(menuLoader.menu == nil)
            .overlay {
                if let results = getFilteredResults(), results.isEmpty, !searchQuery.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                }
            }
            .searchable(text: $searchQuery, prompt: "Dish, or \"4 soda\"")
            .autocorrectionDisabled()
            .navigationTitle("Menu")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Voice order", systemImage: "mic") { isShowingVoiceOrder = true }
                    Button("Add sizes as new lines", systemImage: "arrow.2.circlepath") { randomiseServingSizeUUIDs() }
                        .help("The next size picked for a dish already on the bill goes on a line of its own")
                }
            }
            .sheet(isPresented: $isShowingVoiceOrder) {
                VoiceOrderView()
            }
        }
        .task {
            #if DEBUG
            // `--voice-order` opens voice ordering (screenshots)
            if CommandLine.arguments.contains("--voice-order") { isShowingVoiceOrder = true }
            #endif
            await menuLoader.loadMenu()
        }
    }

    @ViewBuilder
    private func row(_ menuItem: Category.Item) -> some View {
        let inBill = menuLoader.billItems.first(where: { $0.id == menuItem.id })
        HStack(spacing: DesignTokens.spacingM) {
            // Tapping the dish adds it
            Button { add(menuItem) } label: {
                HStack {
                    (Text(menuItem.prefix.map { "(\($0)) " } ?? "").italic()
                     + Text(menuItem.name).fontWeight(.semibold)
                     + Text(menuItem.suffix.map { " (\($0))" } ?? "").italic())
                        .accessibilityIdentifier("menu-item-name-\(menuItem.id.uuidString)")
                    Spacer(minLength: DesignTokens.spacingS)
                    Text((inBill?.price ?? Double(menuItem.price)).rupees)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(inBill == nil ? "Adds it to the bill" : "")

            if let servingSizes = menuItem.servingSizes {
                Menu(inBill?.servingSize?.name ?? servingSizes.first?.name ?? "Size") {
                    ForEach(servingSizes) { size in
                        Button(size.name) { choose(size, for: menuItem) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }

            if let quantity = $menuLoader.billItems.first(where: { $0.id == menuItem.id })?.quantity {
                Stepper(value: quantity, in: 0...100) {
                    Text(Fmt.qty(quantity.wrappedValue))
                        .monospacedDigit()
                        .accessibilityIdentifier("menu-item-quantity-Text-\(menuItem.id.uuidString)")
                }
                .fixedSize()
            }
        }
        .contextMenu {
            Button("Add half a portion", systemImage: "circle.lefthalf.filled") { addHalf(menuItem) }
        }
    }
}

struct MenuList_Previews: PreviewProvider {
    static var previews: some View {
        MenuList()
            .environmentObject(MenuLoader())
    }
}
