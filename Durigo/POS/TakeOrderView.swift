//
//  TakeOrderView.swift
//  Durigo
//
//  Order creation: search/filter the menu, add items (with variants),
//  manage cart line quantities, then submit. Mirrors the web's
//  /pos/order/new + /pos/takeaway + /pos/delivery.
//

import SwiftUI

struct TakeOrderView: View {
    @Bindable var store: POSStore
    let tableId: String?
    let table: POSTable?
    let orderType: OrderType

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedCategoryId: String? = nil
    @State private var cart: [CartLine] = []
    @State private var customerName: String = ""
    @State private var customerPhone: String = ""
    @State private var deliveryAddress: String = ""
    /// The cart line whose kitchen note is being edited
    @State private var noteLineId: UUID?
    @State private var noteDraft = ""
    /// The cart line whose extras are being picked
    @State private var extrasLineId: UUID?
    @State private var notes: String = ""
    @State private var variantPickerItem: AdminMenuItem?
    @State private var submitting = false
    @State private var errorMessage: String?
    /// One key per order: reused if Place Order is retried after a failure, so
    /// an order that did reach the server isn't placed twice
    @State private var idempotencyKey = UUID().uuidString

    var title: String {
        switch orderType {
        case .dineIn:    return table.map { "Table \($0.number)" } ?? "Dine-in"
        case .takeaway:  return "Takeaway Order"
        case .delivery:  return "Delivery Order"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                waiterPickerBar
                Divider()
                if orderType != .dineIn {
                    customerSection
                    Divider()
                }
                searchAndCategoryBar
                Divider()
                menuList
                Divider()
                cartFooter
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $variantPickerItem) { item in
                VariantPickerSheet(item: item) { variant in
                    addToCart(item, variant: variant)
                    variantPickerItem = nil
                }
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            // A changed cart is a different order, so it gets a new key
            .onChange(of: cart.map { "\($0.id)x\($0.quantity)\($0.notes ?? "")\($0.modifiers.map(\.id))" }) {
                idempotencyKey = UUID().uuidString
            }
            .sheet(isPresented: Binding(
                get: { extrasLineId != nil },
                set: { if !$0 { extrasLineId = nil } }
            )) {
                if let i = cart.firstIndex(where: { $0.id == extrasLineId }) {
                    ModifierPickerSheet(
                        itemName: cart[i].menuItem.name,
                        options: store.modifiers(forCategory: cart[i].menuItem.categoryId),
                        selected: $cart[i].modifiers
                    )
                }
            }
            .alert("Note for the kitchen", isPresented: Binding(
                get: { noteLineId != nil },
                set: { if !$0 { noteLineId = nil } }
            )) {
                TextField("e.g. no nuts, less spicy", text: $noteDraft)
                Button("Save") {
                    if let i = cart.firstIndex(where: { $0.id == noteLineId }) {
                        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        cart[i].notes = note.isEmpty ? nil : note
                    }
                    noteLineId = nil
                }
                Button("Cancel", role: .cancel) { noteLineId = nil }
            } message: {
                Text(cart.first(where: { $0.id == noteLineId })?.menuItem.name ?? "")
            }
        }
    }

    // MARK: Sections

