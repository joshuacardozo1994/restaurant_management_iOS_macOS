//
//  BillGenerator.swift
//  Durigo
//
//  Web-styled bill generator: table + waiter pickers in a header card,
//  bill rows in a card with subtle dividers, total in a footer card.
//  Inline editing (name/price/quantity) is preserved exactly — bindings
//  still write through to MenuLoader.billItems.
//

import SwiftUI

// MARK: - Header pickers

struct TableDropdownSelector: View {
    var showIfSelected = false
    @Binding var selectedOption: Int?
    let options: [Int]

    var body: some View {
        Picker(selection: Binding(
            get: { selectedOption ?? -1 },
            set: { selectedOption = $0 == -1 ? nil : $0 }
        )) {
            Text("Table").tag(-1)
            Text("Parcel").tag(0)
            ForEach(options, id: \.self) { option in
                Text("Table \(option)").tag(option)
            }
        } label: {
            pickerLabel
        }
        .pickerStyle(.menu)
        .tint(Color.primary)
        .accessibilityIdentifier("Table-Selector")
    }

    private var pickerLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Group {
                if let selectedOption {
                    Text(selectedOption == 0 ? "Parcel" : "Table \(selectedOption)")
                        .foregroundStyle(.primary)
                } else {
                    Text("Table")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.body, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct WaiterDropdownSelector: View {
    var showIfSelected = false
    /// The name printed on the bill
    @Binding var selectedOption: String?
    /// The picked person's user id, sent with the bill so the staff report
    /// counts it even if two people share a name or someone is renamed
    @Binding var selectedId: String?
    /// Live directory of staff who can serve a table — both waiters and
    /// admins, with role attached so the picker can group them.
    let staff: [WaiterRef]

    /// The picked id; a bill reopened from history may only have a name
    private var currentId: String {
        if let selectedId { return selectedId }
        return staff.first { $0.name == selectedOption }?.id ?? ""
    }

    private var waitersOnly: [WaiterRef] { staff.filter { $0.role == "WAITER" } }
    private var adminsOnly:  [WaiterRef] { staff.filter { $0.role == "ADMIN"  } }
    /// Names on bills that aren't current staff (the bill history filter)
    private var others: [WaiterRef] { staff.filter { $0.role == WaiterRef.otherRole } }

    var body: some View {
        Picker(selection: Binding(
            get: { currentId },
            set: { id in
                selectedId = id.isEmpty ? nil : id
                selectedOption = staff.first { $0.id == id }?.name
            }
        )) {
            Text("Waiter").tag("")
            // Waiters first — that's the primary attribution group for
            // bill generation. Admins listed below as fill-in coverage.
            if !waitersOnly.isEmpty {
                Section("Waiters") {
                    ForEach(waitersOnly) { w in
                        Text(w.name).tag(w.id)
                    }
                }
            }
            if !adminsOnly.isEmpty {
                Section("Admins") {
                    ForEach(adminsOnly) { a in
                        Text(a.name).tag(a.id)
                    }
                }
            }
            if !others.isEmpty {
                Section("Other names on bills") {
                    ForEach(others) { o in
                        Text(o.name).tag(o.id)
                    }
                }
            }
        } label: {
            pickerLabel
        }
        .pickerStyle(.menu)
        .tint(Color.primary)
        .accessibilityIdentifier("Waiter-Selector")
    }

    private var pickerLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Group {
                if let selectedOption {
                    Text(selectedOption)
                        .foregroundStyle(.primary)
                } else {
                    Text("Waiter")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.body, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Filter dropdown for bill payment status. Mirrors the table/waiter selector
/// styling so it slots into the BillHistoryList toolbar's filter menu without
/// looking out of place. Uses raw-string tags because SwiftUI's `Picker` `tag`
/// type has to be `Hashable` and matching enums via raw value avoids the need
/// for the parent menu to know about the optional wrapping.
struct PaymentStatusDropdownSelector: View {
    var showIfSelected = false
    @Binding var selectedOption: BillHistoryItemStatus?

    var body: some View {
        Picker(selection: Binding(
            get: { selectedOption?.rawValue ?? "" },
            set: { newValue in
                selectedOption = newValue.isEmpty ? nil : BillHistoryItemStatus(rawValue: newValue)
            }
        )) {
            Text("Bill status").tag("")
            Section("Paid") {
                Text("Cash").tag(BillHistoryItemStatus.paidByCash.rawValue)
                Text("UPI").tag(BillHistoryItemStatus.paidByUPI.rawValue)
                Text("Card").tag(BillHistoryItemStatus.paidByCard.rawValue)
            }
            Text("Pending").tag(BillHistoryItemStatus.pending.rawValue)
        } label: {
            pickerLabel
        }
        .pickerStyle(.menu)
        .tint(Color.primary)
        .accessibilityIdentifier("PaymentStatus-Selector")
    }

    private var pickerLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Group {
                if let selectedOption {
                    Text(humanLabel(selectedOption))
                        .foregroundStyle(.primary)
                } else {
                    Text("Bill status")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.body, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func humanLabel(_ status: BillHistoryItemStatus) -> String {
        switch status {
        case .paidByCash: return "Paid – Cash"
        case .paidByUPI:  return "Paid – UPI"
        case .paidByCard: return "Paid – Card"
        case .pending:    return "Pending"
        }
    }
}

// MARK: - Single editable bill row

struct BillItem: View {
    @Binding var item: MenuItem

    var body: some View {
        HStack(spacing: DesignTokens.spacingM) {
            // Quantity (tap to +0.5, stepper for fine control)
            HStack(spacing: 6) {
                Text(String(format: "%.1f", item.quantity))
                    .font(.system(.body, weight: .semibold))
                    .frame(minWidth: 32, alignment: .leading)
                    .accessibilityIdentifier("menu-item-quantity-Text-\(item.id.uuidString)")
                    .onTapGesture { item.quantity += 0.5 }
                Stepper("Quantity", value: $item.quantity, in: 1...100)
                    .labelsHidden()
                    .accessibilityIdentifier("menu-item-quantity-Stepper-\(item.id.uuidString)")
            }

            // Optional prefix + serving size badges
            if let prefix = item.prefix {
                Text("(\(prefix))")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("menu-item-prefix-Text-\(item.id.uuidString)")
            }
            if let servingSize = item.servingSize, servingSize.shouldDisplay {
                Text(servingSize.name)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            // Editable name
            TextField("Name", text: $item.name)
                .font(.system(.body))
                .accessibilityIdentifier("menu-item-name-TextField-\(item.id.uuidString)")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            // Editable price
            HStack(spacing: 2) {
                Text("₹")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("0", value: $item.price, format: .number).labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("menu-item-price-TextField-\(item.id.uuidString)")
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                    .font(.system(.body, weight: .semibold))
                    .frame(width: 56)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Empty state

private struct EmptyBillState: View {
    var body: some View {
        ContentUnavailableView("No items yet", systemImage: "list.bullet.clipboard",
                               description: Text("Tap the menu button or add a custom item to start the bill."))
    }
}

// MARK: - Bill Generator

struct BillGenerator: View {
    @EnvironmentObject private var menuLoader: MenuLoader
    @Environment(Session.self) private var session
    @State private var showingBillClearAlert = false
    @State private var isShowingMenuList = false
    /// Live waiter directory pulled from /api/users/waiters. Offline, the
    /// last list fetched is used (so bills still print, linked to the right
    /// people); a hardcoded set only if the server has never been reached.
    /// Stored as `[WaiterRef]` so the dropdown can group by role.
    @State private var waiterStaff: [WaiterRef] = Self.cachedWaiters() ?? [
        WaiterRef(id: "fallback-1", name: "Alcin",   role: "WAITER"),
        WaiterRef(id: "fallback-2", name: "Anthony", role: "WAITER"),
        WaiterRef(id: "fallback-3", name: "Antone",  role: "WAITER"),
        WaiterRef(id: "fallback-4", name: "Amanda",  role: "WAITER"),
        WaiterRef(id: "fallback-5", name: "Monica",  role: "WAITER"),
        WaiterRef(id: "fallback-6", name: "Joshua",  role: "WAITER"),
    ]
    private static let waitersCacheKey = "billGenerator.waiters"

    private static func cachedWaiters() -> [WaiterRef]? {
        guard let data = UserDefaults.standard.data(forKey: waitersCacheKey),
              let list = try? JSONDecoder().decode([WaiterRef].self, from: data),
              !list.isEmpty else { return nil }
        return list
    }

    var body: some View {
        NavigationRoot {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                    headerCard
                    itemsCard
                    totalsCard
                }
                .padding(DesignTokens.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Bill Generator")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $isShowingMenuList) {
                MenuList()
            }
            .task {
                await loadWaiters()
            }
            .alert("Are you sure you want to clear the bill", isPresented: $showingBillClearAlert) {
                Button("Clear", role: .destructive) {
                    menuLoader.resetBill()
                }
                Button("Cancel", role: .cancel) {}
            }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    clearButton
                    addItemButton
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    menuButton
                    printButton
                }
            }
            #else
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    clearButton
                    addItemButton
                }
                ToolbarItemGroup(placement: .secondaryAction) {
                    menuButton
                    printButton
                }
            }
            #endif
            .task {
                await menuLoader.loadMenu()
            }
        }
    }

    // MARK: Header card (table + waiter)

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            HStack {
                Text("New bill")
                    .font(.system(.headline, weight: .semibold))
                Spacer()
                Text("#\(menuLoader.billID.uuidString.prefix(6))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DesignTokens.spacingM) {
                TableDropdownSelector(
                    selectedOption: $menuLoader.tableNumber,
                    options: Array(1...20)
                )
                WaiterDropdownSelector(
                    selectedOption: $menuLoader.waiter,
                    selectedId: $menuLoader.waiterId,
                    staff: waiterStaff
                )
                Spacer()
            }
            customerFields
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusMedium)
    }

    /// Optional: a phone number links the bill to the customer (found or
    /// created on the server) for the customer report
    private var customerFields: some View {
        HStack(spacing: DesignTokens.spacingS) {
            Image(systemName: "person.text.rectangle")
                .foregroundStyle(.secondary)
            TextField("Customer phone", text: $menuLoader.customerPhone)
                .keyboardType(.phonePad)
                .accessibilityIdentifier("bill-customer-phone")
            TextField("Name", text: $menuLoader.customerName)
                .accessibilityIdentifier("bill-customer-name")
        }
        .textFieldStyle(.roundedBorder)
        .font(.subheadline)
    }

    // MARK: Items card

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Items")
                    .font(.system(.headline, weight: .semibold))
                Spacer()
                Text("\(menuLoader.billItems.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.top, DesignTokens.spacingL)
            .padding(.bottom, DesignTokens.spacingS)

            if menuLoader.billItems.isEmpty {
                EmptyBillState()
            } else {
                billItemsList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusMedium)
    }

    private var billItemsList: some View {
        List($menuLoader.billItems, editActions: [.delete, .move]) { $item in
            BillItem(item: $item)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.primary.opacity(DesignTokens.borderOpacity))
                .listRowInsets(EdgeInsets(
                    top: DesignTokens.spacingS,
                    leading: DesignTokens.spacingL,
                    bottom: DesignTokens.spacingS,
                    trailing: DesignTokens.spacingL
                ))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(minHeight: CGFloat(max(menuLoader.billItems.count, 1)) * 56)
    }

    // MARK: Totals card

    private var totalsCard: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(menuLoader.billItems.count)")
                    .font(.system(.title3, weight: .semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\((menuLoader.billItems.getTotal()).rupees)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .accessibilityIdentifier("bill generator items total")
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusMedium)
    }

    // MARK: Toolbar buttons

    private var clearButton: some View {
        Button(action: {
        #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
            showingBillClearAlert.toggle()
        }) {
            Image(systemName: "trash")
        }
        .disabled(menuLoader.billItems.isEmpty)
        .accessibilityIdentifier("clearBill")
    }

    private var addItemButton: some View {
        Button(action: {
            menuLoader.billItems.append(MenuItem(id: UUID(), name: "", quantity: 1, price: 0))
        }) {
            Image(systemName: "plus.circle")
        }
        .accessibilityIdentifier("addItemButton")
    }

    private var menuButton: some View {
        Button(action: {
            isShowingMenuList.toggle()
        }) {
            Image(systemName: "book.pages")
        }
        .accessibilityIdentifier("showMenuButton")
    }

    private var printButton: some View {
        NavigationLink {
            BillPreview(
                tableNumber: menuLoader.tableNumber,
                waiter: menuLoader.waiter ?? "Unknown",
                billID: menuLoader.billID,
                billItems: menuLoader.billItems,
                waiterId: menuLoader.waiterId,
                customerName: trimmedOrNil(menuLoader.customerName),
                customerPhone: trimmedOrNil(menuLoader.customerPhone)
            )
        } label: {
            Image(systemName: "printer")
        }
        .disabled(
            menuLoader.billItems.isEmpty
            || menuLoader.billItems.contains { $0.price == 0 }
            || menuLoader.tableNumber == nil
            || menuLoader.waiter == nil
        )
        .accessibilityIdentifier("print-bill")
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Fetch the live waiter directory (active WAITER + ADMIN users) so
    /// the dropdown matches the same source POS Take Order uses. The
    /// picker groups them by role, so we keep both. We only replace the
    /// hardcoded fallback if the fetch returns at least one entry.
    private func loadWaiters() async {
        let api = APIClient(session: session)
        do {
            let data = try await api.get("/api/users/waiters")
            let live = try JSONDecoder().decode([WaiterRef].self, from: data)
            if !live.isEmpty {
                waiterStaff = live
                if let data = try? JSONEncoder().encode(live) {
                    UserDefaults.standard.set(data, forKey: Self.waitersCacheKey)
                }
            }
        } catch {
            // Keep the hardcoded fallback list — non-fatal.
        }
    }
}

// MARK: - Preview

struct BillGenerator_Previews: PreviewProvider {
    static var previews: some View {
        BillGenerator()
            .environmentObject(MenuLoader())
            .environmentObject(Navigation())
    }
}
