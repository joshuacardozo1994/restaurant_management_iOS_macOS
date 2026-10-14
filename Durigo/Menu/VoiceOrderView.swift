//
//  VoiceOrderView.swift
//  Durigo
//
//  Created by Claude on Voice Ordering Feature
//

import SwiftUI
import Speech

struct ParsedOrderItem: Identifiable {
    let id = UUID()
    var quantity: Double
    var searchText: String
    var matchedItem: Category.Item
}

struct VoiceOrderView: View {
    @EnvironmentObject private var menuLoader: MenuLoader
    @Environment(\.dismiss) var dismiss
    
    @State private var isRecording = false
    @State private var recognizedText = ""
    @State private var addedItems: [ParsedOrderItem] = []
    @State private var currentMatches: [Category.Item] = []
    @State private var showMatchPicker = false
    @State private var pendingQuantity: Double = 1.0
    @State private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    @State private var showPermissionAlert = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Subtle recording status indicator
                if isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                        Text("Listening")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } else {
                    Color.clear.frame(height: 20)
                        .padding(.top, 4)
                }
                
                // Current recognized text with buttons
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        if recognizedText.isEmpty {
                            Text("Speak your order")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 32)
                        } else {
                            Text(recognizedText)
                                .font(.system(.title2, design: .rounded))
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
                    )
                    
                    if !recognizedText.isEmpty {
                        HStack(spacing: 12) {
                            Button(action: {
                                clearAndResetRecognition()
                            }) {
                                HStack {
                                    Image(systemName: "xmark")
                                    Text("Clear")
                                }
                                .font(.headline)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.red.opacity(0.1))
                                )
                            }
                            
                            Button(action: addCurrentItem) {
                                HStack {
                                    Image(systemName: "plus")
                                    Text("Add")
                                }
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.blue)
                                        .shadow(color: Color.blue.opacity(0.3), radius: 8, y: 4)
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal)
                
                // Added items list
                if !addedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ORDER")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("\(addedItems.count)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20)
                        
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach($addedItems) { $item in
                                    AddedItemRow(item: $item, onRemove: {
                                        addedItems.removeAll { $0.id == item.id }
                                    })
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                
                Spacer()
                
                // Minimalist control button
                Button(action: { isRecording ? stopRecording() : startRecording() }) {
                    HStack(spacing: 8) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title3)
                        Text(isRecording ? "Stop" : "Start")
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isRecording ? Color.red : Color.blue)
                            .shadow(color: (isRecording ? Color.red : Color.blue).opacity(0.3), radius: 12, y: 6)
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Voice Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopRecording()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        stopRecording()
                        addItemsToBill()
                        dismiss()
                    }
                    .disabled(addedItems.isEmpty)
                }
            }
            .sheet(isPresented: $showMatchPicker) {
                MatchPickerView(
                    matches: currentMatches,
                    quantity: pendingQuantity,
                    searchText: recognizedText,
                    onSelect: { selectedItem in
                        addItem(selectedItem, quantity: pendingQuantity)
                        showMatchPicker = false
                        clearAndResetRecognition()
                    },
                    onCancel: {
                        showMatchPicker = false
                    }
                )
            }
        }
        .alert("Microphone Permission Required", isPresented: $showPermissionAlert) {
            Button("OK", role: .cancel) {}
            Button("Settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #else
                // System Settings → Privacy & Security → Microphone
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
        } message: {
            Text("Please enable microphone access in Settings to use voice ordering.")
        }
        .onAppear {
            requestPermissions()
        }
    }
    
    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                if status != .authorized {
                    showPermissionAlert = true
                }
            }
        }
    }
    
    private func startRecording() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            return
        }
        
        do {
            #if os(iOS)
            // macOS has no audio session; the engine records from the default input
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            
            let inputNode = audioEngine.inputNode
            guard let recognitionRequest = recognitionRequest else {
                return
            }
            
            recognitionRequest.shouldReportPartialResults = true
            
            // Add custom vocabulary hints for menu items and numbers
            if let menu = menuLoader.menu {
                var contextualStrings: [String] = []
                
                // Add all menu item names
                for category in menu {
                    for item in category.items {
                        contextualStrings.append(item.name)
                        if let suffix = item.suffix {
                            contextualStrings.append(suffix)
                        }
                    }
                }
                
                // Add number words and common terms
                let numberWords1 = ["one", "two", "three", "four", "five"]
                let numberWords2 = ["six", "seven", "eight", "nine", "ten"]
                let specialTerms = ["half", "quarter", "peg", "one by two", "sanna", "sannas"]
                contextualStrings.append(contentsOf: numberWords1)
                contextualStrings.append(contentsOf: numberWords2)
                contextualStrings.append(contentsOf: specialTerms)
                
                recognitionRequest.contextualStrings = contextualStrings
            }
            
            // Require on-device recognition for better privacy and potentially better performance
            recognitionRequest.requiresOnDeviceRecognition = false // Set to true if device supports it
            
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let result = result {
                    DispatchQueue.main.async {
                        recognizedText = result.bestTranscription.formattedString
                    }
                }
                
                if error != nil {
                    stopRecording()
                }
            }
            
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            
        } catch {
            print("Error starting recording: \(error)")
        }
    }
    
    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        isRecording = false
    }
    
    private func addCurrentItem() {
        guard let categories = menuLoader.menu else { return }
        let allItems = categories.flatMap { $0.items.filter { [Category.Item.VisibilityScope.bill, Category.Item.VisibilityScope.both].contains($0.visibilityScope) } }
        
        let text = recognizedText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        
        // Parse quantity from start
        let (quantity, itemText) = parseQuantityAndText(text)
        pendingQuantity = quantity
        
        guard !itemText.isEmpty else { return }
        
        // Find matching items
        let matches = findMatchingItems(itemText, in: allItems)
        
        if matches.isEmpty {
            // No match found - could show an alert
            return
        } else if matches.count == 1 {
            // Single match - add directly
            addItem(matches[0], quantity: quantity)
            clearAndResetRecognition()
        } else {
            // Multiple matches - show picker
            currentMatches = matches
            showMatchPicker = true
        }
    }
    
    private func clearAndResetRecognition() {
        // Clear the text
        recognizedText = ""
        
        // If recording, restart the recognition to reset the buffer
        if isRecording {
            let wasRecording = isRecording
            stopRecording()
            if wasRecording {
                // Small delay to ensure clean restart
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    startRecording()
                }
            }
        }
    }
    
    private func parseQuantityAndText(_ text: String) -> (Double, String) {
        var numberWords: [String: Double] = [:]
        numberWords["one"] = 1.0
        numberWords["two"] = 2.0
        numberWords["three"] = 3.0
        numberWords["four"] = 4.0
        numberWords["five"] = 5.0
        numberWords["six"] = 6.0
        numberWords["seven"] = 7.0
        numberWords["eight"] = 8.0
        numberWords["nine"] = 9.0
        numberWords["ten"] = 10.0
        numberWords["half"] = 0.5
        numberWords["quarter"] = 0.25
        numberWords["peg"] = 1.0
        
        // Special handling for common misrecognitions
        let normalizedText = text
            .replacingOccurrences(of: "tu", with: "two")
            .replacingOccurrences(of: "to", with: "two")
            .replacingOccurrences(of: "too", with: "two")
            .replacingOccurrences(of: "for", with: "four")
            .replacingOccurrences(of: "ate", with: "eight")
            .replacingOccurrences(of: "won", with: "one")
            .replacingOccurrences(of: "big", with: "peg")
            .replacingOccurrences(of: "pig", with: "peg")
            .replacingOccurrences(of: "peck", with: "peg")
        
        // Check for "one by two" pattern (1.5)
        if normalizedText.hasPrefix("one by two ") {
            let remaining = String(normalizedText.dropFirst("one by two ".count))
            return (1.5, remaining)
        }
        
        let words = normalizedText.split(separator: " ")
        guard let firstWord = words.first else { return (1.0, text) }
        
        let firstWordStr = String(firstWord)
        
        // Check if first word is a number
        if let number = Double(firstWordStr) {
            let remaining = words.dropFirst().joined(separator: " ")
            return (number, remaining)
        }
        
        // Check if first word is a number word
        if let number = numberWords[firstWordStr] {
            let remaining = words.dropFirst().joined(separator: " ")
            return (number, remaining)
        }
        
        // No quantity found, return text as is
        return (1.0, text)
    }
    
    private func addItem(_ item: Category.Item, quantity: Double) {
        let parsedItem = ParsedOrderItem(
            quantity: quantity,
            searchText: recognizedText,
            matchedItem: item
        )
        addedItems.append(parsedItem)
    }
    
    private func findMatchingItems(_ searchText: String, in items: [Category.Item]) -> [Category.Item] {
        var matches: [(item: Category.Item, score: Int)] = []
        
        for item in items {
            let itemName = item.name.lowercased()
            let search = searchText.lowercased()
            let searchWords = search.split(separator: " ")
            
            var score = 0
            
            // Exact match
            if itemName == search {
                score = 1000
            }
            // Contains search
            else if itemName.contains(search) {
                score = 500
            }
            // Check if any search word is in the item name (word-level matching)
            else {
                var wordMatchScore = 0
                for word in searchWords {
                    if itemName.contains(word) {
                        wordMatchScore += 150
                    }
                }
                if wordMatchScore > 0 {
                    score = max(score, wordMatchScore)
                }
            }
            
            // Fuzzy match with levenshtein distance (more lenient)
            if score == 0 {
                let distance = levenshteinDistance(itemName, search)
                let maxLength = max(itemName.count, search.count)
                let similarity = 1.0 - (Double(distance) / Double(maxLength))
                if similarity > 0.4 { // Lowered threshold from 0.5 to 0.4
                    score = Int(similarity * 100)
                }
            }
            
            // Check suffix too
            if let suffix = item.suffix {
                let suffixLower = suffix.lowercased()
                if suffixLower.contains(search) {
                    score = max(score, 400)
                } else {
                    // Word-level matching in suffix
                    for word in searchWords {
                        if suffixLower.contains(word) {
                            score = max(score, 200)
                        }
                    }
                }
            }
            
            if score > 0 {
                matches.append((item, score))
            }
        }
        
        // Sort by score and return top 5
        return matches.sorted { $0.score > $1.score }.prefix(5).map { $0.item }
    }
    
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let empty = [Int](repeating: 0, count: s2.count)
        var last = [Int](0...s2.count)
        
        for (i, char1) in s1.enumerated() {
            var current = [i + 1] + empty
            for (j, char2) in s2.enumerated() {
                current[j + 1] = char1 == char2 ?
                    last[j] :
                    min(last[j], last[j + 1], current[j]) + 1
            }
            last = current
        }
        return last.last!
    }
    
    private func addItemsToBill() {
        for parsedItem in addedItems {
            let item = parsedItem.matchedItem
            
            var name = item.name
            if let suffix = item.suffix {
                name += " (\(suffix))"
            }
            
            menuLoader.billItems.append(MenuItem(
                id: item.id,
                name: name,
                prefix: item.prefix,
                suffix: item.suffix,
                quantity: parsedItem.quantity,
                price: item.price,
                tags: item.tags
            ))
        }
    }
}

