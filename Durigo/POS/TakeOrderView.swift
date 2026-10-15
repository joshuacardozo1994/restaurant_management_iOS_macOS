//
//  TakeOrderView.swift
//  Durigo
//
//  Order creation: search/filter the menu, add items (with variants),
//  manage cart line quantities, then submit. Mirrors the web's
//  /pos/order/new + /pos/takeaway + /pos/delivery.
//
//  On a wide screen (iPad, Mac) it sits in place of the floor: a strip of
//  tables to switch between, categories on the left, the menu as cards, and
//  the table's live bill on the right with the lines not sent yet. On a
//  narrow one (iPhone) it is a sheet: the menu list, the cart, and a bar
//  with the bill so far and Send to kitchen.
//

import SwiftUI

struct TakeOrderView: View {
    @Bindable var store: POSStore
    /// Shown in place of the floor (no sheet, no navigation bar of its own)
    var inline = false
    /// Back to the floor, selecting the table the order was for
    var onClose: ((String?) -> Void)? = nil
    /// Wide layout: open the table's payment
    var onPay: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var menuLoader: MenuLoader
    @State private var target: OrderTarget
    /// A cart per table (or takeaway / delivery) while switching between them
    @State private var carts: [String: [CartLine]] = [:]
    @State private var query: String = ""
    @State private var selectedCategoryId: String? = nil
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

    /// From this width the order screen uses the three-column layout
    static let wideWidth: CGFloat = 820

    init(store: POSStore, target: OrderTarget, inline: Bool = false,
         onClose: ((String?) -> Void)? = nil, onPay: ((String) -> Void)? = nil) {
        self.store = store
        self.inline = inline
        self.onClose = onClose
        self.onPay = onPay
        _target = State(initialValue: target)
    }

    private var orderType: OrderType { target.type }
    private var tableId: String? { target.tableId }
    private var table: POSTable? { tableId.flatMap { id in store.tables.first { $0.id == id } } }

    /// The cart for the table (or counter order) on screen
    private var cart: [CartLine] {
        get { carts[target.id] ?? [] }
        nonmutating set { carts[target.id] = newValue }
    }

    var title: String {
        switch orderType {
        case .dineIn:    return table.map { "Table \($0.number)" } ?? "Dine-in"
        case .takeaway:  return "Takeaway Order"
        case .delivery:  return "Delivery Order"
        }
    }

