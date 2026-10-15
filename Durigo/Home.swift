//
//  Home.swift
//  Durigo
//
//  Root navigation container, restructured to mirror the web's sidebar.
//  Sections: Overview / Operations / Management / Analytics + Settings.
//
//  iPhone: bottom tabs (Dashboard, POS, Billing, Reports, More).
//  iPad:   collapsible NavigationSplitView with full grouped sidebar.
//
//  Most screens (Dashboard, Settings, ComingSoon stubs) live below in the
//  same file so we don't have to add new sources to the .xcodeproj.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreTransferable

// MARK: - iPhone bottom-tab roots

enum IPhoneRoot: Hashable {
    case item(NavigationItem)
    case more
}

// MARK: - Root container

struct Home: View {
    @StateObject private var menuLoader = MenuLoader()
    @StateObject private var navigation = Navigation()
    @Query private var billHistoryItems: [BillHistoryItem]
    @Environment(\.modelContext) var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Session.self) private var session
    @State private var columnVisibility: NavigationSplitViewVisibility = .all


    private var pendingCount: Int {
        billHistoryItems.count { $0.paymentStatus == .pending }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                iPadShell
            } else {
                iPhoneShell
            }
        }
        .onOpenURL { url in handleIncomingURL(url) }
        .environmentObject(menuLoader)
        .environmentObject(navigation)
        .onAppear {
            menuLoader.authSession = session
            navigation.selection = startingItem(for: role, requested: navigation.selection)
            // After the first layout: a visibility set before it is ignored
            DispatchQueue.main.async { fitSidebar(to: navigation.selection) }
        }
        // The kitchen board gets the whole screen, as on the web
        .onChange(of: navigation.selection) { _, item in fitSidebar(to: item) }
        // A different person signing in lands on a screen their role can use
        .onChange(of: role) {
            navigation.selection = startingItem(for: role, requested: navigation.selection)
        }
    }

    // MARK: - iPhone shell

    private var role: String? { session.user?.role }
    private var rootTabs: [NavigationItem] { iPhoneRootTabs(for: role) }

    private var iPhoneShell: some View {
        TabView(selection: iPhoneRootBinding) {
            ForEach(rootTabs) { item in
                destination(for: item)
                    .tabItem { Label(item.title, systemImage: item.icon) }
                    .badge(item == .billing ? pendingCount : 0)
                    .tag(IPhoneRoot.item(item))
            }

            iPhoneMore
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(IPhoneRoot.more)
        }
    }

    /// "More" tab: every screen this role can use that isn't a bottom tab,
    /// plus Settings.
    private var iPhoneMore: some View {
        NavigationStack {
            List {
                ForEach(NavigationSection.allCases) { section in
                    let items = section.items.filter { $0.isAllowed(for: role) && !rootTabs.contains($0) }
                    if !items.isEmpty {
                        Section(section.title) {
                            ForEach(items) { moreLink($0) }
                        }
                    }
                }
                Section("Account") {
                    moreLink(.settings)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("More")
        }
    }

    /// iPad/Mac: hide the sidebar on the kitchen board; bring it back after
    private func fitSidebar(to item: NavigationItem) {
        if item == .kitchen {
            columnVisibility = .detailOnly
        } else if columnVisibility == .detailOnly {
            columnVisibility = .all
        }
    }

    private func moreLink(_ item: NavigationItem) -> some View {
        NavigationLink {
            destination(for: item)
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label(item.title, systemImage: item.icon)
        }
        .accessibilityIdentifier("more-link-\(item.title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    /// Maps NavigationItem.selection ↔ the iPhone tab. Screens that aren't a
    /// bottom tab live under More.
    private var iPhoneRootBinding: Binding<IPhoneRoot> {
        Binding(
            get: { rootTabs.contains(navigation.selection) ? .item(navigation.selection) : .more },
            set: { newRoot in
                if case .item(let item) = newRoot { navigation.selection = item }
                // .more: the user navigates within More via NavigationLinks
            }
        )
    }

    // MARK: - iPad shell

    private var iPadShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            NavigationStack {
                destination(for: navigation.selection)
                    .toolbar {
                        // One sidebar button, never two: the system shows its
                        // own on the Mac, and on iPad once the sidebar is
                        // folded away; this one covers iPad with it open
                        #if os(iOS)
                        if columnVisibility != .detailOnly {
                            ToolbarItem(placement: .navigation) {
                                Button {
                                    withAnimation { columnVisibility = .detailOnly }
                                } label: {
                                    Image(systemName: "sidebar.left")
                                }
                                .accessibilityLabel("Hide sidebar")
                            }
                        }
                        #endif
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { navigation.selection },
            set: { if let v = $0 { navigation.selection = v } }
        )) {
            Section { } header: { brandHeader.padding(.bottom, 4) }

            ForEach(NavigationSection.allCases) { section in
                let items = section.items.filter { $0.isAllowed(for: role) }
                if !items.isEmpty {
                    Section(section.title) {
                        ForEach(items) { item in
                            sidebarRow(item).tag(item)
                        }
                    }
                }
            }

            Section {
                sidebarRow(.settings).tag(NavigationItem.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private func sidebarRow(_ item: NavigationItem) -> some View {
        Label {
            HStack {
                Text(item.title)
                if item == .billing && pendingCount > 0 {
                    Spacer()
                    Text("\(pendingCount)")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
            }
        } icon: {
            Image(systemName: item.icon)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 24, height: 24)
                Image(systemName: "fork.knife")
                    .font(.system(size: 12, weight: .medium))
            }
            Text("Durigo's")
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    // MARK: - Destination switch

    @ViewBuilder
    private func destination(for item: NavigationItem) -> some View {
        switch item {
        case .dashboard:    ServiceNightDashboard()
        case .pos:          POSContainerView()
        case .kitchen:      KitchenAdminView()
        case .billing:      BillingView()
        case .reservations: ReservationsAdminView()
        case .menu:         MenuEditor()
        case .modifiers:    ModifiersAdminView()
        case .discounts:    DiscountsAdminView()
        case .inventory:    InventoryAdminView()
        case .users:        UsersAdminView()
        case .reports:      Reports()
        case .settings:     SettingsView()
        }
    }

    // MARK: - Document import (iOS bills file)

    private func handleIncomingURL(_ url: URL) {
        // Files are opened in place (macOS requires it), so the URL may point
        // outside the sandbox and must be accessed as security-scoped
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let durigoBills = try JSONDecoder().decode(DurigoBills.self, from: data)
            durigoBills.items.forEach { copy in
                let item = copy.convertToBillHistoryItem()
                if !billHistoryItems.contains(where: { $0.id == item.id }) {
                    modelContext.insert(item)
                }
            }
        } catch {
            print("Error decoding object: \(error)")
        }
    }
}

// MARK: - Coming Soon stub

struct ComingSoonView: View {
    let title: String
    let icon: String
    let note: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                VStack(spacing: DesignTokens.spacingM) {
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        Text(title)
                            .font(.system(.title2, weight: .bold))
                        Text("Coming soon")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(DesignTokens.spacing2XL)
                .webCardBackground()
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Settings + Logout

struct SettingsView: View {
    @Environment(Session.self) private var session
    @State private var showingLogoutConfirm = false
    @State private var loggingOut = false

    var body: some View {
        NavigationStack {
            Form {
                if let user = session.user {
                    Section("Account") {
                        LabeledContent("Name", value: user.name)
                        LabeledContent("Username", value: user.username)
                        LabeledContent("Role", value: user.role)
                    }
                }

                // Only an admin can change restaurant settings (the server refuses others)
                if session.user?.role.uppercased() == "ADMIN" {
                    Section {
                        NavigationLink {
                            AppSettingsForm()
                        } label: {
                            Label("Restaurant settings", systemImage: "building.2")
                        }
                        .accessibilityIdentifier("settings-restaurant-link")
                    } header: {
                        Text("Configuration")
                    } footer: {
                        Text("The restaurant details and GST/VAT rates printed on every bill.")
                            .font(.caption)
                    }
                }

                Section("Server") {
                    LabeledContent("URL", value: Config.shared.serverURL)
                }

                Section("About") {
                    LabeledContent("App Version", value: Bundle.main.shortVersion)
                    LabeledContent("Build", value: Bundle.main.buildNumber)
                }

                Section {
                    Button(role: .destructive) {
                        showingLogoutConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text(loggingOut ? "Signing out…" : "Sign Out")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(loggingOut)
                    .accessibilityIdentifier("settings-logout-button")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert("Sign out?", isPresented: $showingLogoutConfirm) {
                Button("Sign Out", role: .destructive) {
                    loggingOut = true
                    Task {
                        await session.signOutRemotely()
                        loggingOut = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to sign in again to use the app.")
            }
        }
    }
}

private extension Bundle {
    var shortVersion: String { (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—" }
    var buildNumber: String { (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—" }
}

// MARK: - Users admin

struct AdminUserModel: Codable, Identifiable, Hashable {
    let id: String
    let email: String
    let username: String
    let name: String
    let role: String
    var active: Bool
}

struct AdminUserPayload: Encodable {
    let email: String
    let username: String
    let name: String
    let password: String?
    let role: String
    let active: Bool
}

@MainActor @Observable final class UsersStore {
    private let api: APIClient
    var items: [AdminUserModel] = []
    var isLoading = false
    /// The first load has finished (until then the screen is a skeleton)
    var hasLoaded = false
    var errorMessage: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let data = try await api.get("/api/admin/users")
            items = try JSONDecoder().decode([AdminUserModel].self, from: data)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func create(_ payload: AdminUserPayload) async throws -> AdminUserModel {
        let data = try await api.postJSON("/api/admin/users", payload: payload)
        let created = try JSONDecoder().decode(AdminUserModel.self, from: data)
        items.append(created)
        return created
    }

    func update(_ payload: AdminUserPayload, id: String) async throws -> AdminUserModel {
        let data = try await api.putJSON("/api/admin/users/\(id)", payload: payload)
        let updated = try JSONDecoder().decode(AdminUserModel.self, from: data)
        if let idx = items.firstIndex(where: { $0.id == updated.id }) { items[idx] = updated }
        return updated
    }

    func delete(_ user: AdminUserModel) async throws {
        try await api.delete("/api/admin/users/\(user.id)")
        items.removeAll { $0.id == user.id }
    }

    /// Most user records group by role. Sorted: Admin first, then alphabetical.
    var groupedByRole: [(role: String, users: [AdminUserModel])] {
        let order: [String: Int] = ["ADMIN": 0, "WAITER": 1, "KITCHEN": 2, "CASHIER": 3]
        let grouped = Dictionary(grouping: items, by: \.role)
        return grouped
            .sorted { (order[$0.key] ?? 99) < (order[$1.key] ?? 99) }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
    }
}

struct UsersAdminView: View {
    @Environment(Session.self) private var session
    @State private var store: UsersStore?
    @State private var editing: AdminUserModel?
    @State private var creating = false
    @State private var deleteCandidate: AdminUserModel?

    var body: some View {
        NavigationStack {
            Group {
                if let store {
                    content(store: store)
                } else {
                    Color(.systemGroupedBackground)
                }
            }
            .navigationTitle("Users")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("admin-users-new")
                }
            }
            .sheet(item: $editing) { user in
                if let store { UserFormSheet(store: store, existing: user) }
            }
            .sheet(isPresented: $creating) {
                if let store { UserFormSheet(store: store, existing: nil) }
            }
            .alert(
                "Delete \(deleteCandidate?.name ?? "user")?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { user in
                Button("Delete", role: .destructive) {
                    Task { try? await store?.delete(user) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This is permanent. Sessions for this user are revoked.")
            }
            .task {
                if store == nil { store = UsersStore(session: session) }
                await store?.load()
            }
            .refreshable { await store?.load() }
        }
    }

    @ViewBuilder
    private func content(store: UsersStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let msg = store.errorMessage { errorBanner(msg) }
                if !store.hasLoaded && store.items.isEmpty {
                    // Loading: sample staff in the real sections, as placeholders
                    VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                        ForEach(["ADMIN", "WAITER", "KITCHEN", "CASHIER"], id: \.self) { role in
                            roleSection(role: role, users: AdminUserModel.sample.filter { $0.role == role })
                        }
                    }
                    .skeleton(true)
                    .accessibilityIdentifier("users-loading")
                } else if store.items.isEmpty {
                    emptyState
                } else {
                    ForEach(store.groupedByRole, id: \.role) { group in
                        roleSection(role: group.role, users: group.users)
                    }
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func roleSection(role: String, users: [AdminUserModel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(roleTitle(role))
                    .font(.system(.headline, weight: .semibold))
                Spacer()
                Text("\(users.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.top, DesignTokens.spacingL)
            .padding(.bottom, DesignTokens.spacingS)

            ForEach(Array(users.enumerated()), id: \.element.id) { idx, user in
                userRow(user)
                if idx < users.count - 1 {
                    Divider()
                        .background(Color.primary.opacity(DesignTokens.borderOpacity))
                        .padding(.leading, DesignTokens.spacingL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private func userRow(_ user: AdminUserModel) -> some View {
        Button {
            editing = user
        } label: {
            HStack(spacing: DesignTokens.spacingM) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 36, height: 36)
                    Text(initials(user.name))
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.name)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !user.active {
                            Text("Inactive")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    Text("@\(user.username) · \(user.email)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, DesignTokens.spacingL)
            .padding(.vertical, DesignTokens.spacingM)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleteCandidate = user } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func roleTitle(_ role: String) -> String {
        switch role.uppercased() {
        case "ADMIN": "Administrators"
        case "WAITER": "Waitstaff"
        case "KITCHEN": "Kitchen"
        case "CASHIER": "Cashiers"
        default: role.capitalized
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").compactMap { $0.first.map(String.init) }
        return parts.prefix(2).joined().uppercased()
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingM) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No users yet").font(.headline)
            Text("Tap + to add an admin, waiter, kitchen, or cashier account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.spacing2XL)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.subheadline)
            Spacer()
        }
        .padding(DesignTokens.spacingM)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous).stroke(Color.red.opacity(0.25), lineWidth: 1))
    }
}

private struct UserFormSheet: View {
    let store: UsersStore
    let existing: AdminUserModel?

    @State private var name = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var role = "WAITER"
    @State private var active = true
    @State private var saving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Full name", text: $name)
                        .accessibilityIdentifier("user-form-name")
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .accessibilityIdentifier("user-form-email")
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("user-form-username")
                }
                Section {
                    SecureField(existing == nil ? "Password" : "New password (leave empty to keep)", text: $password)
                        .accessibilityIdentifier("user-form-password")
                } header: {
                    Text("Password")
                } footer: {
                    if existing != nil {
                        Text("Leave empty to keep the current password.").font(.caption)
                    }
                }
                Section("Role") {
                    Picker("Role", selection: $role) {
                        Text("Admin").tag("ADMIN")
                        Text("Waiter").tag("WAITER")
                        Text("Kitchen").tag("KITCHEN")
                        Text("Cashier").tag("CASHIER")
                    }
                }
                Section("Active") {
                    Toggle("Active", isOn: $active)
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.subheadline).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New User" : "Edit User")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else {
                        Button("Save", action: save).disabled(!isValid)
                    }
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    email = existing.email
                    username = existing.username
                    role = existing.role
                    active = existing.active
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && email.contains("@")
        && username.count >= 3
        && (existing != nil || password.count >= 6)
    }

    private func save() {
        let payload = AdminUserPayload(
            email: email.trimmingCharacters(in: .whitespaces).lowercased(),
            username: username.trimmingCharacters(in: .whitespaces).lowercased(),
            name: name.trimmingCharacters(in: .whitespaces),
            password: password.isEmpty ? nil : password,
            role: role,
            active: active
        )
        saving = true; errorMessage = nil
        Task {
            do {
                if let existing { _ = try await store.update(payload, id: existing.id) }
                else { _ = try await store.create(payload) }
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Discounts admin

struct AdminDiscount: Codable, Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let description: String?
    let type: String   // PERCENTAGE | FIXED | BOGO
    let value: Int
    let minOrderValue: Int?
    let maxDiscount: Int?
    let applicableTo: [String]
    let usageLimit: Int?
    let usageCount: Int
    let perUserLimit: Int?
    let validFrom: String   // ISO8601
    let validUntil: String?
    var active: Bool
}

struct DiscountPayload: Encodable {
    let code: String
    let name: String
    let description: String?
    let type: String
    let value: Int
    let minOrderValue: Int?
    let maxDiscount: Int?
    let applicableTo: [String]
    let usageLimit: Int?
    let perUserLimit: Int?
    let validFrom: String
    let validUntil: String?
    let active: Bool?
}

@MainActor @Observable final class DiscountsStore {
    private let api: APIClient
    var items: [AdminDiscount] = []
    var isLoading = false
    /// The first load has finished (until then the screen is a skeleton)
    var hasLoaded = false
    var errorMessage: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let data = try await api.get("/api/admin/discounts")
            items = try JSONDecoder().decode([AdminDiscount].self, from: data)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func create(_ payload: DiscountPayload) async throws -> AdminDiscount {
        let data = try await api.postJSON("/api/admin/discounts", payload: payload)
        let created = try JSONDecoder().decode(AdminDiscount.self, from: data)
        items.insert(created, at: 0)
        return created
    }

    func update(_ payload: DiscountPayload, id: String) async throws -> AdminDiscount {
        let body = try JSONEncoder().encode(payload)
        let data = try await api.patch("/api/admin/discounts/\(id)", body: body)
        let updated = try JSONDecoder().decode(AdminDiscount.self, from: data)
        if let idx = items.firstIndex(where: { $0.id == updated.id }) { items[idx] = updated }
        return updated
    }

    func delete(_ d: AdminDiscount) async throws {
        try await api.delete("/api/admin/discounts/\(d.id)")
        items.removeAll { $0.id == d.id }
    }
}

struct DiscountsAdminView: View {
    @Environment(Session.self) private var session
    @State private var store: DiscountsStore?
    @State private var editing: AdminDiscount?
    @State private var creating = false
    @State private var deleteCandidate: AdminDiscount?

    var body: some View {
        NavigationStack {
            Group {
                if let store { content(store: store) }
                else { Color(.systemGroupedBackground) }
            }
            .navigationTitle("Discounts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("admin-discounts-new")
                }
            }
            .sheet(item: $editing) { d in
                if let store { DiscountFormSheet(store: store, existing: d) }
            }
            .sheet(isPresented: $creating) {
                if let store { DiscountFormSheet(store: store, existing: nil) }
            }
            .alert(
                "Delete \(deleteCandidate?.code ?? "discount")?",
                isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                presenting: deleteCandidate
            ) { d in
                Button("Delete", role: .destructive) { Task { try? await store?.delete(d) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Discounts already used on past orders stay attached to those records.") }
            .task {
                if store == nil { store = DiscountsStore(session: session) }
                await store?.load()
            }
            .refreshable { await store?.load() }
        }
    }

    @ViewBuilder
    private func content(store: DiscountsStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let msg = store.errorMessage {
                    HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
                        .padding(DesignTokens.spacingM)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous).fill(Color.red.opacity(0.08)))
                }
                if !store.hasLoaded && store.items.isEmpty {
                    // Loading: sample discounts in the real card, as placeholders
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(AdminDiscount.sample) { d in
                            discountRow(d)
                            Divider().background(Color.primary.opacity(DesignTokens.borderOpacity)).padding(.leading, DesignTokens.spacingL)
                        }
                    }
                    .webCardBackground()
                    .skeleton(true)
                    .accessibilityIdentifier("discounts-loading")
                } else if store.items.isEmpty {
                    VStack(spacing: DesignTokens.spacingM) {
                        Image(systemName: "ticket").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        Text("No discounts yet").font(.headline)
                        Text("Promo codes like WELCOME10 go here.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(DesignTokens.spacing2XL)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, d in
                            discountRow(d)
                            if idx < store.items.count - 1 {
                                Divider().background(Color.primary.opacity(DesignTokens.borderOpacity)).padding(.leading, DesignTokens.spacingL)
                            }
                        }
                    }
                    .webCardBackground()
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func discountRow(_ d: AdminDiscount) -> some View {
        Button {
            editing = d
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(d.code).font(.system(.body, design: .monospaced, weight: .bold))
                    if !d.active {
                        Text("Inactive").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Spacer()
                    Text(formatValue(d)).font(.system(.body, weight: .semibold)).foregroundStyle(.green)
                }
                Text(d.name).font(.subheadline).foregroundStyle(.primary)
                if let desc = d.description, !desc.isEmpty {
                    Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let limit = d.usageLimit {
                        Text("\(d.usageCount)/\(limit) used").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("\(d.usageCount) used").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let until = d.validUntil { Text("· valid until \(formatDate(until))").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .padding(.horizontal, DesignTokens.spacingL).padding(.vertical, DesignTokens.spacingM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleteCandidate = d } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func formatValue(_ d: AdminDiscount) -> String {
        switch d.type {
        case "PERCENTAGE": "\(d.value)% off"
        case "FIXED":      "\((d.value).rupees) off"
        case "BOGO":       "BOGO"
        default:           "\(d.value)"
        }
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .none
        return df.string(from: date)
    }
}

private struct DiscountFormSheet: View {
    let store: DiscountsStore
    let existing: AdminDiscount?

    @State private var code = ""
    @State private var name = ""
    @State private var description = ""
    @State private var type = "PERCENTAGE"
    @State private var value = 10
    @State private var minOrderValue = 0
    @State private var hasMin = false
    @State private var maxDiscount = 0
    @State private var hasMax = false
    @State private var usageLimit = 100
    @State private var hasLimit = false
    @State private var validFrom = Date()
    @State private var validUntil = Date().addingTimeInterval(30*24*3600)
    @State private var hasUntil = false
    @State private var active = true
    @State private var saving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Code") {
                    TextField("WELCOME10", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("discount-form-code")
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("discount-form-name")
                    TextField("Description (optional)", text: $description, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("discount-form-description")
                }
                Section("Type & value") {
                    Picker("Type", selection: $type) {
                        Text("Percentage").tag("PERCENTAGE")
                        Text("Fixed (₹)").tag("FIXED")
                        Text("BOGO").tag("BOGO")
                    }
                    HStack {
                        Text(type == "PERCENTAGE" ? "Value (%)" : "Value (₹)")
                        Spacer()
                        TextField("0", value: $value, format: .number).labelsHidden()
                            .multilineTextAlignment(.trailing).frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                    }
                }
                Section("Limits") {
                    Toggle("Minimum order value", isOn: $hasMin)
                    if hasMin {
                        HStack { Text("Min ₹"); Spacer(); TextField("0", value: $minOrderValue, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                        }
                    }
                    Toggle("Cap discount", isOn: $hasMax)
                    if hasMax {
                        HStack { Text("Max ₹"); Spacer(); TextField("0", value: $maxDiscount, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                        }
                    }
                    Toggle("Limit total uses", isOn: $hasLimit)
                    if hasLimit {
                        HStack { Text("Total uses"); Spacer(); TextField("0", value: $usageLimit, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                        }
                    }
                }
                Section("Validity") {
                    DatePicker("Valid from", selection: $validFrom, displayedComponents: .date)
                    Toggle("Has expiry", isOn: $hasUntil)
                    if hasUntil {
                        DatePicker("Valid until", selection: $validUntil, in: validFrom..., displayedComponents: .date)
                    }
                }
                Section("Active") { Toggle("Active", isOn: $active) }
                if let errorMessage { Section { Text(errorMessage).font(.subheadline).foregroundStyle(.red) } }
            }
            .navigationTitle(existing == nil ? "New Discount" : "Edit Discount")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save", action: save).disabled(!isValid) }
                }
            }
            .onAppear(perform: loadInitial)
        }
        .interactiveDismissDisabled(saving)
    }

    private var isValid: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty
        && !name.trimmingCharacters(in: .whitespaces).isEmpty
        && value > 0
        && (type != "PERCENTAGE" || value <= 100)
    }

    private func loadInitial() {
        guard let e = existing else { return }
        code = e.code; name = e.name
        description = e.description ?? ""
        type = e.type
        value = e.value
        if let m = e.minOrderValue { hasMin = true; minOrderValue = m }
        if let m = e.maxDiscount { hasMax = true; maxDiscount = m }
        if let l = e.usageLimit { hasLimit = true; usageLimit = l }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: e.validFrom) ?? ISO8601DateFormatter().date(from: e.validFrom) { validFrom = d }
        if let until = e.validUntil, let d = f.date(from: until) ?? ISO8601DateFormatter().date(from: until) {
            hasUntil = true; validUntil = d
        }
        active = e.active
    }

    private func save() {
        let f = ISO8601DateFormatter()
        let payload = DiscountPayload(
            code: code.trimmingCharacters(in: .whitespaces).uppercased(),
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            type: type,
            value: value,
            minOrderValue: hasMin ? minOrderValue : nil,
            maxDiscount: hasMax ? maxDiscount : nil,
            applicableTo: ["all"],
            usageLimit: hasLimit ? usageLimit : nil,
            perUserLimit: nil,
            validFrom: f.string(from: validFrom),
            validUntil: hasUntil ? f.string(from: validUntil) : nil,
            active: active
        )
        saving = true; errorMessage = nil
        Task {
            do {
                if let existing { _ = try await store.update(payload, id: existing.id) }
                else { _ = try await store.create(payload) }
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Modifiers admin

struct AdminCategoryRefMin: Codable, Hashable {
    let id: String
    let name: String
}

struct AdminModifier: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let price: Int
    let type: String   // ADD | REMOVE | SUBSTITUTE | SPECIAL
    let categoryId: String?
    let category: AdminCategoryRefMin?
    var active: Bool
    let sortOrder: Int
}

struct ModifierPayload: Encodable {
    let name: String
    let description: String?
    let price: Int
    let type: String
    let categoryId: String?
    let sortOrder: Int
    let active: Bool?
}

@MainActor @Observable final class ModifiersStore {
    private let api: APIClient
    var items: [AdminModifier] = []
    var categories: [AdminCategory] = []
    var isLoading = false
    /// The first load has finished (until then the screen is a skeleton)
    var hasLoaded = false
    var errorMessage: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            async let modsData = api.get("/api/admin/modifiers")
            async let catsData = api.get("/api/admin/categories")
            items = try JSONDecoder().decode([AdminModifier].self, from: try await modsData)
            categories = try JSONDecoder().decode([AdminCategory].self, from: try await catsData)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func create(_ payload: ModifierPayload) async throws -> AdminModifier {
        let data = try await api.postJSON("/api/admin/modifiers", payload: payload)
        let created = try JSONDecoder().decode(AdminModifier.self, from: data)
        items.append(created)
        return created
    }

    func update(_ payload: ModifierPayload, id: String) async throws -> AdminModifier {
        let body = try JSONEncoder().encode(payload)
        let data = try await api.patch("/api/admin/modifiers/\(id)", body: body)
        let updated = try JSONDecoder().decode(AdminModifier.self, from: data)
        if let idx = items.firstIndex(where: { $0.id == updated.id }) { items[idx] = updated }
        return updated
    }

    func delete(_ m: AdminModifier) async throws {
        try await api.delete("/api/admin/modifiers/\(m.id)")
        items.removeAll { $0.id == m.id }
    }

    var groupedByType: [(type: String, mods: [AdminModifier])] {
        let order: [String: Int] = ["ADD": 0, "REMOVE": 1, "SUBSTITUTE": 2, "SPECIAL": 3]
        let grouped = Dictionary(grouping: items, by: \.type)
        return grouped
            .sorted { (order[$0.key] ?? 99) < (order[$1.key] ?? 99) }
            .map { ($0.key, $0.value.sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }) }
    }
}

struct ModifiersAdminView: View {
    @Environment(Session.self) private var session
    @State private var store: ModifiersStore?
    @State private var editing: AdminModifier?
    @State private var creating = false
    @State private var deleteCandidate: AdminModifier?

    var body: some View {
        NavigationStack {
            Group {
                if let store { content(store: store) }
                else { Color(.systemGroupedBackground) }
            }
            .navigationTitle("Modifiers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("admin-modifiers-new")
                }
            }
            .sheet(item: $editing) { m in
                if let store { ModifierFormSheet(store: store, existing: m) }
            }
            .sheet(isPresented: $creating) {
                if let store { ModifierFormSheet(store: store, existing: nil) }
            }
            .alert(
                "Delete \(deleteCandidate?.name ?? "modifier")?",
                isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                presenting: deleteCandidate
            ) { m in
                Button("Delete", role: .destructive) { Task { try? await store?.delete(m) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Modifiers attached to past orders stay on those records.") }
            .task {
                if store == nil { store = ModifiersStore(session: session) }
                await store?.load()
            }
            .refreshable { await store?.load() }
        }
    }

    @ViewBuilder
    private func content(store: ModifiersStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let msg = store.errorMessage {
                    HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
                        .padding(DesignTokens.spacingM)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall, style: .continuous).fill(Color.red.opacity(0.08)))
                }
                if !store.hasLoaded && store.items.isEmpty {
                    // Loading: sample modifiers in the real sections, as placeholders
                    VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                        ForEach(["ADD", "REMOVE", "SPECIAL"], id: \.self) { type in
                            modSection(type: type, mods: AdminModifier.sample.filter { $0.type == type })
                        }
                    }
                    .skeleton(true)
                    .accessibilityIdentifier("modifiers-loading")
                } else if store.items.isEmpty {
                    VStack(spacing: DesignTokens.spacingM) {
                        Image(systemName: "tag").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        Text("No modifiers yet").font(.headline)
                        Text("Add-ons (extra cheese), removals (no onion), and substitutions live here.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(DesignTokens.spacing2XL)
                } else {
                    ForEach(store.groupedByType, id: \.type) { group in
                        modSection(type: group.type, mods: group.mods)
                    }
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func modSection(type: String, mods: [AdminModifier]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(typeTitle(type)).font(.system(.headline, weight: .semibold))
                Spacer()
                Text("\(mods.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL).padding(.top, DesignTokens.spacingL).padding(.bottom, DesignTokens.spacingS)

            ForEach(Array(mods.enumerated()), id: \.element.id) { idx, m in
                modRow(m)
                if idx < mods.count - 1 {
                    Divider().background(Color.primary.opacity(DesignTokens.borderOpacity)).padding(.leading, DesignTokens.spacingL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private func modRow(_ m: AdminModifier) -> some View {
        Button {
            editing = m
        } label: {
            HStack(spacing: DesignTokens.spacingM) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.name).font(.system(.body, weight: .semibold)).foregroundStyle(.primary)
                        if !m.active {
                            Text("Inactive").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    HStack(spacing: 6) {
                        if let cat = m.category { Text(cat.name).font(.caption2).foregroundStyle(.secondary) }
                        else { Text("All categories").font(.caption2).foregroundStyle(.secondary) }
                        if let desc = m.description, !desc.isEmpty {
                            Text("·").font(.caption2).foregroundStyle(.secondary)
                            Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer()
                Text(m.price > 0 ? "+\((m.price).rupees)" : (m.price == 0 ? "Free" : "−\((-m.price).rupees)"))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(m.price > 0 ? .primary : .secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL).padding(.vertical, DesignTokens.spacingM)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleteCandidate = m } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func typeTitle(_ t: String) -> String {
        switch t {
        case "ADD": "Add-ons"
        case "REMOVE": "Removals"
        case "SUBSTITUTE": "Substitutions"
        case "SPECIAL": "Special instructions"
        default: t
        }
    }
}

private struct ModifierFormSheet: View {
    let store: ModifiersStore
    let existing: AdminModifier?

    @State private var name = ""
    @State private var description = ""
    @State private var price = 0
    @State private var type = "ADD"
    @State private var categoryId: String? = nil
    @State private var sortOrder = 0
    @State private var active = true
    @State private var saving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name (e.g. Extra cheese, No onion)", text: $name)
                        .accessibilityIdentifier("modifier-form-name")
                    TextField("Description (optional)", text: $description, axis: .vertical).lineLimit(2...4)
                        .accessibilityIdentifier("modifier-form-description")
                }
                Section {
                    Picker("Type", selection: $type) {
                        Text("Add-on").tag("ADD")
                        Text("Removal").tag("REMOVE")
                        Text("Substitute").tag("SUBSTITUTE")
                        Text("Special").tag("SPECIAL")
                    }
                    HStack {
                        Text("Price")
                        Spacer()
                        Text("₹")
                        TextField("0", value: $price, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                    }
                } header: { Text("Type & price") }
                  footer: { Text("Removals are usually free (₹0). Add-ons charge a positive amount.").font(.caption) }
                Section("Category") {
                    Picker("Category", selection: $categoryId) {
                        Text("All categories").tag(String?.none)
                        ForEach(store.categories, id: \.id) { c in
                            Text(c.name).tag(String?.some(c.id))
                        }
                    }
                }
                Section {
                    Toggle("Active", isOn: $active)
                    HStack {
                        Text("Sort order"); Spacer()
                        TextField("0", value: $sortOrder, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                    }
                }
                if let errorMessage { Section { Text(errorMessage).font(.subheadline).foregroundStyle(.red) } }
            }
            .navigationTitle(existing == nil ? "New Modifier" : "Edit Modifier")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
            .onAppear {
                if let e = existing {
                    name = e.name
                    description = e.description ?? ""
                    price = e.price
                    type = e.type
                    categoryId = e.categoryId
                    sortOrder = e.sortOrder
                    active = e.active
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        let payload = ModifierPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            price: price,
            type: type,
            categoryId: categoryId,
            sortOrder: sortOrder,
            active: active
        )
        saving = true; errorMessage = nil
        Task {
            do {
                if let existing { _ = try await store.update(payload, id: existing.id) }
                else { _ = try await store.create(payload) }
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - App settings (full editable form)

struct AppSettings: Codable, Equatable {
    var restaurant: RestaurantInfo
    var business: BusinessHours
    var billing: BillingSettings
    var inventory: InventorySettings

    struct RestaurantInfo: Codable, Equatable {
        var name: String
        var address: String
        var phone: String
        var email: String
        var gstin: String
        var vatTin: String?
        var socialHandle: String
    }
    struct BusinessHours: Codable, Equatable {
        var openingTime: String
        var closingTime: String
        var orderPrefix: String
    }
    struct BillingSettings: Codable, Equatable {
        /// GST on food and soft drinks, as a fraction (0.05 = 5%)
        var taxRate: Double
        /// VAT on liquor, as a fraction (0.22 = 22%)
        var liquorTaxRate: Double?
        var taxInclusive: Bool?
        var taxLabel: String
        var currency: String
        var locale: String
        var acceptCash: Bool
        var acceptCard: Bool
        var acceptUPI: Bool
        var acceptDigitalWallet: Bool
        var printReceipt: Bool
    }
    struct InventorySettings: Codable, Equatable {
        /// A fraction (0.2 = 20% above minimum stock)
        var lowStockThreshold: Double
        var autoReorder: Bool
        var trackExpiry: Bool
    }
}

@MainActor @Observable final class AppSettingsStore {
    private let api: APIClient
    var settings: AppSettings?
    var isLoading = false
    /// The first load has finished (until then the screen is a skeleton)
    var hasLoaded = false
    var saving = false
    var errorMessage: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let data = try await api.get("/api/admin/settings")
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func save(_ s: AppSettings) async throws {
        saving = true; defer { saving = false }
        _ = try await api.putJSON("/api/admin/settings", payload: s)
        settings = s
    }
}

private extension Binding where Value == String? {
    /// Edit an optional string with a TextField; empty stays empty
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0 })
    }
}

private extension Binding {
    /// Edit an optional value, showing `fallback` until it's set
    func or<T>(_ fallback: T) -> Binding<T> where Value == T? {
        Binding<T>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}

struct AppSettingsForm: View {
    @Environment(Session.self) private var session
    @State private var store: AppSettingsStore?
    @State private var draft: AppSettings?
    @State private var saveError: String?
    @State private var saveSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                if let draft = Binding($draft) {
                    sections(draft)
                } else if store?.isLoading ?? true {
                    // Loading: the real fields with sample settings, as placeholders
                    sections(.constant(AppSettings.sample))
                        .skeleton(true)
                } else if let msg = store?.errorMessage {
                    Section { Text(msg).foregroundStyle(.red) }
                }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if store?.saving == true { ProgressView() }
                    else {
                        Button("Save") { Task { await persist() } }
                            .disabled(draft == nil)
                            .accessibilityIdentifier("settings-save")
                    }
                }
            }
            .alert("Saved", isPresented: $saveSuccess) {
                Button("OK", role: .cancel) {}
            } message: { Text("Settings updated.") }
            .task {
                if store == nil { store = AppSettingsStore(session: session) }
                await store?.load()
                draft = store?.settings
            }
        }
    }

    /// Only what reaches a bill; the server keeps the other stored settings,
    /// which nothing reads yet (as on the web)
    @ViewBuilder
    private func sections(_ draft: Binding<AppSettings>) -> some View {
        Section {
            labeledField("Name", text: draft.restaurant.name).accessibilityIdentifier("settings-restaurant-name")
            labeledField("Address", text: draft.restaurant.address)
            labeledField("Phone", text: draft.restaurant.phone).keyboardType(.phonePad)
            labeledField("GSTIN", text: draft.restaurant.gstin).textInputAutocapitalization(.characters)
            labeledField("VAT TIN", text: draft.restaurant.vatTin.orEmpty)
        } header: {
            Text("Restaurant")
        } footer: {
            Text("Printed at the top of every bill. The VAT TIN prints on bills with liquor.")
        }
        Section("Tax") {
            percentField("GST on food & soft drinks", rate: draft.billing.taxRate)
            percentField("VAT on liquor", rate: draft.billing.liquorTaxRate.or(0.22))
            Toggle("Menu prices include tax", isOn: draft.billing.taxInclusive.or(true))
        }
    }

    /// A text field that keeps its label beside it once filled in (a plain
    /// TextField in a Form only shows its label as the placeholder)
    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text("Not set"))
                .multilineTextAlignment(.trailing)
                .labelsHidden() // the Mac would print the label twice
        }
    }

    /// A rate stored as a fraction (0.05), edited as a percentage (5)
    private func percentField(_ label: String, rate: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: Binding(get: { (rate.wrappedValue * 1000).rounded() / 10 },
                                          set: { rate.wrappedValue = $0 / 100 }),
                      format: .number)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .accessibilityLabel(label)
                .frame(width: 70)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text("%").foregroundStyle(.secondary)
        }
    }

    private func persist() async {
        guard let store, let draft else { return }
        saveError = nil
        do {
            try await store.save(draft)
            saveSuccess = true
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Reservations

struct AdminTable: Codable, Identifiable, Hashable {
    let id: String
    let number: Int
    let capacity: Int
    let status: String
}

struct AdminReservation: Codable, Identifiable, Hashable {
    let id: String
    var tableId: String?
    var guestName: String
    var guestPhone: String
    var guestCount: Int
    var date: String      // ISO date
    var time: String      // HH:MM
    var duration: Int
    var status: String
    var notes: String?
    var table: AdminTable?
}

struct ReservationCreatePayload: Encodable {
    /// Optional: a booking can be taken before a table is chosen
    let tableId: String?
    let guestName: String
    let guestPhone: String
    let guestCount: Int
    let date: String
    let time: String
    let duration: Int
    let notes: String?
}

struct ReservationUpdatePayload: Encodable {
    let status: String?
    let guestName: String?
    let guestPhone: String?
    let guestCount: Int?
    let time: String?
    let notes: String?
}

@MainActor @Observable final class ReservationsStore {
    private let api: APIClient
    var items: [AdminReservation] = []
    var tables: [AdminTable] = []
    var isLoading = false
    /// The first load has finished (until then the screen is a skeleton)
    var hasLoaded = false
    var errorMessage: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            async let resData = api.get("/api/reservations/upcoming", query: [URLQueryItem(name: "days", value: "30")])
            async let tablesData = api.get("/api/admin/tables")
            items = try JSONDecoder().decode([AdminReservation].self, from: try await resData)
            tables = try JSONDecoder().decode([AdminTable].self, from: try await tablesData)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func create(_ payload: ReservationCreatePayload) async throws -> AdminReservation {
        let data = try await api.postJSON("/api/reservations", payload: payload)
        let created = try JSONDecoder().decode(AdminReservation.self, from: data)
        items.append(created)
        items.sort { $0.date < $1.date }
        return created
    }

    func update(_ payload: ReservationUpdatePayload, id: String) async throws -> AdminReservation {
        let data = try await api.putJSON("/api/reservations/\(id)", payload: payload)
        let updated = try JSONDecoder().decode(AdminReservation.self, from: data)
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx] = updated }
        return updated
    }

    func cancel(_ r: AdminReservation) async throws {
        try await api.delete("/api/reservations/\(r.id)")
        items.removeAll { $0.id == r.id }
    }
}

struct ReservationsAdminView: View {
    @Environment(Session.self) private var session
    @State private var store: ReservationsStore?
    @State private var creating = false
    @State private var editing: AdminReservation?

    var body: some View {
        NavigationStack {
            Group {
                if let store { content(store: store) }
                else { Color(.systemGroupedBackground) }
            }
            .navigationTitle("Reservations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("admin-reservations-new")
                }
            }
            .sheet(isPresented: $creating) {
                if let store { ReservationFormSheet(store: store) }
            }
            .sheet(item: $editing) { r in
                if let store { ReservationDetailSheet(store: store, reservation: r) }
            }
            .task {
                if store == nil { store = ReservationsStore(session: session) }
                await store?.load()
            }
            .refreshable { await store?.load() }
        }
    }

    @ViewBuilder
    private func content(store: ReservationsStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let msg = store.errorMessage {
                    HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
                        .padding(DesignTokens.spacingM)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
                }
                if !store.hasLoaded && store.items.isEmpty {
                    // Loading: sample bookings in the real day sections, as placeholders
                    VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                        ForEach(groupedByDay(AdminReservation.sample), id: \.day) { group in
                            daySection(day: group.day, items: group.items)
                        }
                    }
                    .skeleton(true)
                    .accessibilityIdentifier("reservations-loading")
                } else if store.items.isEmpty {
                    VStack(spacing: DesignTokens.spacingM) {
                        Image(systemName: "calendar").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        Text("No upcoming reservations").font(.headline)
                        Text("Tap + to book a table.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(DesignTokens.spacing2XL)
                } else {
                    ForEach(groupedByDay(store.items), id: \.day) { group in
                        daySection(day: group.day, items: group.items)
                    }
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func daySection(day: String, items: [AdminReservation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(day)
                .font(.system(.headline, weight: .semibold))
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.top, DesignTokens.spacingL)
                .padding(.bottom, DesignTokens.spacingS)

            ForEach(Array(items.enumerated()), id: \.element.id) { idx, r in
                reservationRow(r)
                if idx < items.count - 1 {
                    Divider().background(Color.primary.opacity(DesignTokens.borderOpacity)).padding(.leading, DesignTokens.spacingL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private func reservationRow(_ r: AdminReservation) -> some View {
        Button {
            editing = r
        } label: {
            HStack(spacing: DesignTokens.spacingM) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(r.time).font(.system(.body, weight: .semibold))
                        Text("·").foregroundStyle(.secondary)
                        Text(r.guestName).font(.body)
                        statusChip(r.status)
                    }
                    Text("\(r.guestCount) guest\(r.guestCount == 1 ? "" : "s") · \(tableLabel(r))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.spacingL).padding(.vertical, DesignTokens.spacingM)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tableLabel(_ r: AdminReservation) -> String {
        if let t = r.table { return "Table \(t.number)" }
        if let tid = r.tableId, let t = (store?.tables.first { $0.id == tid }) { return "Table \(t.number)" }
        return "No table"
    }

    private func statusChip(_ status: String) -> some View {
        let color: Color = {
            switch status.uppercased() {
            case "CONFIRMED": .green
            case "ARRIVED":   .blue
            case "COMPLETED": .gray
            case "CANCELLED", "NO_SHOW": .red
            default:          .orange
            }
        }()
        return Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    /// Group reservations by `date` (the ISO day field), display "Today / Tomorrow / Mon May 4" etc.
    private func groupedByDay(_ items: [AdminReservation]) -> [(day: String, items: [AdminReservation])] {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let groups = Dictionary(grouping: items, by: { dayLabel(for: $0.date, formatter: f) })
        return groups
            .sorted { ($0.value.first?.date ?? "") < ($1.value.first?.date ?? "") }
            .map { ($0.key, $0.value.sorted { $0.time < $1.time }) }
    }

    private func dayLabel(for iso: String, formatter: ISO8601DateFormatter) -> String {
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let df = DateFormatter(); df.dateFormat = "EEE, MMM d"
        return df.string(from: date)
    }
}

private struct ReservationFormSheet: View {
    let store: ReservationsStore
    @Environment(\.dismiss) private var dismiss
    @State private var tableId: String = ""
    @State private var guestName = ""
    @State private var guestPhone = ""
    @State private var guestCount = 2
    @State private var date = Date().addingTimeInterval(2 * 3600) // default 2h from now
    @State private var time = "19:00"
    @State private var duration = 120
    @State private var notes = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    TextField("Name", text: $guestName).accessibilityIdentifier("reservation-form-name")
                    TextField("Phone", text: $guestPhone).keyboardType(.phonePad)
                    Stepper(value: $guestCount, in: 1...20) { Text("\(guestCount) guest\(guestCount == 1 ? "" : "s")") }
                }
                Section("When") {
                    DatePicker("Date", selection: $date, in: Date()..., displayedComponents: .date)
                    HStack {
                        Text("Time"); Spacer()
                        TextField("HH:MM", text: $time).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityIdentifier("reservation-form-time")
                    }
                    Stepper(value: $duration, in: 30...480, step: 30) { Text("\(duration) min") }
                }
                Section("Table") {
                    Picker("Table", selection: $tableId) {
                        Text("Assign later").tag("")
                        ForEach(store.tables, id: \.id) { t in
                            Text("Table \(t.number) (\(t.capacity) seats)").tag(t.id)
                        }
                    }
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical).lineLimit(2...4)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("New Reservation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save", action: save).disabled(!isValid) }
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var isValid: Bool {
        !guestName.trimmingCharacters(in: .whitespaces).isEmpty
        && !guestPhone.trimmingCharacters(in: .whitespaces).isEmpty
        && guestCount > 0
    }

    private func save() {
        // Server expects date-only YYYY-MM-DD, separate `time` field. If we
        // send a full ISO timestamp the server's `new Date(date + " " + time)`
        // produces "Invalid Date" silently.
        let dateF = DateFormatter()
        dateF.dateFormat = "yyyy-MM-dd"
        dateF.timeZone = TimeZone(identifier: "Asia/Kolkata")
        let payload = ReservationCreatePayload(
            tableId: tableId.isEmpty ? nil : tableId,
            guestName: guestName.trimmingCharacters(in: .whitespaces),
            guestPhone: guestPhone.trimmingCharacters(in: .whitespaces),
            guestCount: guestCount,
            date: dateF.string(from: date),
            time: time,
            duration: duration,
            notes: notes.isEmpty ? nil : notes
        )
        saving = true; errorMessage = nil
        Task {
            do {
                _ = try await store.create(payload)
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct ReservationDetailSheet: View {
    let store: ReservationsStore
    let reservation: AdminReservation
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    LabeledContent("Name", value: reservation.guestName)
                    LabeledContent("Phone", value: reservation.guestPhone)
                    LabeledContent("Party size", value: "\(reservation.guestCount)")
                }
                Section("When") {
                    LabeledContent("Date", value: dayLabel(reservation.date))
                    LabeledContent("Time", value: reservation.time)
                    LabeledContent("Duration", value: "\(reservation.duration) min")
                }
                Section("Update status") {
                    ForEach(["CONFIRMED", "ARRIVED", "COMPLETED", "CANCELLED", "NO_SHOW"], id: \.self) { status in
                        Button {
                            Task { await setStatus(status) }
                        } label: {
                            HStack {
                                Text(status.replacingOccurrences(of: "_", with: " ").capitalized)
                                if reservation.status == status {
                                    Spacer(); Image(systemName: "checkmark").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(reservation.guestName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func dayLabel(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
        let df = DateFormatter(); df.dateStyle = .medium
        return df.string(from: date)
    }

    private func setStatus(_ status: String) async {
        let payload = ReservationUpdatePayload(status: status, guestName: nil, guestPhone: nil, guestCount: nil, time: nil, notes: nil)
        saving = true; errorMessage = nil
        do {
            _ = try await store.update(payload, id: reservation.id)
            saving = false
            dismiss()
        } catch {
            saving = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Kitchen

struct KitchenOrderItem: Codable, Identifiable, Hashable {
    let id: String
    let quantity: Int
    var status: String   // PENDING / PREPARING / READY / SERVED / CANCELLED
    let notes: String?
    let menuItem: NamedRef?
    let itemName: String?
    /// Kitchen staff who last touched this item's status. Set by the
    /// server from the JWT user when the per-item PATCH fires. Used on
    /// the kanban card to show "Anthony is preparing this".
    let preparedBy: PreparedByRef?
    /// Kitchen staff explicitly assigned to this item by an admin from
    /// the kitchen display. Distinct from `preparedBy` (history of who
    /// progressed it). Editable via PATCH /items/{id}/assign.
    var assignedTo: PreparedByRef?
    /// Extras chosen when ordering ("Extra cheese", "No onion")
    var modifiers: [OrderItemModifier]? = nil

    struct NamedRef: Codable, Hashable {
        let id: String?
        let name: String?
    }

    struct PreparedByRef: Codable, Hashable {
        let id: String?
        let name: String?
        let role: String?
    }

    /// The name saved on the line when it was ordered, else the menu's
    var displayName: String { itemName ?? menuItem?.name ?? "Custom item" }
}

// Transferable conformance lets a KitchenOrder be the payload of a SwiftUI
// `.draggable(...)` modifier on the iPad kanban. CodableRepresentation just
// JSON-encodes the order — that round-trips through the drag pasteboard
// and back into Swift on drop without needing a custom UTType.
extension UTType {
    static let kitchenOrder = UTType(exportedAs: "com.durigo.kitchen-order")
}

struct KitchenOrder: Codable, Identifiable, Hashable, Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kitchenOrder)
    }

    let id: String
    let orderNumber: String
    var status: String
    let type: String
    let createdAt: String
    let table: TableRef?
    let waiter: WaiterRef?
    let items: [KitchenOrderItem]
    /// Order note: allergies, or a delivery's customer and address
    var notes: String? = nil

    struct TableRef: Codable, Hashable {
        let number: Int?
    }

    struct WaiterRef: Codable, Hashable {
        let id: String?
        let name: String?
    }
}

@MainActor @Observable final class KitchenStore {
    private let api: APIClient
    var orders: [KitchenOrder] = []
    var isLoading = false
    /// The first load has finished (until then the screen is a skeleton)
    var hasLoaded = false
    var errorMessage: String?
    /// Available kitchen staff (KITCHEN + ADMIN, active only) for the
    /// per-item assignment picker. Loaded once on `start()`.
    var kitchenStaff: [WaiterRef] = []

    /// True while the SSE stream is connected. Surfaces a small "Live" chip
    /// in the toolbar so the user knows updates are coming in automatically.
    var liveConnected = false

    /// Active stream task — cancelled by `stop()` and on reconnect.
    private var streamTask: Task<Void, Never>?

    /// Called with each order that arrives while the screen is open (after the
    /// list has reloaded), so the view can chime and print its ticket
    var onNewOrder: ((KitchenOrder) -> Void)?

    init(session: Session) { self.api = APIClient(session: session) }

    /// A store holding sample tickets, for the board's skeleton (it never loads)
    static func placeholder(session: Session) -> KitchenStore {
        let s = KitchenStore(session: session)
        s.orders = KitchenOrder.sample
        return s
    }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let data = try await api.get("/api/kitchen/orders")
            let all = try JSONDecoder().decode([KitchenOrder].self, from: data)
            // Mirror the web's 4-column kanban (NEW → PREPARING → READY →
            // SERVED). Drop only fully closed-out orders.
            orders = all.filter { !["COMPLETED", "CANCELLED"].contains($0.status.uppercased()) }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Realtime via SSE

    /// Open an SSE stream and reload the order list whenever a relevant
    /// kitchen event arrives. Reconnects with exponential-ish backoff if the
    /// stream drops. Idempotent — calling repeatedly while already connected
    /// is a no-op.
    func start() {
        guard streamTask == nil else { return }
        // Lazy-load kitchen staff list once when the view first connects.
        Task { [weak self] in await self?.loadKitchenStaff() }
        streamTask = Task { [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 1_000_000_000  // 1s
            while !Task.isCancelled {
                do {
                    let stream = self.api.eventStream("/api/events")
                    await MainActor.run { self.liveConnected = true }
                    for try await ev in stream {
                        if Task.isCancelled { break }
                        switch ev.event {
                        case "order_created":
                            await self.load()
                            // The event's data is the new order; announce it once loaded
                            struct Created: Decodable { let id: String }
                            if let id = try? JSONDecoder().decode(Created.self, from: Data(ev.data.utf8)).id,
                               let order = await MainActor.run(body: { self.orders.first { $0.id == id } }) {
                                await MainActor.run { self.onNewOrder?(order) }
                            }
                        case "order_updated", "order_status_changed", "kitchen_update":
                            // Targeted patches would be nicer, but the full
                            // reload is cheap and keeps the local state in
                            // exact sync with the server filter rules.
                            await self.load()
                        default: break  // ignore connection / heartbeat / other types
                        }
                    }
                    backoff = 1_000_000_000  // reset after a clean stream end
                } catch is CancellationError {
                    break
                } catch {
                    // Connection dropped — note it, back off, retry.
                    await MainActor.run { self.liveConnected = false }
                    try? await Task.sleep(nanoseconds: backoff)
                    backoff = min(backoff * 2, 30_000_000_000)  // cap at 30s
                }
                await MainActor.run { self.liveConnected = false }
            }
            await MainActor.run { self.liveConnected = false }
        }
    }

    /// Cancel the SSE stream. Called from `.onDisappear` of the kitchen view
    /// so we don't keep the connection alive while the user is on another tab.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        liveConnected = false
    }

    /// Load the kitchen-staff directory (active KITCHEN + ADMIN users).
    /// Reuses the WaiterRef DTO since the shape is identical (`{id, name,
    /// role}`).
    func loadKitchenStaff() async {
        do {
            let data = try await api.get("/api/users/kitchen-staff")
            self.kitchenStaff = try JSONDecoder().decode([WaiterRef].self, from: data)
        } catch {
            // Non-fatal — picker will show only "Unassigned" until refresh.
        }
    }

    /// Assign (or un-assign with nil) a kitchen staff member to an item.
    /// Server gates this to ADMIN role; non-admin requests will 403, which
    /// our APIClient surfaces via errorMessage.
    func assignItem(orderId: String, itemId: String, to userId: String?) async {
        struct Payload: Encodable { let assignedToId: String? }
        do {
            let data = try await api.patch(
                "/api/orders/\(orderId)/items/\(itemId)/assign",
                body: try JSONEncoder().encode(Payload(assignedToId: userId))
            )
            // Decode the server's authoritative response so we get the
            // joined assignedTo object back (including name/role for the
            // chip), then patch local state.
            struct Wrapper: Decodable {
                struct Item: Decodable {
                    let assignedTo: KitchenOrderItem.PreparedByRef?
                }
                let item: Item
            }
            let resp = try JSONDecoder().decode(Wrapper.self, from: data)
            if let oi = orders.firstIndex(where: { $0.id == orderId }),
               let ii = orders[oi].items.firstIndex(where: { $0.id == itemId }) {
                var newItems = orders[oi].items
                newItems[ii].assignedTo = resp.item.assignedTo
                orders[oi] = KitchenOrder(
                    id: orders[oi].id, orderNumber: orders[oi].orderNumber,
                    status: orders[oi].status, type: orders[oi].type,
                    createdAt: orders[oi].createdAt, table: orders[oi].table,
                    waiter: orders[oi].waiter, items: newItems, notes: orders[oi].notes
                )
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Mark a single line item as READY (or any explicit status). The server
    /// auto-promotes the parent order to the slowest item's status, so when
    /// the last item flips READY the order moves to READY column on every
    /// device via SSE.
    /// Endpoint is `PATCH /api/orders/{id}/items/{itemId}/status`. Gated to
    /// ADMIN+KITCHEN role on the server.
    func setItemStatus(orderId: String, itemId: String, to status: String) async {
        let upper = status.uppercased()
        do {
            let body = try JSONEncoder().encode(["status": upper])
            _ = try await api.patch("/api/orders/\(orderId)/items/\(itemId)/status", body: body)
            // Optimistic local update: flip just that item's status. The
            // SSE event will follow and reconcile via load().
            if let oi = orders.firstIndex(where: { $0.id == orderId }),
               let ii = orders[oi].items.firstIndex(where: { $0.id == itemId }) {
                var newItems = orders[oi].items
                newItems[ii].status = upper
                orders[oi] = KitchenOrder(
                    id: orders[oi].id, orderNumber: orders[oi].orderNumber,
                    status: orders[oi].status, type: orders[oi].type,
                    createdAt: orders[oi].createdAt, table: orders[oi].table,
                    waiter: orders[oi].waiter, items: newItems, notes: orders[oi].notes
                )
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Set an order's status to an explicit value. Used by the iPad kanban
    /// drag-drop where the user can move backwards too (e.g. accidentally
    /// marked READY → drag back to PREPARING). The standard `advance()`
    /// only moves forwards.
    func setStatus(_ order: KitchenOrder, to next: String) async {
        let upper = next.uppercased()
        let valid = ["PENDING", "CONFIRMED", "PREPARING", "READY", "SERVED"]
        guard valid.contains(upper), order.status.uppercased() != upper else { return }
        do {
            let payload: [String: String] = ["status": upper]
            let body = try JSONEncoder().encode(payload)
            _ = try await api.patch("/api/orders/\(order.id)/status", body: body)
            if let idx = orders.firstIndex(where: { $0.id == order.id }) {
                orders[idx] = KitchenOrder(
                    id: order.id, orderNumber: order.orderNumber, status: upper,
                    type: order.type, createdAt: order.createdAt, table: order.table,
                    waiter: order.waiter, items: order.items, notes: order.notes
                )
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Cancel the whole order. The server refuses a paid one, and a served
    /// one unless you're an admin; its reason shows here.
    func cancel(_ order: KitchenOrder, reason: String?) async {
        do {
            var payload = ["status": "CANCELLED"]
            if let reason, !reason.isEmpty { payload["reason"] = reason }
            _ = try await api.patch("/api/orders/\(order.id)/status", body: try JSONEncoder().encode(payload))
            orders.removeAll { $0.id == order.id }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func advance(_ order: KitchenOrder) async {
        let next: String
        switch order.status.uppercased() {
        case "PENDING", "CONFIRMED":  next = "PREPARING"
        case "PREPARING":             next = "READY"
        case "READY":                 next = "SERVED"
        default: return
        }
        do {
            let payload: [String: String] = ["status": next]
            let body = try JSONEncoder().encode(payload)
            _ = try await api.patch("/api/orders/\(order.id)/status", body: body)
            if let idx = orders.firstIndex(where: { $0.id == order.id }) {
                // Keep SERVED orders in the kitchen list — they live in the
                // 4th column until the cashier marks them COMPLETED.
                orders[idx] = KitchenOrder(
                    id: order.id, orderNumber: order.orderNumber, status: next,
                    type: order.type, createdAt: order.createdAt, table: order.table,
                    waiter: order.waiter, items: order.items, notes: order.notes
                )
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var groupedByStatus: [(status: String, orders: [KitchenOrder])] {
        let order: [String: Int] = ["PENDING": 0, "PREPARING": 2, "READY": 3, "SERVED": 4]
        // Confirmed orders are "To do" too: one section, as in the iPad's
        // To do column (two sections both titled "To do" read as a bug)
        let grouped = Dictionary(grouping: orders, by: { o -> String in
            let status = o.status.uppercased()
            return status == "CONFIRMED" ? "PENDING" : status
        })
        return grouped
            .sorted { (order[$0.key] ?? 99) < (order[$1.key] ?? 99) }
            .map { ($0.key, $0.value.sorted { $0.createdAt < $1.createdAt }) }
    }
}

/// Wrapper carrying both the tapped item and its parent order so the
/// detail sheet has full context. Identifiable so SwiftUI can use it as
/// a `.sheet(item:)` binding.
struct KitchenItemContext: Identifiable {
    let item: KitchenOrderItem
    let order: KitchenOrder
    var id: String { item.id }
}

/// Full-detail popup for a single kitchen item. Opens when a kanban item
/// row is tapped — gives the kitchen the entire context (full name, qty,
/// notes, assignment, preparer, surrounding order) without truncation.
struct KitchenItemDetailSheet: View {
    let context: KitchenItemContext
    @Environment(\.dismiss) private var dismiss

    private var item: KitchenOrderItem { context.item }
    private var order: KitchenOrder { context.order }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                    headerCard
                    if let notes = item.notes, !notes.isEmpty {
                        notesCard(notes)
                    }
                    attributionCard
                    orderContextCard
                }
                .padding(DesignTokens.spacingL)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Item Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Hero block: full item name (no truncation), qty, current status.
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(item.quantity)×")
                    .font(.system(.title, weight: .bold))
                    .monospaced()
                    .foregroundStyle(.secondary)
                Text(item.displayName)
                    .font(.system(.title2, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            if let extras = item.modifiers?.summary {
                Text(extras).font(.headline)
            }
            statusPill
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private var statusPill: some View {
        let s = item.status.uppercased()
        let color: Color
        switch s {
        case "PENDING":   color = .orange
        case "PREPARING": color = .yellow
        case "READY":     color = .mint
        case "SERVED":    color = .green
        case "CANCELLED": color = .red
        default:          color = .secondary
        }
        return Text(s.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notes", systemImage: "note.text")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(notes)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium).fill(Color.blue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium).stroke(Color.blue.opacity(0.25), lineWidth: 1))
    }

    /// Assignment + history block: who's assigned, who actually progressed
    /// the item (when those differ).
    private var attributionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            attributionRow(
                label: "Assigned to",
                value: item.assignedTo?.name,
                role: item.assignedTo?.role,
                fallback: "— Unassigned",
                icon: "fork.knife"
            )
            if let prep = item.preparedBy?.name,
               item.preparedBy?.id != item.assignedTo?.id {
                attributionRow(
                    label: "Last touched by",
                    value: prep,
                    role: item.preparedBy?.role,
                    fallback: nil,
                    icon: "clock.arrow.circlepath"
                )
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private func attributionRow(label: String, value: String?, role: String?, fallback: String?, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption).foregroundStyle(.secondary)
                if let v = value, !v.isEmpty {
                    HStack(spacing: 6) {
                        Text(v).font(.system(.subheadline, weight: .semibold))
                        if let r = role {
                            Text(r)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let fallback {
                    Text(fallback)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var orderContextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Order Context", systemImage: "doc.text")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack {
                contextRow(label: "Order #", value: order.orderNumber.split(separator: "-").last.map(String.init) ?? order.orderNumber)
                Spacer()
                if let n = order.table?.number {
                    contextRow(label: "Table", value: "\(n)")
                } else {
                    contextRow(label: "Type", value: order.type)
                }
            }
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    private func contextRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.subheadline, design: .monospaced, weight: .semibold))
        }
    }
}

struct KitchenAdminView: View {
    @Environment(Session.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store: KitchenStore?
    /// Re-published every 30s so elapsed-time chips on each order card
    /// stay fresh without needing per-card state. Mirrors the web's
    /// `setInterval(setCurrentTime, 1000)` in KanbanKitchenDisplay.tsx.
    @State private var now: Date = Date()
    /// Item the user tapped on the kanban — opens a detail sheet showing
    /// the full name, notes, assignment, and surrounding order context.
    /// Carries both the item AND its parent order so the sheet has all
    /// the context without re-querying.
    @State private var inspectingItem: KitchenItemContext?
    private static let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// Per device, like the web kitchen display (one screen chimes and prints,
    /// another may not)
    @AppStorage("kitchen.chime") private var chime = true
    @AppStorage("kitchen.autoPrint") private var autoPrint = false
    @State private var printError: String?
    /// The order being cancelled, and the optional reason for its log
    @State private var cancellingOrder: KitchenOrder?
    @State private var cancelReason = ""

    var body: some View {
        NavigationStack {
            Group {
                if let store, store.hasLoaded || !store.orders.isEmpty {
                    content(store: store)
                } else {
                    // Loading: sample tickets on the real board, as placeholders
                    content(store: .placeholder(session: session))
                        .skeleton(true)
                        .accessibilityIdentifier("kitchen-loading")
                }
            }
            .navigationTitle("Kitchen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if store?.liveConnected == true {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Live").font(.caption)
                        }
                        .accessibilityIdentifier("kitchen-live-indicator")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Chime for new orders", isOn: $chime)
                        Toggle("Auto-print tickets", isOn: $autoPrint)
                        #if os(iOS)
                        Button {
                            KitchenPrinter.choosePrinter()
                        } label: {
                            Label(KitchenPrinter.savedPrinterName.map { "Printer: \($0)" } ?? "Choose printer…",
                                  systemImage: "printer")
                        }
                        #endif
                    } label: {
                        Image(systemName: autoPrint ? "printer.fill" : chime ? "bell.fill" : "bell.slash")
                    }
                    .accessibilityIdentifier("kitchen-alert-settings")
                }
            }
            .task {
                if store == nil { store = KitchenStore(session: session) }
                store?.onNewOrder = { order in
                    if chime { KitchenChime.play() }
                    if autoPrint { printTicket(order, automatic: true) }
                }
                await store?.load()
                store?.start()
            }
            .alert("Couldn't print the ticket", isPresented: Binding(
                get: { printError != nil }, set: { if !$0 { printError = nil } }
            )) {
                Button("OK") { printError = nil }
            } message: {
                Text(printError ?? "")
            }
            .alert("Cancel this whole order?", isPresented: Binding(
                get: { cancellingOrder != nil }, set: { if !$0 { cancellingOrder = nil } }
            ), presenting: cancellingOrder) { order in
                TextField("Reason (optional)", text: $cancelReason)
                Button("Cancel Order", role: .destructive) {
                    let reason = cancelReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await store?.cancel(order, reason: reason.isEmpty ? nil : reason) }
                }
                Button("Keep It", role: .cancel) { cancellingOrder = nil }
            } message: { _ in
                Text("It will be taken off the bill and the kitchen.")
            }
            .onDisappear { store?.stop() }
            .refreshable { await store?.load() }
            .onReceive(Self.tick) { now = $0 }
            .sheet(item: $inspectingItem) { ctx in
                KitchenItemDetailSheet(context: ctx)
            }
        }
    }

    /// Print an order's kitchen ticket. Automatic prints go straight to the
    /// chosen printer; a manual print shows the print dialog when no printer
    /// has been chosen.
    private func printTicket(_ order: KitchenOrder, automatic: Bool) {
        Task { @MainActor in
            do {
                try await KitchenPrinter.print(order, interactive: !automatic)
            } catch {
                printError = error.localizedDescription
            }
        }
    }

    /// Staff can cancel until food is served; after that only an admin can
    /// (the server enforces the same rule)
    private func canCancel(_ o: KitchenOrder) -> Bool {
        if session.user?.role.uppercased() == "ADMIN" { return true }
        return o.status.uppercased() != "SERVED" && !o.items.contains { $0.status.uppercased() == "SERVED" }
    }

    /// Minutes between order creation and `now`. Returns 0 if the timestamp
    /// is unparseable (server always sends ISO-8601 UTC, so parsing should
    /// only fail on malformed responses).
    private func elapsedMinutes(_ createdAt: String) -> Int {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: createdAt)
            ?? ISO8601DateFormatter().date(from: createdAt)
        guard let date else { return 0 }
        return max(0, Int(now.timeIntervalSince(date) / 60))
    }

    private var tableOnOwnLine: Bool { dynamicTypeSize >= .xxLarge }

    /// "Table 10", or "Takeaway" / "Delivery"
    private func whereLabel(_ o: KitchenOrder) -> String {
        if let n = o.table?.number { return "Table \(n)" }
        return o.type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Mirrors web's `formatDuration`: 12m, 1h 5m, 2d 4h.
    private func formatElapsed(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        if h < 24 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        let d = h / 24, rh = h % 24
        return rh > 0 ? "\(d)d \(rh)h" : "\(d)d"
    }

    /// Web thresholds (KanbanKitchenDisplay.tsx:120): >30m red, >15m yellow.
    private func elapsedColor(_ minutes: Int) -> Color {
        if minutes > 30 { return .red }
        if minutes > 15 { return .yellow }
        return .secondary
    }

    @ViewBuilder
    private func content(store: KitchenStore) -> some View {
        if sizeClass == .regular {
            // iPad: side-by-side kanban with drag-and-drop between columns.
            kanbanContent(store: store)
        } else {
            // iPhone: stacked vertical sections (no kanban — columns wouldn't
            // fit in 393pt of width).
            verticalContent(store: store)
        }
    }

    @ViewBuilder
    private func verticalContent(store: KitchenStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let msg = store.errorMessage {
                    HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
                        .padding(DesignTokens.spacingM)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
                }
                if store.orders.isEmpty {
                    emptyKitchen
                } else {
                    ForEach(store.groupedByStatus, id: \.status) { group in
                        statusColumn(status: group.status, orders: group.orders, store: store)
                    }
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// 4-column kanban (To do / Preparing / Ready / Served). Cards are
    /// `.draggable(KitchenOrder)`; columns are `.dropDestination(for:
    /// KitchenOrder.self)` and call `store.setStatus(...)` on drop. A drop
    /// onto the same column is a no-op (handled by setStatus' guard).
    @ViewBuilder
    private func kanbanContent(store: KitchenStore) -> some View {
        let cols: [(status: String, title: String, color: Color)] = [
            ("PENDING",   "To do",     .orange),
            ("PREPARING", "Preparing", .yellow),
            ("READY",     "Ready",     .mint),
            ("SERVED",    "Served",    .green),
        ]
        if let msg = store.errorMessage {
            HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
                .padding(DesignTokens.spacingM)
                .padding(.horizontal, DesignTokens.spacingL)
        }
        if store.orders.isEmpty {
            emptyKitchen
        } else {
            // Four columns side by side when each gets at least 240pt
            // (landscape); otherwise (portrait iPad) the board scrolls
            // sideways rather than squeezing cards until numbers wrap
            GeometryReader { geo in
                let gaps = DesignTokens.spacingM * 3 + DesignTokens.spacingL * 2
                if (geo.size.width - gaps) / 4 >= Self.minKanbanColumn {
                    kanbanBoard(store: store, cols: cols, columnWidth: nil)
                } else {
                    ScrollView(.horizontal) {
                        kanbanBoard(store: store, cols: cols, columnWidth: Self.minKanbanColumn)
                            .frame(height: geo.size.height)
                    }
                }
            }
        }
    }

    private static let minKanbanColumn: CGFloat = 240

    private func kanbanBoard(store: KitchenStore, cols: [(status: String, title: String, color: Color)], columnWidth: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.spacingM) {
            ForEach(cols, id: \.status) { col in
                kanbanColumn(
                    store: store,
                    targetStatus: col.status,
                    title: col.title,
                    color: col.color,
                    orders: ordersForColumn(col.status, store: store)
                )
                .frame(width: columnWidth)
            }
        }
        .padding(DesignTokens.spacingL)
    }

    private func ordersForColumn(_ targetStatus: String, store: KitchenStore) -> [KitchenOrder] {
        // PENDING column also displays CONFIRMED orders so newly-confirmed
        // tickets don't visually disappear before the kitchen sees them.
        if targetStatus == "PENDING" {
            return store.orders.filter { ["PENDING", "CONFIRMED"].contains($0.status.uppercased()) }
        }
        return store.orders.filter { $0.status.uppercased() == targetStatus }
    }

    private var emptyKitchen: some View {
        VStack(spacing: DesignTokens.spacingM) {
            Image(systemName: "fork.knife.circle").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("No active orders").font(.headline)
            Text("New orders will appear here as they come in.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(DesignTokens.spacing2XL)
    }

    @ViewBuilder
    private func kanbanColumn(store: KitchenStore, targetStatus: String, title: String, color: Color, orders: [KitchenOrder]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(title).font(.system(.headline, weight: .bold))
                Spacer()
                Text("\(orders.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.18)))
                    .foregroundStyle(color)
            }
            ScrollView {
                VStack(spacing: DesignTokens.spacingS) {
                    ForEach(orders) { o in
                        orderCard(o, store: store)
                            .draggable(o)
                    }
                }
                // Spacer fills the column so the drop target covers the
                // empty area below the last card.
                Color.clear.frame(minHeight: 200)
            }
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium)
                .fill(color.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusMedium)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
        .dropDestination(for: KitchenOrder.self) { dropped, _ in
            for o in dropped {
                Task { await store.setStatus(o, to: targetStatus) }
            }
            return true
        }
    }

    private func statusColumn(status: String, orders: [KitchenOrder], store: KitchenStore) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack {
                Text(statusTitle(status)).font(.system(.title3, weight: .bold))
                Spacer()
                Text("\(orders.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            ForEach(orders) { o in
                orderCard(o, store: store)
            }
        }
    }

    private func orderCard(_ o: KitchenOrder, store: KitchenStore) -> some View {
        let elapsed = elapsedMinutes(o.createdAt)
        let color = elapsedColor(elapsed)
        // The full orderNumber `ORD-{ts}-{count}` is too long for a kanban
        // card. Staff only use the trailing counter — "order 6764" — so we
        // show just the last 4 chars with a `#` prefix, matching the
        // OrderDetailView pattern.
        // Old numbers ("ORD-2605028900502") have no short counter: last 4
        let lastPart = o.orderNumber.split(separator: "-").last.map(String.init) ?? o.orderNumber
        let shortNum = lastPart.count > 6 ? String(lastPart.suffix(4)) : lastPart
        // Tight inter-row spacing inside the kanban card so cards stack
        // densely. Header → items: 4pt; items → footer: 4pt.
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Number and time never wrap (they did in narrow columns at
                // large text sizes); the table label shrinks a little instead
                Text("#\(shortNum)").font(.system(.caption, design: .monospaced, weight: .bold))
                    .fixedSize()
                // Elapsed-time chip — colored at 15/30 min thresholds.
                Text(formatElapsed(elapsed))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.15)))
                    .foregroundStyle(color)
                Spacer(minLength: 4)
                if !tableOnOwnLine {
                    Text(whereLabel(o))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                if canCancel(o) {
                    // One button for both, so the narrow kanban header keeps its room
                    Menu {
                        Button {
                            printTicket(o, automatic: false)
                        } label: {
                            Label("Print ticket", systemImage: "printer")
                        }
                        Button(role: .destructive) {
                            cancelReason = ""
                            cancellingOrder = o
                        } label: {
                            Label("Cancel order…", systemImage: "xmark.circle")
                        }
                    } label: {
                        // 36pt: was a 14pt target on a busy kitchen screen
                        Image(systemName: "ellipsis.circle").font(.body)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Print or cancel this order")
                    .accessibilityIdentifier("kitchen-more-\(o.id)")
                } else {
                    Button {
                        printTicket(o, automatic: false)
                    } label: {
                        Image(systemName: "printer").font(.body)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Print kitchen ticket")
                }
            }
            // At large text sizes the header has no room left for the table,
            // and the kitchen must never lose it: its own line instead
            if tableOnOwnLine {
                Text(whereLabel(o)).font(.subheadline.weight(.semibold))
            }
            if let note = o.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                Label(note, systemImage: "exclamationmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Waiter line — kitchen calls this person when food is ready.
            if let waiter = o.waiter?.name, !waiter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(waiter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(o.items.filter { $0.status.uppercased() != "CANCELLED" }) { it in
                // Compact row. Tapping anywhere in the name area opens a
                // detail popup — useful when names are long and truncate.
                VStack(alignment: .leading, spacing: 2) {
                    // One line when the column is wide enough to read the
                    // name; otherwise the name gets its own line and the
                    // controls sit under it (never a row of just pills)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 6) {
                            itemQuantity(it)
                            itemName(it, order: o).frame(minWidth: 110, alignment: .leading)
                            assignMenu(for: it, order: o, store: store)
                            itemStatusControl(item: it, order: o, store: store)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                itemQuantity(it)
                                itemName(it, order: o, wraps: true)
                            }
                            HStack(spacing: 6) {
                                Spacer(minLength: 0)
                                assignMenu(for: it, order: o, store: store)
                                itemStatusControl(item: it, order: o, store: store)
                            }
                        }
                    }
                    if let extras = it.modifiers?.summary {
                        Text(extras)
                            .font(.caption.weight(.semibold))
                            .padding(.leading, 28)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Item notes are often allergies: red and never truncated
                    if let n = it.notes, !n.isEmpty {
                        Text(n.uppercased())
                            .font(.caption.weight(.semibold)).foregroundStyle(.red)
                            .padding(.leading, 28)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let chef = it.preparedBy?.name, !chef.isEmpty,
                       it.preparedBy?.id != it.assignedTo?.id {
                        Text("touched by \(chef)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 28)
                    }
                }
            }
            // iPhone: explicit Menu lets the user pick which phase to move
            // the order to (skipping ahead, going back, etc.). iPad uses
            // drag-drop on the kanban so this is hidden there.
            if sizeClass != .regular {
                Menu {
                    ForEach(allowedTransitions(from: o.status.uppercased()), id: \.self) { target in
                        Button {
                            Task { await store.setStatus(o, to: target) }
                        } label: {
                            Label("Mark \(itemStatusTitle(target))", systemImage: itemStatusIcon(target))
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                        Text("Change phase")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.top, 4)
                .accessibilityIdentifier("kitchen-advance-\(o.id)")
            }
        }
        .padding(DesignTokens.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground()
    }

    // (no toggleExpanded — replaced by the detail popup approach.)

    private func itemQuantity(_ it: KitchenOrderItem) -> some View {
        Text("\(it.quantity)×")
            .font(.caption.monospaced())
            .frame(width: 22, alignment: .leading)
            .foregroundStyle(.secondary)
    }

    /// Tapping the name opens the detail popup (full name, notes, who's on it)
    private func itemName(_ it: KitchenOrderItem, order o: KitchenOrder, wraps: Bool = false) -> some View {
        Text(it.displayName)
            .font(.subheadline)
            .lineLimit(wraps ? 3 : 1)
            .fixedSize(horizontal: false, vertical: wraps)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                inspectingItem = KitchenItemContext(item: it, order: o)
            }
    }

    /// Per-item assignment Menu. Lists the kitchen-staff directory for
    /// the admin/expediter to pick from. Tapping a name PATCHes the item
    /// with the new assignedToId; "Unassigned" clears it. Server gates to
    /// ADMIN — non-admins see the menu but get a 403 toast on tap (we
    /// could hide based on session role, but keeping it discoverable for
    /// now since the screen is normally an expediter station).
    @ViewBuilder
    private func assignMenu(for item: KitchenOrderItem, order: KitchenOrder, store: KitchenStore) -> some View {
        let assignedName = item.assignedTo?.name
        // Show only the first word of the assignee name so the pill stays
        // narrow in the kanban's tight columns ("Kitchen Staff" → "Kitchen").
        let pillLabel = assignedName?.split(separator: " ").first.map(String.init) ?? "Assign"
        Menu {
            ForEach(store.kitchenStaff) { staff in
                Button {
                    Task { await store.assignItem(orderId: order.id, itemId: item.id, to: staff.id) }
                } label: {
                    Label("\(staff.name) (\(staff.role))", systemImage: "fork.knife")
                }
            }
            if assignedName != nil {
                Divider()
                Button(role: .destructive) {
                    Task { await store.assignItem(orderId: order.id, itemId: item.id, to: nil) }
                } label: {
                    Label("Unassign", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 8, weight: .semibold))
                Text(pillLabel)
                    .font(.caption2.weight(assignedName == nil ? .regular : .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Big enough to hit in a hurry (the chip was ~16pt tall)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Capsule())
            .background(
                Capsule().stroke(
                    style: StrokeStyle(lineWidth: 1, dash: assignedName == nil ? [3] : [])
                ).foregroundStyle((assignedName == nil ? Color.secondary : Color.accentColor).opacity(0.5))
            )
            .foregroundStyle(assignedName == nil ? .secondary : Color.accentColor)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("kitchen-item-assign-\(item.id)")
    }

    /// Per-item action control — a Menu listing every valid status the
    /// item can transition to. Lets the kitchen explicitly pick "Preparing"
    /// (when starting a dish) vs "Ready" (when done) vs skip-ahead to
    /// "Served" if needed, instead of a one-shot button. The current status
    /// is the visible label with a chevron hint.
    @ViewBuilder
    private func itemStatusControl(item: KitchenOrderItem, order: KitchenOrder, store: KitchenStore) -> some View {
        let cur = item.status.uppercased()
        let color = itemStatusColor(cur)
        Menu {
            // Show only transitions that make sense from the current status.
            // The server validates these too but we hide noise on the client.
            ForEach(allowedTransitions(from: cur), id: \.self) { target in
                Button {
                    Task {
                        await store.setItemStatus(orderId: order.id, itemId: item.id, to: target)
                    }
                } label: {
                    Label(itemStatusTitle(target), systemImage: itemStatusIcon(target))
                }
            }
            if cur != "CANCELLED" {
                Divider()
                Button(role: .destructive) {
                    Task { await store.setItemStatus(orderId: order.id, itemId: item.id, to: "CANCELLED") }
                } label: {
                    Label("Cancel item", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(itemStatusTitle(cur))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            // Big enough to hit in a hurry (the chip was ~16pt tall)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Capsule())
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("kitchen-item-status-\(item.id)")
    }

    /// Status transitions allowed from a given current status. Excludes
    /// the current status itself (no-op selection).
    private func allowedTransitions(from current: String) -> [String] {
        let all = ["PENDING", "PREPARING", "READY", "SERVED"]
        return all.filter { $0 != current }
    }

    private func itemStatusTitle(_ status: String) -> String {
        switch status {
        case "PENDING":   return "Pending"
        case "PREPARING": return "Preparing"
        case "READY":     return "Ready"
        case "SERVED":    return "Served"
        case "CANCELLED": return "Cancelled"
        default:          return status.capitalized
        }
    }

    private func itemStatusIcon(_ status: String) -> String {
        switch status {
        case "PENDING":   return "clock"
        case "PREPARING": return "flame"
        case "READY":     return "checkmark.circle"
        case "SERVED":    return "tray.and.arrow.up"
        case "CANCELLED": return "xmark.circle"
        default:          return "circle"
        }
    }

    private func itemStatusColor(_ status: String) -> Color {
        switch status {
        case "PENDING":   return .orange
        case "PREPARING": return .yellow
        case "READY":     return .mint
        case "SERVED":    return .green
        case "CANCELLED": return .red
        default:          return .secondary
        }
    }

    private func nextLabel(_ status: String) -> String? {
        switch status.uppercased() {
        case "PENDING", "CONFIRMED":  return "Start preparing"
        case "PREPARING":             return "Mark ready"
        case "READY":                 return "Mark served"
        default:                      return nil
        }
    }

    private func statusTitle(_ status: String) -> String {
        switch status.uppercased() {
        case "PENDING", "CONFIRMED": "To do"
        case "PREPARING": "Preparing"
        case "READY":     "Ready"
        case "SERVED":    "Served"
        default: status
        }
    }
}

// MARK: - Inventory

struct AdminIngredient: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var unit: String
    var currentStock: Double
    var minimumStock: Double
    var maximumStock: Double?
    var costPerUnit: Int?
    var supplier: String?
}

struct IngredientPayload: Encodable {
    let name: String
    let unit: String
    let currentStock: Double
    let minimumStock: Double
    let maximumStock: Double?
    let costPerUnit: Int?
    let supplier: String?
}

@MainActor @Observable final class InventoryStore {
    private let api: APIClient
    var items: [AdminIngredient] = []
    var isLoading = false
    /// The first load has finished (until then the screen is a skeleton)
    var hasLoaded = false
    var errorMessage: String?

    init(session: Session) { self.api = APIClient(session: session) }

    func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            let data = try await api.get("/api/admin/inventory")
            items = try JSONDecoder().decode([AdminIngredient].self, from: data)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func create(_ payload: IngredientPayload) async throws -> AdminIngredient {
        let data = try await api.postJSON("/api/admin/inventory", payload: payload)
        let created = try JSONDecoder().decode(AdminIngredient.self, from: data)
        items.append(created)
        items.sort { $0.name < $1.name }
        return created
    }

    func update(_ payload: IngredientPayload, id: String) async throws -> AdminIngredient {
        let data = try await api.putJSON("/api/admin/inventory/\(id)", payload: payload)
        let updated = try JSONDecoder().decode(AdminIngredient.self, from: data)
        if let idx = items.firstIndex(where: { $0.id == id }) { items[idx] = updated }
        return updated
    }

    func delete(_ ing: AdminIngredient) async throws {
        try await api.delete("/api/admin/inventory/\(ing.id)")
        items.removeAll { $0.id == ing.id }
    }
}

struct InventoryAdminView: View {
    @Environment(Session.self) private var session
    @State private var store: InventoryStore?
    @State private var editing: AdminIngredient?
    @State private var creating = false
    @State private var deleteCandidate: AdminIngredient?

    var body: some View {
        NavigationStack {
            Group {
                if let store { content(store: store) }
                else { Color(.systemGroupedBackground) }
            }
            .navigationTitle("Inventory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("admin-inventory-new")
                }
            }
            .sheet(item: $editing) { ing in
                if let store { IngredientFormSheet(store: store, existing: ing) }
            }
            .sheet(isPresented: $creating) {
                if let store { IngredientFormSheet(store: store, existing: nil) }
            }
            .alert(
                "Delete \(deleteCandidate?.name ?? "ingredient")?",
                isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
                presenting: deleteCandidate
            ) { ing in
                Button("Delete", role: .destructive) { Task { try? await store?.delete(ing) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("Ingredients linked to recipes can't be deleted.") }
            .task {
                if store == nil { store = InventoryStore(session: session) }
                await store?.load()
            }
            .refreshable { await store?.load() }
        }
    }

    @ViewBuilder
    private func content(store: InventoryStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                if let msg = store.errorMessage {
                    HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(msg).font(.subheadline); Spacer() }
                        .padding(DesignTokens.spacingM)
                        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadiusSmall).fill(Color.red.opacity(0.08)))
                }
                if !store.hasLoaded && store.items.isEmpty {
                    // Loading: sample ingredients in the real cards, as placeholders
                    VStack(alignment: .leading, spacing: DesignTokens.spacingL) {
                        ForEach(AdminIngredient.sample) { ing in ingredientCard(ing) }
                    }
                    .skeleton(true)
                    .accessibilityIdentifier("inventory-loading")
                } else if store.items.isEmpty {
                    VStack(spacing: DesignTokens.spacingM) {
                        Image(systemName: "shippingbox").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        Text("No ingredients yet").font(.headline)
                        Text("Tap + to add an ingredient to track.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(DesignTokens.spacing2XL)
                } else {
                    ForEach(store.items) { ing in ingredientCard(ing) }
                }
            }
            .padding(DesignTokens.spacingL)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func ingredientCard(_ ing: AdminIngredient) -> some View {
        Button {
            editing = ing
        } label: {
            VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
                HStack {
                    Text(ing.name).font(.system(.body, weight: .semibold))
                    if ing.currentStock <= ing.minimumStock {
                        Text("Low").font(.caption2).foregroundStyle(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                    }
                    Spacer()
                    Text(stockText(ing)).font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(ing.currentStock <= ing.minimumStock ? .red : .primary)
                }
                stockBar(ing)
                if let supplier = ing.supplier, !supplier.isEmpty {
                    Text("Supplier: \(supplier)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(DesignTokens.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .webCardBackground()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleteCandidate = ing } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func stockBar(_ ing: AdminIngredient) -> some View {
        let max = ing.maximumStock ?? Swift.max(ing.minimumStock * 2, ing.currentStock * 1.2)
        let frac = max > 0 ? min(1.0, ing.currentStock / max) : 0
        let lowFrac = max > 0 ? min(1.0, ing.minimumStock / max) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                Rectangle().fill(Color.red.opacity(0.6))
                    .frame(width: 1, height: 6)
                    .offset(x: geo.size.width * lowFrac)
                RoundedRectangle(cornerRadius: 3).fill(ing.currentStock <= ing.minimumStock ? Color.red : Color.green)
                    .frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 6)
    }

    private func stockText(_ ing: AdminIngredient) -> String {
        let pretty = ing.currentStock.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(ing.currentStock))" : String(format: "%.1f", ing.currentStock)
        return "\(pretty) \(ing.unit)"
    }
}

private struct IngredientFormSheet: View {
    let store: InventoryStore
    let existing: AdminIngredient?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var unit = "kg"
    @State private var currentStock: Double = 0
    @State private var minimumStock: Double = 0
    @State private var maximumStock: Double = 0
    @State private var hasMax = false
    @State private var costPerUnit = 0
    @State private var hasCost = false
    @State private var supplier = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name", text: $name).accessibilityIdentifier("inventory-form-name")
                    TextField("Unit (kg, L, pieces)", text: $unit)
                }
                Section("Stock") {
                    HStack { Text("Current"); Spacer()
                        TextField("0", value: $currentStock, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 100)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                    }
                    HStack { Text("Minimum"); Spacer()
                        TextField("0", value: $minimumStock, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 100)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                    }
                    Toggle("Has max", isOn: $hasMax)
                    if hasMax {
                        HStack { Text("Maximum"); Spacer()
                            TextField("0", value: $maximumStock, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 100)
                            #if os(iOS)
                                .keyboardType(.decimalPad)
                            #endif
                        }
                    }
                }
                Section("Sourcing") {
                    Toggle("Track cost", isOn: $hasCost)
                    if hasCost {
                        HStack { Text("Cost per unit (₹)"); Spacer()
                            TextField("0", value: $costPerUnit, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 100)
                            #if os(iOS)
                                .keyboardType(.numberPad)
                            #endif
                        }
                    }
                    TextField("Supplier", text: $supplier)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(existing == nil ? "New Ingredient" : "Edit Ingredient")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || unit.isEmpty) }
                }
            }
            .onAppear {
                if let e = existing {
                    name = e.name; unit = e.unit
                    currentStock = e.currentStock; minimumStock = e.minimumStock
                    if let m = e.maximumStock { hasMax = true; maximumStock = m }
                    if let c = e.costPerUnit { hasCost = true; costPerUnit = c }
                    supplier = e.supplier ?? ""
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        let payload = IngredientPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            unit: unit.trimmingCharacters(in: .whitespaces),
            currentStock: currentStock,
            minimumStock: minimumStock,
            maximumStock: hasMax ? maximumStock : nil,
            costPerUnit: hasCost ? costPerUnit : nil,
            supplier: supplier.isEmpty ? nil : supplier
        )
        saving = true; errorMessage = nil
        Task {
            do {
                if let existing { _ = try await store.update(payload, id: existing.id) }
                else { _ = try await store.create(payload) }
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Preview

#Preview {
#if DEBUG
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: BillHistoryItem.self, configurations: config)
    PreviewData.billHistoryItems.forEach { container.mainContext.insert($0) }
#endif
    return Home()
        .environment(Session())
#if DEBUG
        .modelContainer(container)
#endif
}


// MARK: - Kitchen chime and ticket printing

#if os(iOS)
import AudioToolbox
import UIKit
#else
import AppKit
#endif
import PDFKit

/// The sound the kitchen hears when a new order arrives
enum KitchenChime {
    static func play() {
        #if os(iOS)
        AudioServicesPlayAlertSound(SystemSoundID(1005))
        #else
        NSSound(named: "Glass")?.play()
        #endif
    }
}

/// A kitchen order ticket (KOT) for an 80mm thermal printer: table or order
/// type, order number, time, waiter, then each item with its notes in capitals.
/// Same content as the web's /print/kot page.
struct KitchenTicketView: View {
    let order: KitchenOrder
    static let width: CGFloat = 226 // 80mm at 72 points per inch

    private var time: String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: order.createdAt) ?? ISO8601DateFormatter().date(from: order.createdAt) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "d MMM, h:mm a"
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return f.string(from: date)
    }

    var body: some View {
        let items = order.items.filter { $0.status.uppercased() != "CANCELLED" }
        VStack(alignment: .leading, spacing: 4) {
            Text(order.table?.number.map { "TABLE \($0)" } ?? order.type.uppercased())
                .font(.system(size: 22, weight: .heavy))
            Text("#\(order.orderNumber.split(separator: "-").last.map(String.init) ?? order.orderNumber)  ·  \(time)")
                .font(.system(size: 11, design: .monospaced))
            if let waiter = order.waiter?.name { Text("Waiter: \(waiter)").font(.system(size: 11)) }
            Rectangle().frame(height: 1)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(item.quantity) × \(item.displayName)")
                        .font(.system(size: 14, weight: .bold))
                    ForEach(item.modifiers ?? [], id: \.modifier.id) { m in
                        Text("    + \(m.modifier.name)").font(.system(size: 12, weight: .semibold))
                    }
                    if let n = item.notes, !n.isEmpty {
                        Text("  ** \(n.uppercased()) **").font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            if let note = order.notes, !note.isEmpty {
                Rectangle().frame(height: 1)
                Text(note.uppercased()).font(.system(size: 12, weight: .semibold))
                    .padding(4)
                    .border(Color.black, width: 1)
            }
            Rectangle().frame(height: 1)
            Text("\(items.reduce(0) { $0 + $1.quantity }) items").font(.system(size: 10))
        }
        .foregroundStyle(.black)
        .padding(8)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white)
    }
}

enum KitchenPrinter {
    struct NoPrinterError: LocalizedError {
        var errorDescription: String? {
            "Choose a printer for auto-print first (the printer icon in the Kitchen toolbar)."
        }
    }

    /// One-page PDF of the ticket, as tall as its content
    @MainActor
    static func pdf(for order: KitchenOrder) -> Data {
        let renderer = ImageRenderer(content: KitchenTicketView(order: order))
        renderer.proposedSize = ProposedViewSize(width: KitchenTicketView.width, height: nil)
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
        }
        return data as Data
    }

    #if os(iOS)
    private static let printerURLKey = "kitchen.printerURL"
    private static let printerNameKey = "kitchen.printerName"

    static var savedPrinterName: String? { UserDefaults.standard.string(forKey: printerNameKey) }

    /// Pick the printer automatic tickets go to (remembered on this device)
    @MainActor
    static func choosePrinter() {
        let saved = UserDefaults.standard.url(forKey: printerURLKey).map { UIPrinter(url: $0) }
        let picker = UIPrinterPickerController(initiallySelectedPrinter: saved)
        picker.present(animated: true) { picker, selected, _ in
            guard selected, let printer = picker.selectedPrinter else { return }
            UserDefaults.standard.set(printer.url, forKey: printerURLKey)
            UserDefaults.standard.set(printer.displayName, forKey: printerNameKey)
        }
    }

    @MainActor
    static func print(_ order: KitchenOrder, interactive: Bool) async throws {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = "KOT \(order.orderNumber)"
        controller.printInfo = info
        controller.printingItem = pdf(for: order)

        if let url = UserDefaults.standard.url(forKey: printerURLKey) {
            controller.print(to: UIPrinter(url: url), completionHandler: nil)
        } else if interactive {
            controller.present(animated: true, completionHandler: nil)
        } else {
            throw NoPrinterError()
        }
    }
    #else
    /// On the Mac, tickets go to the default printer; a manual print shows the
    /// print panel so another printer can be picked
    @MainActor
    static func print(_ order: KitchenOrder, interactive: Bool) async throws {
        guard let document = PDFDocument(data: pdf(for: order)) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        operation.jobTitle = "KOT \(order.orderNumber)"
        operation.showsPrintPanel = interactive
        operation.showsProgressPanel = interactive
        operation.run()
    }
    #endif
}
