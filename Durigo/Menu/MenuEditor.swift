//
//  MenuEditor.swift
//  Durigo
//
//  Web-style menu admin: lists items grouped by category, supports inline
//  availability toggle, swipe-to-delete, tap-to-edit, plus item creation
//  via a sheet form. Mirrors the web's /admin/menu pages.
//
//  Models, store, list view, and edit form are all in one file so we don't
//  need to add new sources to the .xcodeproj.
//

import SwiftUI

// MARK: - Models matching the web's /api/admin/menu raw shape

/// Lightweight category reference embedded inside admin menu items.
struct AdminCategoryRef: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
}

struct AdminCategory: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let sortOrder: Int
    let active: Bool
    let type: String
}

struct AdminVariantTemplate: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let priceEquation: String
    let multiplier: Double
    let sortOrder: Int
    var showServingSize: Bool? = nil  // Optional — older variant rows on existing items omit this
    var active: Bool? = nil
}

struct AdminMenuItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var description: String?
    var price: Int
    var categoryId: String
    var category: AdminCategoryRef
    var available: Bool
    var tags: [String]
    var sortOrder: Int
    var variantTemplates: [AdminVariantTemplate]
}

// MARK: - Store

@MainActor
@Observable final class AdminMenuStore {
    private let api: APIClient
    var items: [AdminMenuItem] = []
    var categories: [AdminCategory] = []
    var variantTemplates: [AdminVariantTemplate] = []
    var isLoading = false
    /// The first load has finished (until then the list is a skeleton)
    var hasLoaded = false
    var errorMessage: String?

