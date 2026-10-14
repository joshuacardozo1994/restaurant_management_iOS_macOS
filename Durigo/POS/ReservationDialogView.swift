//
//  ReservationDialogView.swift
//  Durigo
//
//  Sheet for booking a future reservation against an Available table.
//  Mirrors the web's ReservationDialog shown next to "Take Order" on
//  available cards. Submits to POST /api/reservations.
//

import SwiftUI

struct ReservationDialogView: View {
    @Bindable var store: POSStore
    let tableId: String
    let tableNumber: Int

    @Environment(\.dismiss) private var dismiss
    @State private var guestName: String = ""
    @State private var guestPhone: String = ""
    @State private var guestCount: Int = 2
    @State private var date: Date = Date().addingTimeInterval(60 * 60) // default 1h from now
    @State private var duration: Int = 120
    @State private var notes: String = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var success: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    TextField("Name", text: $guestName)
                        .textContentType(.name)
                    TextField("Phone", text: $guestPhone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    Stepper(value: $guestCount, in: 1...20) {
                        HStack {
                            Text("Party size")
                            Spacer()
                            Text("\(guestCount)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }

                Section("When") {
                    DatePicker("Date & time", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Picker("Duration", selection: $duration) {
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                        Text("90 min").tag(90)
                        Text("2 hours").tag(120)
                        Text("3 hours").tag(180)
                        Text("4 hours").tag(240)
                    }
                }

                Section("Notes (optional)") {
                    TextField("Special requests", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Reserve Table \(tableNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Book") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || submitting)
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
            .alert("Reservation booked", isPresented: .init(
                get: { success != nil },
                set: { if !$0 { success = nil } }
            )) {
                Button("OK") {
                    success = nil
                    dismiss()
                }
            } message: {
                Text(success ?? "")
            }
        }
    }

    private var canSubmit: Bool {
        !guestName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !guestPhone.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        // Restaurant (IST) calendar date and wall-clock time, as the server expects
        dateFmt.timeZone = TimeZone(identifier: "Asia/Kolkata")
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone = TimeZone(identifier: "Asia/Kolkata")
        let dateStr = dateFmt.string(from: date)
        let timeStr = timeFmt.string(from: date)
        do {
            let r = try await store.createReservation(
                tableId: tableId,
                guestName: guestName,
                guestPhone: guestPhone,
                guestCount: guestCount,
                date: dateStr,
                time: timeStr,
                duration: duration,
                notes: notes.isEmpty ? nil : notes
            )
            success = "Booked for \(r.guestName) on \(r.date) at \(r.time)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