// Added item row with edit capability
struct AddedItemRow: View {
    @Binding var item: ParsedOrderItem
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Quantity controls - minimal buttons
            HStack(spacing: 4) {
                Button(action: {
                    if item.quantity > 0.5 {
                        item.quantity -= 0.5
                    }
                }) {
                    Image(systemName: "minus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
                }
                
                Text("\(item.quantity, specifier: "%.1f")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(minWidth: 28)
                
                Button(action: {
                    item.quantity += 0.5
                }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
                }
            }
            
            // Item name
            VStack(alignment: .leading, spacing: 2) {
                Text(item.matchedItem.name)
                    .font(.body)
                if let suffix = item.matchedItem.suffix {
                    Text(suffix)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Price
            Text("\((item.matchedItem.price).rupees)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // Remove button - minimal
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// Match picker view for ambiguous matches
struct MatchPickerView: View {
    let matches: [Category.Item]
    let quantity: Double
    let searchText: String
    let onSelect: (Category.Item) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("MULTIPLE MATCHES")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(matches) { item in
                            Button(action: {
                                onSelect(item)
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        if let suffix = item.suffix {
                                            Text(suffix)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    Text("\((item.price).rupees)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.secondarySystemGroupedBackground))
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Select Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }
}

#Preview {
    VoiceOrderView()
        .environmentObject(MenuLoader())
}
