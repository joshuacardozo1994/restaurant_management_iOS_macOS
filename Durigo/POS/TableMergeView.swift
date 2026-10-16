//
//  TableMergeView.swift
//  Durigo
//
//  Modal for combining tables into a TableGroup for large parties. Mirrors
//  the web's TableMergeModal — pick 2+ tables that aren't already in a
//  group, optionally name the group, designate a primary, and merge.
//
//  Existing groups are listed at the top with an unmerge button.
//

import SwiftUI

struct TableMergeView: View {
    @Bindable var store: POSStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIds: Set<String> = []
    @State private var primaryTableId: String?
    @State private var groupName: String = ""
    @State private var submitting = false
    @State private var errorMessage: String?

    /// Tables eligible for a new merge: must be free of an existing group
    /// AND not currently in maintenance. (Web allows merging any non-grouped
    /// table; we mirror that — it's fine to merge an Occupied table into a
    /// group if a party arrived bigger than the booked table.)
    private var availableTables: [POSTable] {
        let grouped = store.groupedTableIds
        return store.tables
            .filter { !grouped.contains($0.id) && $0.statusEnum != .maintenance }
            .sorted { $0.number < $1.number }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.tableGroups.isEmpty {
                    Section("Active groups") {
                        ForEach(store.tableGroups) { group in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(group.totalCapacity) seats • \(group.members.count) tables")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await unmerge(group.id) }
                                } label: {
                                    Image(systemName: "rectangle.split.3x1.slash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .accessibilityLabel("Unmerge \(group.displayName)")
                                .accessibilityIdentifier("unmerge-\(group.id)")
                            }
                        }
                    }
                }

                Section {
                    TextField("Group name (optional)", text: $groupName)
                } header: {
                    Text("New group name")
                } footer: {
                    Text("Leave blank to auto-name from member tables, e.g. \"Tables 3, 4\"")
                }

                Section {
                    if availableTables.isEmpty {
                        ContentUnavailableView("No tables to merge", systemImage: "square.split.2x2",
                                               description: Text("Every table is already in a group or in maintenance."))
                    } else {
                        ForEach(availableTables) { table in
                            tableRow(table)
                        }
                    }
                } header: {
                    HStack {
                        Text("Pick at least 2 tables")
                        Spacer()
                        if !selectedIds.isEmpty {
                            Text("\(selectedIds.count) selected • cap \(totalSelectedCapacity)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if selectedTables.count >= 2 {
                    Section {
                        Picker("Primary table", selection: $primaryTableId) {
                            ForEach(selectedTables) { Text("Table \($0.number)").tag(Optional($0.id)) }
                        }
                        .accessibilityIdentifier("merge-primary")
                    }
                }
            }
            .navigationTitle("Merge Tables")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") {
                        Task { await merge() }
                    }
                    .disabled(!canMerge || submitting)
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
        }
    }

    private func tableRow(_ table: POSTable) -> some View {
        let isSelected = selectedIds.contains(table.id)
        return Button {
            toggleSelection(table.id)
        } label: {
            LabeledContent {
                if isSelected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
            } label: {
                Text("Table \(table.number)")
                Text("\(table.capacity) seats · \(table.statusEnum.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)")
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityIdentifier("merge-row-\(table.number)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The selected tables, for the primary picker
    private var selectedTables: [POSTable] {
        availableTables.filter { selectedIds.contains($0.id) }
    }

    private var totalSelectedCapacity: Int {
        store.tables
            .filter { selectedIds.contains($0.id) }
            .reduce(0) { $0 + $1.capacity }
    }

    private var canMerge: Bool {
        selectedIds.count >= 2 && primaryTableId.map { selectedIds.contains($0) } == true
    }

    private func toggleSelection(_ tableId: String) {
        if selectedIds.contains(tableId) {
            selectedIds.remove(tableId)
            if primaryTableId == tableId {
                primaryTableId = selectedIds.first
            }
        } else {
            selectedIds.insert(tableId)
            // Auto-make first selection primary; user can change with the
            // "Make primary" button.
            if primaryTableId == nil { primaryTableId = tableId }
        }
    }

    private func merge() async {
        guard let primary = primaryTableId else { return }
        submitting = true
        defer { submitting = false }
        do {
            _ = try await store.mergeTables(
                name: groupName.isEmpty ? nil : groupName,
                tableIds: Array(selectedIds),
                primaryTableId: primary
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unmerge(_ groupId: String) async {
        do {
            try await store.unmergeGroup(groupId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
