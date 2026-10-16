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
    /// The More tab is open on the iPhone. Kept here, not worked out from the
    /// selection: otherwise any redraw (a badge changing) snapped back to the
    /// last bottom tab, out of whatever screen More had opened
    @State private var onMoreTab = false


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
            get: { onMoreTab || !rootTabs.contains(navigation.selection) ? .more : .item(navigation.selection) },
            set: { newRoot in
                switch newRoot {
                case .item(let item): onMoreTab = false; navigation.selection = item
                // The user navigates within More via NavigationLinks
                case .more: onMoreTab = true
                }
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
        case .kitchen:      KitchenRailView()
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