    var body: some View {
        Group {
            if inline {
                GeometryReader { geo in
                    if geo.size.width >= Self.wideWidth {
                        wideLayout
                    } else {
                        VStack(spacing: 0) {
                            inlineTopBar
                            Divider()
                            compactLayout
                        }
                    }
                }
                .background(SN.page)
            } else {
                NavigationStack {
                    compactLayout
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { close(selecting: nil) }
                            }
                        }
                }
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
        .onChange(of: target.id + cart.map { "\($0.id)x\($0.quantity)\($0.notes ?? "")\($0.modifiers.map(\.id))" }.joined()) {
            idempotencyKey = UUID().uuidString
        }
        .sheet(isPresented: Binding(
            get: { extrasLineId != nil },
            set: { if !$0 { extrasLineId = nil } }
        )) {
            if let line = cart.first(where: { $0.id == extrasLineId }) {
                ModifierPickerSheet(
                    itemName: line.menuItem.name,
                    options: store.modifiers(forCategory: line.menuItem.categoryId),
                    selected: Binding(
                        get: { cart.first(where: { $0.id == line.id })?.modifiers ?? [] },
                        set: { value in
                            if let i = cart.firstIndex(where: { $0.id == line.id }) { cart[i].modifiers = value }
                        }
                    )
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

    private func close(selecting tableId: String?) {
        if let onClose { onClose(tableId) } else { dismiss() }
    }

    // MARK: - Narrow layout (iPhone sheet)

    private var compactLayout: some View {
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
    }

    /// Inline but narrow (iPad in split view): a way back to the floor
    private var inlineTopBar: some View {
        HStack {
            Button {
                close(selecting: tableId)
            } label: {
                Label("Floor", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("order-back-to-floor")
            Spacer()
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, DesignTokens.spacingS)
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
            waiterPicker
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, DesignTokens.spacingS)
    }

    private var waiterPicker: some View {
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
        .tint(currentWaiterName == nil ? SN.red : SN.teal)
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

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search menu", text: $query)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SN.panel))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SN.line, lineWidth: 1))
    }

    private var searchAndCategoryBar: some View {
        VStack(spacing: 6) {
            searchField
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.top, DesignTokens.spacingS)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryChip(id: nil, name: "All")
                    ForEach(store.categories) { c in
                        if itemCount(in: c.id) > 0 { categoryChip(id: c.id, name: c.name) }
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
            HStack(spacing: 5) {
                Text(name)
                Text("\(itemCount(in: id))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? SN.page.opacity(0.8) : SN.mut)
            }
            .font(.system(.footnote, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Capsule().fill(isSelected ? SN.ink : SN.panel))
            .overlay(Capsule().stroke(isSelected ? SN.ink : SN.line, lineWidth: 1))
            .foregroundStyle(isSelected ? SN.page : SN.ink)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-chip-\(name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Dishes on offer in a category (nil = all)
    private func itemCount(in categoryId: String?) -> Int {
        store.menu.filter { $0.available && (categoryId == nil || $0.categoryId == categoryId) }.count
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

    private func tapItem(_ item: AdminMenuItem) {
        if item.variantTemplates.isEmpty {
            addToCart(item, variant: nil)
        } else {
            variantPickerItem = item
        }
    }

    /// How many of a dish are in the cart (every variant)
    private func quantityInCart(_ item: AdminMenuItem) -> Int {
        cart.filter { $0.menuItem.id == item.id }.reduce(0) { $0 + $1.quantity }
    }

    private var menuList: some View {
        List {
            ForEach(filteredItems) { item in
                Button {
                    tapItem(item)
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
                        Text("\((item.price).rupees)")
                            .font(.system(.body, weight: .semibold))
                            .monospacedDigit()
                        let inCart = quantityInCart(item)
                        if inCart > 0 {
                            QuantityBadge(count: inCart)
                        } else {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(SN.teal)
                        }
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

            VStack(spacing: 10) {
                if !cart.isEmpty {
                    // Notes field — kitchen sees this on every order card.
                    TextField("Notes for kitchen (allergies, preferences)", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(billTotal.rupees)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .accessibilityIdentifier("order-bill-total")
                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(SN.mut)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    sendButton(fullWidth: false)
                }
            }
            .padding(DesignTokens.spacingL)
            .background(SN.panel)
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
                    Text(note).font(.caption).italic().foregroundStyle(SN.amber)
                }
            }
            Spacer()
            lineControls(line)
            Text("\((line.lineTotal).rupees)")
                .font(.system(.subheadline, weight: .semibold))
                .frame(minWidth: 60, alignment: .trailing)
                .monospacedDigit()
        }
    }

    /// Extras, note, and − qty + for a cart line
    @ViewBuilder
    private func lineControls(_ line: CartLine) -> some View {
        // Extras ("Extra cheese +₹50"), when any apply to this category
        if !store.modifiers(forCategory: line.menuItem.categoryId).isEmpty {
            Button {
                extrasLineId = line.id
            } label: {
                Image(systemName: line.modifiers.isEmpty ? "plus.square.on.square" : "plus.square.fill.on.square.fill")
                    .foregroundStyle(line.modifiers.isEmpty ? SN.mut : SN.teal)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
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
                .foregroundStyle(line.notes == nil ? SN.mut : SN.amber)
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.notes == nil ? "Add a note for \(line.menuItem.name)" : "Edit note for \(line.menuItem.name)")
        HStack(spacing: 0) {
            Button {
                decrement(line)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(SN.mut)
                    .font(.title3)
                    // 36pt, not the 17pt glyph: hit in a hurry at a table
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("One fewer \(line.menuItem.name)")
            .accessibilityIdentifier("cart-minus-\(line.menuItem.name)")
            Text("\(line.quantity)")
                .font(.system(.body, weight: .semibold))
                .frame(minWidth: 28)
                .monospacedDigit()
            Button {
                increment(line)
            } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(SN.teal)
                    .font(.title3)
                    // 36pt, not the 17pt glyph: hit in a hurry at a table
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("One more \(line.menuItem.name)")
            .accessibilityIdentifier("cart-plus-\(line.menuItem.name)")
        }
    }

    private func sendButton(fullWidth: Bool) -> some View {
        Button {
            Task { await submit() }
        } label: {
            if submitting {
                ProgressView()
            } else {
                Text(cart.isEmpty ? "Add items to continue" : "Send \(cartQuantity) to kitchen")
            }
        }
        .buttonStyle(POSActionStyle(kind: .prominent, fullWidth: fullWidth))
        .disabled(cart.isEmpty || submitting || !canSubmit)
        .accessibilityIdentifier("send-to-kitchen")
    }

    // MARK: - Wide layout (iPad, Mac)

    private var wideLayout: some View {
        VStack(spacing: 0) {
            tableStrip
            Rectangle().fill(SN.line).frame(height: 1)
            HStack(spacing: 0) {
                categoryColumn
                    .frame(width: 200)
                Rectangle().fill(SN.line).frame(width: 1)
                VStack(spacing: 0) {
                    searchField
                        .padding(DesignTokens.spacingL)
                    menuGrid
                }
                Rectangle().fill(SN.line).frame(width: 1)
                liveBill
                    .frame(width: 360)
            }
        }
        .background(SN.page)
        .foregroundStyle(SN.ink)
    }

    /// Every table, to switch the order to another one
    private var tableStrip: some View {
        HStack(spacing: 10) {
            Button {
                close(selecting: tableId)
            } label: {
                Label("Floor", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("order-back-to-floor")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tables) { t in
                            stripTile(t).id(t.id)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .onAppear { if let tableId { proxy.scrollTo(tableId, anchor: .center) } }
            }
            Button("Takeaway") { switchTo(OrderTarget(tableId: nil, type: .takeaway)) }
                .buttonStyle(QuietButtonStyle())
                .accessibilityAddTraits(orderType == .takeaway ? .isSelected : [])
            Button("Delivery") { switchTo(OrderTarget(tableId: nil, type: .delivery)) }
                .buttonStyle(QuietButtonStyle())
                .accessibilityAddTraits(orderType == .delivery ? .isSelected : [])
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, 10)
        .background(SN.panel)
    }

    private func stripTile(_ t: POSTable) -> some View {
        let status = t.effectiveStatus
        let isOn = tableId == t.id
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let unsent = (carts[OrderTarget(tableId: t.id, type: .dineIn).id] ?? []).reduce(0) { $0 + $1.quantity }
        return Button {
            // A merged table's orders go on its group's primary
            let group = store.tableGroups.first { $0.members.contains { $0.tableId == t.id } }
            let primary = group.flatMap { g in
                store.tables.filter { x in g.members.contains { $0.tableId == x.id } }.min { $0.number < $1.number }
            }
            switchTo(OrderTarget(tableId: (primary ?? t).id, type: .dineIn))
        } label: {
            Text(verbatim: String(t.number))
                .font(.subheadline.monospaced().weight(.semibold))
                .foregroundStyle(status == .reserved || status == .maintenance ? SN.mut : SN.ink)
                .frame(minWidth: 44, minHeight: 36)
                .background(shape.fill(TileLook.fill(status)))
                .overlay(shape.strokeBorder(TileLook.stroke(status), style: StrokeStyle(lineWidth: 1, dash: TileLook.dash(status))))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SN.teal, lineWidth: 2)
                        .padding(-2)
                        .opacity(isOn ? 1 : 0)
                )
                .overlay(alignment: .topTrailing) {
                    if unsent > 0 {
                        Circle().fill(SN.amber).frame(width: 8, height: 8).offset(x: 2, y: -2)
                    }
                }
                .opacity(status == .maintenance ? 0.6 : 1)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(status == .maintenance)
        .accessibilityLabel("Table \(t.number)\(unsent > 0 ? ", \(unsent) not sent" : "")")
        .accessibilityIdentifier("strip-table-\(t.number)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func switchTo(_ newTarget: OrderTarget) {
        guard newTarget != target else { return }
        target = newTarget
        notes = ""
    }

    private var categoryColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                categoryRow(id: nil, name: "All")
                ForEach(store.categories) { c in
                    if itemCount(in: c.id) > 0 { categoryRow(id: c.id, name: c.name) }
                }
            }
            .padding(10)
        }
    }

    private func categoryRow(id: String?, name: String) -> some View {
        let isSelected = selectedCategoryId == id
        return Button {
            selectedCategoryId = id
        } label: {
            HStack {
                Text(name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text("\(itemCount(in: id))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SN.mut)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? SN.panel2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-chip-\(name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedCategoryName: String {
        selectedCategoryId.flatMap { id in store.categories.first { $0.id == id }?.name } ?? "All dishes"
    }

    private var menuGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PanelLabel(text: query.isEmpty ? "\(selectedCategoryName) · \(filteredItems.count)" : "Matching “\(query)” · \(filteredItems.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(filteredItems) { item in
                        menuCard(item)
                    }
                }
                if filteredItems.isEmpty {
                    Text("No items match")
                        .foregroundStyle(SN.mut)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }
            }
            .padding([.horizontal, .bottom], DesignTokens.spacingL)
        }
    }

    private func menuCard(_ item: AdminMenuItem) -> some View {
        let inCart = quantityInCart(item)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                tapItem(item)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if inCart > 0 { QuantityBadge(count: inCart) }
                    }
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc).font(.caption).foregroundStyle(SN.mut).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(item.price.rupees)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(SN.mut)
                }
                .frame(maxWidth: .infinity, minHeight: item.variantTemplates.isEmpty ? 72 : 44, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !item.variantTemplates.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(item.variantTemplates) { v in
                        let price = v.price(forBase: Double(item.price))
                        let picked = cart.contains { $0.menuItem.id == item.id && $0.variant?.id == v.id }
                        Button {
                            addToCart(item, variant: v)
                        } label: {
                            Text("\(v.name) \(Int(price.rounded()))")
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .foregroundStyle(picked ? SN.teal : SN.mut)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(picked ? SN.teal : SN.line, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(item.name), \(v.name), \(price.rupees)")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(shape.fill(SN.panel))
        .overlay(shape.stroke(inCart > 0 ? SN.teal.opacity(0.6) : SN.line, lineWidth: inCart > 0 ? 1.5 : 1))
    }

    /// The table's bill so far, the lines not sent yet, and Send
    private var liveBill: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                PanelLabel(text: billLabel)
                Text(orderType == .dineIn ? "Bill so far" : title)
                    .font(.title3.weight(.bold))
                if let table, let since = table.seatedSince {
                    let n = table.liveOrders.count
                    TimelineView(.periodic(from: .now, by: 30)) { tl in
                        Text("Seated \(POSTime.elapsed(since: since, now: tl.date)) · \(n) order\(n == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(SN.mut)
                    }
                }
                HStack(spacing: 6) {
                    Text("Waiter").font(.subheadline).foregroundStyle(SN.mut)
                    Spacer()
                    waiterPicker
                }
            }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
            if orderType != .dineIn {
                customerSection
            }
            Rectangle().fill(SN.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let table, !table.liveItems.isEmpty {
                        POSStageGroups(items: table.liveItems)
                    }
                    if !cart.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            PanelLabel(text: "Not sent").padding(.bottom, 2)
                            ForEach(cart) { line in
                                billCartRow(line)
                                Rectangle().fill(SN.line).frame(height: 1)
                            }
                        }
                    }
                    if cart.isEmpty && (table?.liveItems.isEmpty ?? true) {
                        Text("Tap a dish to add it")
                            .font(.subheadline)
                            .foregroundStyle(SN.mut)
                    }
                }
                .padding(DesignTokens.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(SN.line).frame(height: 1)
            VStack(spacing: 10) {
                if !cart.isEmpty {
                    TextField("Notes for kitchen (allergies, preferences)", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                }
                let gross = store.grossByTax(table: table, cart: cart)
                POSBillTotals(gst: gross.gst, vat: gross.vat)
                HStack(spacing: 8) {
                    sendButton(fullWidth: true)
                    if let table, !table.liveOrders.isEmpty, let onPay {
                        Button("Bill · Pay") { onPay(table.id) }
                            .buttonStyle(POSActionStyle(fullWidth: false))
                            .accessibilityIdentifier("order-bill-pay")
                    }
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(SN.panel)
    }

    private var billLabel: String {
        var parts: [String] = []
        if let table { parts.append("Table \(table.number)") } else { parts.append(orderType == .takeaway ? "Counter" : "Delivery") }
        if let waiter = table?.activeWaiterName { parts.append(waiter) }
        return parts.joined(separator: " · ")
    }

    private func billCartRow(_ line: CartLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            POSBillLine(color: SN.amber, quantity: line.quantity, name: line.menuItem.name,
                        variant: line.variant?.name,
                        extras: line.modifiers.isEmpty ? nil : "+ " + line.modifiers.map(\.name).joined(separator: ", "),
                        note: line.notes, amount: line.lineTotal)
            HStack(spacing: 0) {
                Spacer()
                lineControls(line)
            }
        }
    }

    // MARK: - Totals

    private var cartQuantity: Int { cart.reduce(0) { $0 + $1.quantity } }

    /// The whole bill: what the table has had plus what's not sent, with tax
    private var billTotal: Int {
        let gross = store.grossByTax(table: table, cart: cart)
        return BillMath.computeBill(gst: gross.gst, vat: gross.vat, discount: 0, config: menuLoader.billingConfig).total
    }

    /// "8 items · 2 not sent"
    private var summaryText: String {
        let sent = table?.liveItems.reduce(0) { $0 + $1.quantity } ?? 0
        let all = sent + cartQuantity
        return "\(all) item\(all == 1 ? "" : "s") · \(cartQuantity) not sent"
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
            cart = []
            close(selecting: tableId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// "2" in a teal circle: how many of a dish are in the cart
private struct QuantityBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(SN.page)
            .frame(minWidth: 22, minHeight: 22)
            .background(Circle().fill(SN.teal))
            .accessibilityLabel("\(count) in the order")
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
                                Text("+\((m.price).rupees)").monospacedDigit().foregroundStyle(.secondary)
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
                            Text("\((v.price(forBase: Double(item.price))).rupees)")
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