    init(session: Session) {
        self.api = APIClient(session: session)
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            async let itemsData = api.get("/api/admin/menu")
            async let categoriesData = api.get("/api/admin/categories")
            async let variantsData = api.get("/api/admin/variant-templates")

            let decoder = JSONDecoder()
            self.items = try decoder.decode([AdminMenuItem].self, from: try await itemsData)
            self.categories = try decoder.decode([AdminCategory].self, from: try await categoriesData)
            self.variantTemplates = try decoder.decode([AdminVariantTemplate].self, from: try await variantsData)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Toggle availability via PATCH (server flips the boolean).
    func toggleAvailability(_ item: AdminMenuItem) async {
        // Optimistic update first
        if let idx = items.firstIndex(of: item) {
            items[idx].available.toggle()
        }
        do {
            let data = try await api.patch("/api/admin/menu-items/\(item.id)")
            let updated = try JSONDecoder().decode(AdminMenuItem.self, from: data)
            if let idx = items.firstIndex(where: { $0.id == updated.id }) {
                items[idx] = updated
            }
        } catch {
            // Roll back optimistic update
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].available.toggle()
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func update(_ payload: MenuItemPayload, id: String) async throws -> AdminMenuItem {
        let data = try await api.putJSON("/api/admin/menu-items/\(id)", payload: payload)
        let updated = try JSONDecoder().decode(AdminMenuItem.self, from: data)
        if let idx = items.firstIndex(where: { $0.id == updated.id }) {
            items[idx] = updated
        }
        return updated
    }

    func create(_ payload: MenuItemPayload) async throws -> AdminMenuItem {
        let data = try await api.postJSON("/api/admin/menu-items", payload: payload)
        let created = try JSONDecoder().decode(AdminMenuItem.self, from: data)
        items.append(created)
        return created
    }

    func delete(_ item: AdminMenuItem) async throws {
        try await api.delete("/api/admin/menu-items/\(item.id)")
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Category mutations

    func createCategory(_ payload: CategoryPayload) async throws -> AdminCategory {
        let data = try await api.postJSON("/api/admin/categories", payload: payload)
        let created = try JSONDecoder().decode(AdminCategory.self, from: data)
        categories.append(created)
        return created
    }

    func updateCategory(_ payload: CategoryPayload, id: String) async throws -> AdminCategory {
        let data = try await api.putJSON("/api/admin/categories/\(id)", payload: payload)
        let updated = try JSONDecoder().decode(AdminCategory.self, from: data)
        if let idx = categories.firstIndex(where: { $0.id == updated.id }) {
            categories[idx] = updated
        }
        return updated
    }

    func deleteCategory(_ category: AdminCategory) async throws {
        try await api.delete("/api/admin/categories/\(category.id)")
        categories.removeAll { $0.id == category.id }
    }

    // MARK: - Variant template mutations

    func createVariant(_ payload: VariantPayload) async throws -> AdminVariantTemplate {
        let data = try await api.postJSON("/api/admin/variant-templates", payload: payload)
        let created = try JSONDecoder().decode(AdminVariantTemplate.self, from: data)
        variantTemplates.append(created)
        variantTemplates.sort { $0.sortOrder < $1.sortOrder }
        return created
    }

    func updateVariant(_ payload: VariantPayload, id: String) async throws -> AdminVariantTemplate {
        let data = try await api.putJSON("/api/admin/variant-templates/\(id)", payload: payload)
        let updated = try JSONDecoder().decode(AdminVariantTemplate.self, from: data)
        if let idx = variantTemplates.firstIndex(where: { $0.id == updated.id }) {
            variantTemplates[idx] = updated
        }
        return updated
    }

    func deleteVariant(_ variant: AdminVariantTemplate) async throws {
        try await api.delete("/api/admin/variant-templates/\(variant.id)")
        variantTemplates.removeAll { $0.id == variant.id }
    }

    /// Fast lookup of items grouped + sorted by category sortOrder.
    var groupedByCategory: [(category: AdminCategory, items: [AdminMenuItem])] {
        let byCategory = Dictionary(grouping: items, by: \.categoryId)
        return categories
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { cat -> (AdminCategory, [AdminMenuItem])? in
                let bucket = (byCategory[cat.id] ?? []).sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.name < $1.name
                }
                return bucket.isEmpty ? nil : (cat, bucket)
            }
    }
}

/// Request payload for create/update — matches the route handler's Zod schema.
struct MenuItemPayload: Encodable {
    let name: String
    let description: String?
    let price: Int
    let categoryId: String
    let available: Bool
    let tags: [String]
    let selectedVariantTemplates: [String]
}

struct CategoryPayload: Encodable {
    let name: String
    let description: String?
    let type: String
    let active: Bool
    let sortOrder: Int?
}

struct VariantPayload: Encodable {
    let name: String
    let description: String?
    let priceEquation: String
    let multiplier: Double
    let sortOrder: Int
    let showServingSize: Bool
}

// MARK: - Main view

struct MenuEditor: View {
    @Environment(Session.self) private var session
    @EnvironmentObject private var menuLoader: MenuLoader
    @State private var store: AdminMenuStore?
    @State private var searchText = ""
    @State private var editingItem: AdminMenuItem?
    @State private var showingNewItem = false
    @State private var showingCategories = false
    @State private var showingVariants = false
    @State private var deleteCandidate: AdminMenuItem?

    var body: some View {
        NavigationRoot {
            Group {
                if let store {
                    content(store: store)
                } else {
                    ScrollView { skeletonList(store: nil).padding(DesignTokens.spacingL) }
                        .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Menu")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingNewItem = true
                        } label: {
                            Label("New Item", systemImage: "plus")
                        }
                        Button {
                            showingCategories = true
                        } label: {
                            Label("Categories", systemImage: "folder")
                        }
                        Button {
                            showingVariants = true
                        } label: {
                            Label("Variants", systemImage: "rectangle.stack")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("admin-menu-actions-button")
                }
            }
            .sheet(item: $editingItem) { item in
                if let store {
                    MenuItemFormSheet(
                        store: store,
                        existing: item,
                        onSaved: {
                            editingItem = nil
                            await menuLoader.loadMenu()
                        }
                    )
                }
            }
            .sheet(isPresented: $showingNewItem) {
                if let store {
                    MenuItemFormSheet(
                        store: store,
                        existing: nil,
                        onSaved: {
                            showingNewItem = false
                            await menuLoader.loadMenu()
                        }
                    )
                }
            }
            .sheet(isPresented: $showingCategories) {
                if let store {
                    CategoryListSheet(
                        store: store,
                        onChange: { await menuLoader.loadMenu() }
                    )
                }
            }
            .sheet(isPresented: $showingVariants) {
                if let store {
                    VariantListSheet(
                        store: store,
                        onChange: { await menuLoader.loadMenu() }
                    )
                }
            }
            .alert(
                "Delete \(deleteCandidate?.name ?? "item")?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { item in
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await store?.delete(item)
                            await menuLoader.loadMenu()
                        } catch { /* surfaced via store.errorMessage */ }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Items with existing orders cannot be deleted — use the availability toggle instead.")
            }
            .task {
                if store == nil { store = AdminMenuStore(session: session) }
                await store?.loadAll()
            }
            .refreshable {
                await store?.loadAll()
            }
        }
    }

    @ViewBuilder
    private func content(store: AdminMenuStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                searchField
                if let msg = store.errorMessage {
                    errorBanner(msg)
                }
                let groups = filteredGroups(store: store)
                if !store.hasLoaded && groups.isEmpty {
                    skeletonList(store: store)
                } else if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.category.id) { group in
                        categorySection(category: group.category, items: group.items, store: store)
                    }
                }
            }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Loading: sample categories and items in the real sections, as placeholders
    private func skeletonList(store: AdminMenuStore?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
            ForEach(AdminCategory.sample) { category in
                categorySection(category: category,
                                items: AdminMenuItem.sample.filter { $0.categoryId == category.id },
                                store: store)
            }
        }
        .skeleton(true)
        .accessibilityIdentifier("menu-loading")
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by name", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("admin-menu-search")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignTokens.spacingM)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusSmall)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(DesignTokens.spacingM)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingM) {
            Image(systemName: "fork.knife")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No menu items yet" : "No matches for \"\(searchText)\"")
                .font(.system(.headline, weight: .semibold))
            if searchText.isEmpty {
                Text("Tap + to add your first item.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.spacing2XL)
    }

    private func categorySection(
        category: AdminCategory,
        items: [AdminMenuItem],
        store: AdminMenuStore?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(category.name)
                    .font(.system(.headline, weight: .semibold))
                Text(categoryTypeLabel(category.type))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.top, DesignTokens.spacingL)
            .padding(.bottom, DesignTokens.spacingS)

            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                MenuItemRow(
                    item: item,
                    onToggle: { Task { await store?.toggleAvailability(item) } },
                    onTap: { editingItem = item },
                    onDelete: { deleteCandidate = item }
                )
                if idx < items.count - 1 {
                    Divider()
                        .background(Color.primary.opacity(DesignTokens.borderOpacity))
                        .padding(.leading, DesignTokens.spacingL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusMedium)
    }

    private func categoryTypeLabel(_ type: String) -> String {
        switch type.uppercased() {
        case "FOOD": "Food"
        case "BEVERAGE": "Beverage"
        case "ALCOHOL": "Alcohol"
        default: type
        }
    }

    private func filteredGroups(store: AdminMenuStore) -> [(category: AdminCategory, items: [AdminMenuItem])] {
        let groups = store.groupedByCategory
        guard !searchText.isEmpty else { return groups }
        let q = searchText.lowercased()
        return groups.compactMap { g -> (AdminCategory, [AdminMenuItem])? in
            let filtered = g.items.filter { $0.name.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
            return filtered.isEmpty ? nil : (g.category, filtered)
        }
    }
}

// MARK: - Single row

private struct MenuItemRow: View {
    let item: AdminMenuItem
    let onToggle: () -> Void
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(.body, weight: .semibold))
                        .strikethrough(!item.available, color: .secondary)
                        .foregroundStyle(item.available ? .primary : .secondary)
                    if !item.variantTemplates.isEmpty {
                        Text("\(item.variantTemplates.count) variant\(item.variantTemplates.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                if let desc = item.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text("\((item.price).rupees)")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(item.available ? .primary : .secondary)
            Toggle("", isOn: Binding(
                get: { item.available },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .accessibilityIdentifier("admin-menu-availability-\(item.id)")
        }
        .padding(.horizontal, DesignTokens.spacingL)
        .padding(.vertical, DesignTokens.spacingM)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Form sheet (create + edit)

private struct MenuItemFormSheet: View {
    let store: AdminMenuStore
    let existing: AdminMenuItem?
    let onSaved: () async -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var price: Int = 0
    @State private var categoryId: String = ""
    @State private var available: Bool = true
    @State private var tags: [String] = []
    @State private var newTag: String = ""
    @State private var selectedVariantIDs: Set<String> = []
    @State private var saving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("admin-menu-form-name")
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                    HStack {
                        Text("Price")
                        Spacer()
                        Text("₹")
                        TextField("0", value: $price, format: .number).labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                            .accessibilityIdentifier("admin-menu-form-price")
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $categoryId) {
                        Text("Select…").tag("")
                        ForEach(store.categories, id: \.id) { cat in
                            Text(cat.name).tag(cat.id)
                        }
                    }
                }

                Section("Availability") {
                    Toggle("Available", isOn: $available)
                }

                Section("Tags") {
                    if !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag).font(.caption)
                                        Button {
                                            tags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("Add a tag", text: $newTag)
                            .onSubmit { addTag() }
                        Button("Add", action: addTag)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if !store.variantTemplates.isEmpty {
                    Section("Variants") {
                        ForEach(store.variantTemplates) { template in
                            HStack {
                                Image(systemName: selectedVariantIDs.contains(template.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedVariantIDs.contains(template.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                    if let desc = template.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(template.priceEquation)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedVariantIDs.contains(template.id) {
                                    selectedVariantIDs.remove(template.id)
                                } else {
                                    selectedVariantIDs.insert(template.id)
                                }
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Item" : "Edit Item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!isFormValid)
                    }
                }
            }
            .onAppear(perform: loadInitial)
        }
        .interactiveDismissDisabled(saving)
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && price >= 0
        && !categoryId.isEmpty
    }

    private func loadInitial() {
        guard let existing else {
            // New item: default to first category
            if categoryId.isEmpty, let first = store.categories.first {
                categoryId = first.id
            }
            return
        }
        name = existing.name
        description = existing.description ?? ""
        price = existing.price
        categoryId = existing.categoryId
        available = existing.available
        tags = existing.tags
        selectedVariantIDs = Set(existing.variantTemplates.map(\.id))
    }

    private func addTag() {
        let cleaned = newTag.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, !tags.contains(cleaned) else { return }
        tags.append(cleaned)
        newTag = ""
    }

    private func save() {
        let payload = MenuItemPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            price: price,
            categoryId: categoryId,
            available: available,
            tags: tags,
            selectedVariantTemplates: Array(selectedVariantIDs)
        )
        saving = true
        errorMessage = nil
        Task {
            do {
                if let existing {
                    _ = try await store.update(payload, id: existing.id)
                } else {
                    _ = try await store.create(payload)
                }
                await onSaved()
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Category list + form

private struct CategoryListSheet: View {
    let store: AdminMenuStore
    let onChange: () async -> Void

    @State private var editing: AdminCategory?
    @State private var creating = false
    @State private var deleteCandidate: AdminCategory?
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.categories.sorted(by: { $0.sortOrder < $1.sortOrder })) { cat in
                    Button {
                        editing = cat
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.name)
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text(cat.type)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                    if !cat.active {
                                        Text("Inactive")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteCandidate = cat
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Categories")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { cat in
                CategoryFormSheet(store: store, existing: cat, onSaved: {
                    editing = nil
                    await onChange()
                })
            }
            .sheet(isPresented: $creating) {
                CategoryFormSheet(store: store, existing: nil, onSaved: {
                    creating = false
                    await onChange()
                })
            }
            .alert(
                "Delete \(deleteCandidate?.name ?? "category")?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { cat in
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await store.deleteCategory(cat)
                            await onChange()
                        } catch {
                            deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Categories with menu items cannot be deleted.")
            }
            .alert(
                "Couldn't delete",
                isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                ),
                presenting: deleteError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }
}

private struct CategoryFormSheet: View {
    let store: AdminMenuStore
    let existing: AdminCategory?
    let onSaved: () async -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var type: String = "FOOD"
    @State private var active: Bool = true
    @State private var saving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("admin-category-form-name")
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("Type") {
                    Picker("Type", selection: $type) {
                        Text("Food").tag("FOOD")
                        Text("Beverage").tag("BEVERAGE")
                        Text("Alcohol").tag("ALCOHOL")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Active") {
                    Toggle("Active", isOn: $active)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Category" : "Edit Category")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    description = existing.description ?? ""
                    type = existing.type
                    active = existing.active
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        let payload = CategoryPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            type: type,
            active: active,
            sortOrder: nil
        )
        saving = true
        errorMessage = nil
        Task {
            do {
                if let existing {
                    _ = try await store.updateCategory(payload, id: existing.id)
                } else {
                    _ = try await store.createCategory(payload)
                }
                await onSaved()
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Variant list + form

private struct VariantListSheet: View {
    let store: AdminMenuStore
    let onChange: () async -> Void

    @State private var editing: AdminVariantTemplate?
    @State private var creating = false
    @State private var deleteCandidate: AdminVariantTemplate?
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.variantTemplates) { v in
                        Button {
                            editing = v
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name).font(.system(.body, weight: .semibold)).foregroundStyle(.primary)
                                    Text(v.priceEquation)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if v.showServingSize == true {
                                    Image(systemName: "eye")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteCandidate = v
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Templates")
                } footer: {
                    Text("Use `x` in price equations as the base price (e.g. `0.5*x`, `x+100`).")
                        .font(.caption)
                }
            }
            .navigationTitle("Variants")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { v in
                VariantFormSheet(store: store, existing: v, onSaved: {
                    editing = nil
                    await onChange()
                })
            }
            .sheet(isPresented: $creating) {
                VariantFormSheet(store: store, existing: nil, onSaved: {
                    creating = false
                    await onChange()
                })
            }
            .alert(
                "Delete \(deleteCandidate?.name ?? "template")?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { v in
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await store.deleteVariant(v)
                            await onChange()
                        } catch {
                            deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Templates that are still in use cannot be deleted.")
            }
            .alert(
                "Couldn't delete",
                isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                ),
                presenting: deleteError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }
}

private struct VariantFormSheet: View {
    let store: AdminMenuStore
    let existing: AdminVariantTemplate?
    let onSaved: () async -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var priceEquation: String = "x"
    @State private var multiplier: Double = 1.0
    @State private var sortOrder: Int = 0
    @State private var showServingSize: Bool = false
    @State private var saving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name (e.g. Peg, Half, Full)", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    HStack {
                        Text("Equation")
                        Spacer()
                        TextField("x", text: $priceEquation)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Multiplier")
                        Spacer()
                        TextField("1.0", value: $multiplier, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                    }
                } header: {
                    Text("Pricing")
                } footer: {
                    Text("Use `x` for the base price. Examples: `x` (same), `0.5*x` (half), `x+100` (markup).")
                        .font(.caption)
                }
                Section("Display") {
                    Toggle("Show on bill", isOn: $showServingSize)
                    HStack {
                        Text("Sort order")
                        Spacer()
                        TextField("0", value: $sortOrder, format: .number).labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Variant" : "Edit Variant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                      || priceEquation.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    description = existing.description ?? ""
                    priceEquation = existing.priceEquation
                    multiplier = existing.multiplier
                    sortOrder = existing.sortOrder
                    showServingSize = existing.showServingSize ?? false
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        let payload = VariantPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            priceEquation: priceEquation.trimmingCharacters(in: .whitespaces),
            multiplier: multiplier,
            sortOrder: sortOrder,
            showServingSize: showServingSize
        )
        saving = true
        errorMessage = nil
        Task {
            do {
                if let existing {
                    _ = try await store.updateVariant(payload, id: existing.id)
                } else {
                    _ = try await store.createVariant(payload)
                }
                await onSaved()
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

#Preview {
    MenuEditor()
        .environment(Session())
        .environmentObject(MenuLoader())
}
