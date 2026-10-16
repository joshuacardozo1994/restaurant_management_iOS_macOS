//
//  DesignSystem.swift
//  Durigo
//
//  Web-style design tokens & reusable components — mirrors the shadcn/ui
//  aesthetic the website uses (rounded cards, subtle borders, muted secondary
//  text, primary/secondary buttons, capsule status chips).
//
//  Use these everywhere instead of ad-hoc styling so the iOS app stays
//  consistent with the web.
//

import SwiftUI

// MARK: - Spacing + radius tokens

enum DesignTokens {
    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusMedium: CGFloat = 12
    static let cornerRadiusLarge: CGFloat = 16

    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let spacing2XL: CGFloat = 32

    static let borderOpacity: Double = 0.06
    static let mutedTextOpacity: Double = 0.7
}

// MARK: - Card background (matches web's bg-card + border)

extension View {
    /// Apply the web-style card background: rounded corners + subtle border.
    func webCardBackground(cornerRadius: CGFloat = DesignTokens.cornerRadiusMedium) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(DesignTokens.borderOpacity), lineWidth: 1)
            )
    }
}

// MARK: - Section card

struct SectionCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingM) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.headline, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content()
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusMedium)
    }
}

// MARK: - Status chip (capsule with colored dot)

struct StatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Primary and secondary buttons: the system's bordered styles

struct WebPrimaryButtonStyle: PrimitiveButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

struct WebSecondaryButtonStyle: PrimitiveButtonStyle {
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

extension PrimitiveButtonStyle where Self == WebPrimaryButtonStyle {
    static var webPrimary: WebPrimaryButtonStyle { .init() }
    static func webPrimary(fullWidth: Bool) -> WebPrimaryButtonStyle { .init(fullWidth: fullWidth) }
}

extension PrimitiveButtonStyle where Self == WebSecondaryButtonStyle {
    static var webSecondary: WebSecondaryButtonStyle { .init() }
    static func webSecondary(fullWidth: Bool) -> WebSecondaryButtonStyle { .init(fullWidth: fullWidth) }
}

// MARK: - Stat metric tile

struct StatTile: View {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String?
    var trend: Trend? = nil

    enum Trend {
        case up(String)
        case down(String)
        case neutral(String)

        var color: Color {
            switch self {
            case .up: .green
            case .down: .red
            case .neutral: .secondary
            }
        }
        var label: String {
            switch self {
            case .up(let s): s
            case .down(let s): s
            case .neutral(let s): s
            }
        }
        var icon: String {
            switch self {
            case .up: "arrow.up.right"
            case .down: "arrow.down.right"
            case .neutral: "arrow.right"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingS) {
            HStack {
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
            HStack(spacing: 4) {
                if let trend {
                    Image(systemName: trend.icon)
                        .font(.caption2)
                    Text(trend.label)
                        .font(.caption)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(trend?.color ?? .secondary)
        }
        .padding(DesignTokens.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .webCardBackground(cornerRadius: DesignTokens.cornerRadiusMedium)
    }
}

// MARK: - Section header (matches web's H2 + description pattern)

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.title2, weight: .bold))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            SectionHeader("Reports", subtitle: "Analytics overview")
                .padding(.horizontal)

            HStack(spacing: 12) {
                StatTile(title: "Total Revenue", value: "₹39,01,425", subtitle: "from last week", icon: "indianrupeesign", trend: .up("12.5%"))
                StatTile(title: "Total Orders", value: "1,907", subtitle: "from last week", icon: "cart", trend: .up("8.3%"))
            }
            .padding(.horizontal)

            SectionCard(title: "Top Selling Items", subtitle: "Last 7 days") {
                ForEach(0..<3) { i in
                    HStack {
                        Text("Item \(i+1)")
                        Spacer()
                        StatusChip(label: "Cash", color: .green)
                    }
                    if i < 2 { Divider() }
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel") {}
                    .buttonStyle(.webSecondary(fullWidth: true))
                Button("Save Changes") {}
                    .buttonStyle(.webPrimary(fullWidth: true))
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
}

// MARK: - macOS compatibility
//
// The app is one SwiftUI codebase for iPhone, iPad and Mac. These shims let
// the iOS-only modifiers and system colours used across the screens compile
// on macOS, where they have no equivalent (or a close one), so call sites
// don't each need #if os(iOS).

#if os(macOS)
import AppKit

extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemGroupedBackground: NSColor { .underPageBackgroundColor }
}

/// Stand-in for iOS's keyboard types; the Mac has a hardware keyboard
enum UIKeyboardType {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad,
         namePhonePad, emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}

/// Stand-in for iOS's autocapitalisation setting
struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

/// Stand-in for iOS's navigation bar title styles; Mac windows have none
enum NavigationBarTitleDisplayModeShim {
    case automatic, inline, large
}

extension View {
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayModeShim) -> some View { self }
}
#endif


// MARK: - One navigation stack per screen

private struct InNavigationStackKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Already inside a navigation stack (a screen pushed from More, or onto
    /// another screen): don't start a second one
    var inNavigationStack: Bool {
        get { self[InNavigationStackKey.self] }
        set { self[InNavigationStackKey.self] = newValue }
    }
}

/// A screen's navigation stack: its own when it is the root of a tab or the
/// sidebar's detail, the existing one when it was pushed. Nested stacks give
/// doubled bars and broken back buttons.
struct NavigationRoot<Content: View>: View {
    @Environment(\.inNavigationStack) private var inStack
    @ViewBuilder let content: () -> Content

    var body: some View {
        if inStack {
            content()
        } else {
            NavigationStack {
                content()
            }
            .environment(\.inNavigationStack, true)
        }
    }
}

extension View {
    /// The navigation bar's subtitle (iOS 26 and macOS 26); nothing on older systems
    @ViewBuilder
    func navigationSubtitleIfAvailable(_ text: String) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.navigationSubtitle(text)
        } else {
            self
        }
    }
}
