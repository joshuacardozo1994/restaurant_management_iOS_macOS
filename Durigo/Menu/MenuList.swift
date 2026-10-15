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
    
    
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack {
                        TextField("Menu Item", text: $searchQuery)
                            .autocorrectionDisabled()
                            .padding()
                            .accessibilityIdentifier("menuItemSearchQueryTextField")
                        if !searchQuery.isEmpty {
                            Button(action: {
                                searchQuery = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing)
                            }
                            .accessibilityIdentifier("clearSearchField")
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(10)
                    
                    Button(action: { randomiseServingSizeUUIDs() }) {
                        Image(systemName: "arrow.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                
                let items = getFilteredResults() ?? [Category.placeholder, Category.placeholder]
                List(items) { category in
                    Section {
                        ForEach(category.items.filter({ [Category.Item.VisibilityScope.bill, Category.Item.VisibilityScope.both].contains($0.visibilityScope)  })) { menuItem in
                        HStack {
                            HStack {
                                if let quantity = menuLoader.billItems.first(where: { $0.id == menuItem.id })?.quantity {
                                    Text(String(format: "%.1f", quantity))
                                        .bold()
                                        .onTapGesture {
                                            print("tapped")
                                            menuLoader.billItems = menuLoader.billItems.map({
                                                MenuItem(id: $0.id, name: $0.name, prefix: $0.prefix, suffix: $0.suffix, quantity: $0.quantity + ($0.id == menuItem.id ? 0.5 : 0), price: $0.price, servingSize: $0.servingSize, tags: $0.tags)
                                            })
                                            
                                        }
                                } else {
                                    Text("0").hidden()
                                }
                            }
                            .frame(width: 28)
                            if let servingSizes = menuItem.servingSizes {
                                Menu {
                                    ForEach(servingSizes) { servingSize in
                                        Button(action: {
                                            addToMenu(menuItem: menuItem)
                                            menuLoader.billItems = menuLoader.billItems.map { billItem in
                                                guard billItem.id == menuItem.id  else { return billItem }
                                                var newbillItem = billItem
                                                newbillItem.servingSize = servingSize
                                                newbillItem.price = Double(Helper.evaluateExpression(expression: servingSize.expression, withValue: Double(menuItem.price)) ?? 0)
                                                return newbillItem
                                            }
                                        }) {
                                            Text(servingSize.name)
                                                
                                        }
                                    }
                                    
                                    
                                } label: {
                                    Text(menuLoader.billItems.first(where: { $0.id == menuItem.id })?.servingSize?.name ?? servingSizes.first?.name ?? "")
                                        .foregroundStyle(Color.primary)
                                        .bold()
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color.primary, lineWidth: 1)
                                            )
                                }
                            }
                            let text = Text(menuItem.prefix != nil ? "(\(menuItem.prefix ?? "")) " : "")
                                .italic()
                            +
                            Text(menuItem.name)
                                
                                .bold()
                            +
                            Text(menuItem.suffix != nil ? " (\(menuItem.suffix ?? ""))" : "")
                                .italic()
                            text
                                .accessibilityIdentifier("menu-item-name-\(menuItem.id.uuidString)")
                            Spacer()
                            Group {
                                if let quantity = $menuLoader.billItems.first(where: { $0.id == menuItem.id })?.quantity {
                                    Stepper("Quantity", value: quantity, in: 0...100)
                                        .labelsHidden()
                                } else {
                                    Button(action: {
                                        addToMenu(menuItem: menuItem)
                                        menuLoader.billItems = menuLoader.billItems.map { billItem in
                                            guard billItem.id == menuItem.id else { return billItem }
                                            guard let servingSizes = menuItem.servingSizes else { return billItem }
                                            guard let servingSize = servingSizes.first else { return billItem }
                                            var newbillItem = billItem
                                            newbillItem.servingSize = servingSize
                                            newbillItem.price = Double(Helper.evaluateExpression(expression: servingSize.expression, withValue: Double(menuItem.price)) ?? 0)
                                            return newbillItem
                                        }
                                    }) {
                                        Color.clear
                                            .frame(height: 32)
                                    }
                                }
                            }
                            .frame(width: 94, height: 32)
                            
                            if let billItemPrice = menuLoader.billItems.first(where: { $0.id == menuItem.id })?.price {
                                Text("\(Int(billItemPrice))")
                            } else {
                                Text("\(Int(menuItem.price))")
                            }
                            
                            
                        }
                    }
                } header: {
                    Text(category.name)
                        .textCase(.uppercase)
                        .font(.headline)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            // Until the menu arrives the list shows placeholder categories
            .skeleton(menuLoader.menu == nil)
        }
        .navigationTitle("Menu")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: {
                    isShowingVoiceOrder = true
                }) {
                    Image(systemName: "mic.fill")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $isShowingVoiceOrder) {
            VoiceOrderView()
        }
        }
        .task {
            await menuLoader.loadMenu()
        }
    }
}

struct MenuList_Previews: PreviewProvider {
    static var previews: some View {
        MenuList()
            .environmentObject(MenuLoader())
    }
}