    /// Waiter selector — required for dine-in/delivery so the kitchen knows
    /// who to call when the food's ready. Mirrors the existing Bill Generator
    /// waiter dropdown but pulls real users from /api/users/waiters.
    private var waiterPickerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text("Waiter")
                .font(.system(.subheadline, weight: .semibold))
            Spacer()
            Picker(selection: Binding(
                get: { store.selectedWaiterId ?? "" },
                set: { store.selectedWaiterId = $0.isEmpty ? nil : $0 }
            )) {
                Text("Select…").tag("")
                ForEach(store.waiters) { w in
                    Text(w.name).tag(w.id)
                }
            } label: {
                Text(currentWaiterName ?? "Select…")
                    .font(.system(.subheadline, weight: .medium))
            }
            .pickerStyle(.menu)
            .tint(currentWaiterName == nil ? .red : .accentColor)
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, DesignTokens.spacingS)
    }

    private var currentWaiterName: String? {
        guard let id = store.selectedWaiterId else { return nil }
        return store.waiters.first(where: { $0.id == id })?.name
    }

    private var customerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Required for delivery; optional for takeaway, where a phone
            // number links the order to the customer for the customer report
            Text(orderType == .delivery ? "Customer" : "Customer (optional)")
                .font(.system(.subheadline, weight: .semibold))
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.top, DesignTokens.spacingM)
            if orderType == .delivery {
                TextField("Customer name", text: $customerName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, DesignTokens.spacingL)
                TextField("Phone number", text: $customerPhone)
                    .keyboardType(.phonePad)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, DesignTokens.spacingL)
                TextField("Delivery address", text: $deliveryAddress, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, DesignTokens.spacingL)
                    .padding(.bottom, DesignTokens.spacingS)
            } else {
                HStack {
                    TextField("Phone number", text: $customerPhone)
                        .keyboardType(.phonePad)
                        .accessibilityIdentifier("takeaway-customer-phone")
                    TextField("Name", text: $customerName)
                        .accessibilityIdentifier("takeaway-customer-name")
                }
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.bottom, DesignTokens.spacingS)
            }
        }
    }

    private var searchAndCategoryBar: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search menu", text: $query)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.top, DesignTokens.spacingS)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryChip(id: nil, name: "All")
                    ForEach(store.categories) { c in
                        categoryChip(id: c.id, name: c.name)
                    }
                }
                .padding(.horizontal, DesignTokens.spacingL)
            }
            .padding(.bottom, 6)
        }
    }

    private func categoryChip(id: String?, name: String) -> some View {
        let isSelected = selectedCategoryId == id
        return Button {
            selectedCategoryId = id
        } label: {
            Text(name)
                .font(.system(.footnote, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color(.tertiarySystemBackground)))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var filteredItems: [AdminMenuItem] {
        store.menu.filter { item in
            guard item.available else { return false }
            if let cat = selectedCategoryId, item.categoryId != cat { return false }
            if !query.isEmpty {
                return item.name.localizedCaseInsensitiveContains(query)
            }
            return true
        }
    }

    private var menuList: some View {
        List {
            ForEach(filteredItems) { item in
                Button {
                    if item.variantTemplates.isEmpty {
                        addToCart(item, variant: nil)
                    } else {
                        variantPickerItem = item
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(.body, weight: .medium))
                            if let desc = item.description, !desc.isEmpty {
                                Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if !item.variantTemplates.isEmpty {
                                Text("\(item.variantTemplates.count) variants")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text("₹\(Int(item.price))")
                            .font(.system(.body, weight: .semibold))
                            .monospacedDigit()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if filteredItems.isEmpty {
                Text("No items match")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }

    // MARK: Cart footer

    @ViewBuilder
    private var cartFooter: some View {
        VStack(spacing: 0) {
            if !cart.isEmpty {
                List {
                    ForEach(cart) { line in
                        cartRow(for: line)
                    }
                    .onDelete { offsets in
                        cart.remove(atOffsets: offsets)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 220)
            }

            VStack(spacing: 8) {
                if !cart.isEmpty {
                    // Notes field — kitchen sees this on every order card.
                    TextField("Notes for kitchen (allergies, preferences)", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    HStack {
                        Text("Total")
                            .font(.system(.headline, weight: .semibold))
                        Spacer()
                        Text("₹\(Int(cartTotal))")
                            .font(.system(.title3, weight: .bold))
                            .monospacedDigit()
                    }
                }
                Button {
                    Task { await submit() }
                } label: {
                    if submitting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(cart.isEmpty ? "Add items to continue" : "Send to Kitchen")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cart.isEmpty || submitting || !canSubmit)
            }
            .padding(DesignTokens.spacingL)
            .background(Color(.systemBackground))
        }
    }

    private func cartRow(for line: CartLine) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.menuItem.name).font(.system(.subheadline, weight: .medium))
                if let v = line.variant {
                    Text(v.name).font(.caption2).foregroundStyle(.secondary)
                }
                if let extras = line.modifiers.isEmpty ? nil : "+ " + line.modifiers.map(\.name).joined(separator: ", ") {
                    Text(extras).font(.caption).foregroundStyle(.secondary)
                }
                if let note = line.notes {
                    Text(note).font(.caption).italic().foregroundStyle(.orange)
                }
            }
            Spacer()
            // Extras ("Extra cheese +₹50"), when any apply to this category
            if !store.modifiers(forCategory: line.menuItem.categoryId).isEmpty {
                Button {
                    extrasLineId = line.id
                } label: {
                    Image(systemName: line.modifiers.isEmpty ? "plus.square.on.square" : "plus.square.fill.on.square.fill")
                        .foregroundStyle(line.modifiers.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Extras for \(line.menuItem.name)")
                .accessibilityIdentifier("cart-extras-\(line.menuItem.name)")
            }
            // Per-item note for the kitchen ("no nuts", "less spicy")
            Button {
                noteDraft = line.notes ?? ""
                noteLineId = line.id
            } label: {
                Image(systemName: line.notes == nil ? "square.and.pencil" : "pencil.circle.fill")
                    .foregroundStyle(line.notes == nil ? Color.secondary : Color.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line.notes == nil ? "Add a note for \(line.menuItem.name)" : "Edit note for \(line.menuItem.name)")
            HStack(spacing: 0) {
                Button {
                    decrement(line)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text("\(line.quantity)")
                    .font(.system(.body, weight: .semibold))
                    .frame(minWidth: 28)
                    .monospacedDigit()
                Button {
                    increment(line)
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            Text("₹\(Int(line.lineTotal))")
                .font(.system(.subheadline, weight: .semibold))
                .frame(minWidth: 60, alignment: .trailing)
                .monospacedDigit()
        }
    }

    /// The order note. The server has no customer fields on an order, so (as
    /// the web does) a delivery's customer, phone and address go in the note.
    private var orderNotes: String? {
        let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var parts = [trimmed(notes)]
        if orderType == .delivery {
            if !trimmed(customerName).isEmpty { parts.append("Customer: \(trimmed(customerName))") }
            if !trimmed(customerPhone).isEmpty { parts.append("Phone: \(trimmed(customerPhone))") }
            if !trimmed(deliveryAddress).isEmpty { parts.append("Address: \(trimmed(deliveryAddress))") }
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: " | ")
        return joined.isEmpty ? nil : joined
    }

    private var cartTotal: Double {
        cart.reduce(0) { $0 + $1.lineTotal }
    }

    private var canSubmit: Bool {
        // Require a waiter for dine-in/delivery — the kitchen needs to know
        // who to call when food is ready. Takeaway is impersonal (counter
        // orders) so we let it through.
        if orderType != .takeaway && store.selectedWaiterId == nil {
            return false
        }
        switch orderType {
        case .delivery:
            return !customerName.trimmingCharacters(in: .whitespaces).isEmpty &&
                   !customerPhone.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return true
        }
    }

    // MARK: Cart mutations

    private func addToCart(_ item: AdminMenuItem, variant: AdminVariantTemplate?) {
        // A line with its own note or extras stays separate from plain ones
        if let i = cart.firstIndex(where: { $0.menuItem.id == item.id && $0.variant?.id == variant?.id && $0.notes == nil && $0.modifiers.isEmpty }) {
            cart[i].quantity += 1
        } else {
            cart.append(CartLine(menuItem: item, variant: variant, quantity: 1, notes: nil))
        }
    }

    private func increment(_ line: CartLine) {
        if let i = cart.firstIndex(where: { $0.id == line.id }) {
            cart[i].quantity += 1
        }
    }

    private func decrement(_ line: CartLine) {
        if let i = cart.firstIndex(where: { $0.id == line.id }) {
            if cart[i].quantity <= 1 {
                cart.remove(at: i)
            } else {
                cart[i].quantity -= 1
            }
        }
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        do {
            _ = try await store.placeOrder(
                tableId: tableId,
                type: orderType,
                cart: cart,
                notes: orderNotes,
                customerName: trimmedOrNil(customerName),
                customerPhone: trimmedOrNil(customerPhone),
                customerAddress: orderType == .delivery ? trimmedOrNil(deliveryAddress) : nil,
                idempotencyKey: idempotencyKey
            )
            // Refresh tables so we pick up the new status from the server.
            await store.loadTables()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Extras picker

/// Toggle the extras on one cart line. Each shows its price; the line's
/// price updates as they're picked.
private struct ModifierPickerSheet: View {
    let itemName: String
    let options: [AdminModifier]
    @Binding var selected: [AdminModifier]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(options) { m in
                    let isOn = selected.contains { $0.id == m.id }
                    Button {
                        if isOn {
                            selected.removeAll { $0.id == m.id }
                        } else if selected.count < 10 {   // the server's limit per line
                            selected.append(m)
                        }
                    } label: {
                        HStack {
                            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                            Text(m.name)
                            Spacer()
                            if m.price > 0 {
                                Text("+₹\(m.price)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("extra-\(m.name)")
                }
            }
            .navigationTitle("Extras for \(itemName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Variant picker

private struct VariantPickerSheet: View {
    let item: AdminMenuItem
    let onPick: (AdminVariantTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(item.variantTemplates) { v in
                    Button {
                        onPick(v)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name).font(.system(.body, weight: .medium))
                                if let d = v.description, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("₹\(Int(v.price(forBase: Double(item.price))))")
                                .font(.system(.body, weight: .semibold))
                                .monospacedDigit()
                        }
                        // The whole row is the button, not just its text
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
