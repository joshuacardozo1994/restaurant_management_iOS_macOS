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
            List {
                Section {
                    if recognizedText.isEmpty {
                        Text(isRecording ? "Listening…" : "Tap Start, then say the order: \"two fish curry rice\"")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, DesignTokens.spacingS)
                    } else {
                        Text(recognizedText)
                            .font(.title2.weight(.medium))
                            .padding(.vertical, DesignTokens.spacingS)
                        HStack(spacing: DesignTokens.spacingM) {
                            Button("Clear", systemImage: "xmark", role: .destructive) { clearAndResetRecognition() }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                            Button("Add", systemImage: "plus", action: addCurrentItem)
                                .buttonStyle(.borderedProminent)
                                .tint(SN.teal)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                } header: {
                    if isRecording {
                        Label("Listening", systemImage: "waveform")
                            .foregroundStyle(SN.teal)
                    } else {
                        Text("Heard")
                    }
                }

                if !addedItems.isEmpty {
                    Section("Order · \(addedItems.count)") {
                        ForEach($addedItems) { $item in
                            AddedItemRow(item: $item)
                        }
                        .onDelete { addedItems.remove(atOffsets: $0) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Label(isRecording ? "Stop" : "Start", systemImage: isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(isRecording ? SN.red : SN.teal)
                .padding(.horizontal, DesignTokens.spacingL)
                .padding(.vertical, DesignTokens.spacingS)
                .background(.bar)
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

/// A dish heard and matched: half-portion steps, swipe to remove
struct AddedItemRow: View {
    @Binding var item: ParsedOrderItem

    var body: some View {
        Stepper(value: $item.quantity, in: 0.5...100, step: 0.5) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Fmt.qty(item.quantity))× \(item.matchedItem.name)")
                    if let suffix = item.matchedItem.suffix {
                        Text(suffix).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text((item.matchedItem.price * item.quantity).rupees)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
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
            List {
                Section {
                    ForEach(matches) { item in
                        Button { onSelect(item) } label: {
                            LabeledContent {
                                Text(item.price.rupees).monospacedDigit()
                            } label: {
                                Text(item.name)
                                if let suffix = item.suffix { Text(suffix) }
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("“\(searchText)” could be")
                }
            }
            .navigationTitle("Which one?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

#Preview {
    VoiceOrderView()
        .environmentObject(MenuLoader())
}
