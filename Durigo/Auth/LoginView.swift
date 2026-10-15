//
//  LoginView.swift
//  Durigo
//
//  First-launch / signed-out screen. Mirrors the web app's login design:
//   - iPhone (compact): single column, brand at top, form centered
//   - iPad (regular):   two-column split — brand panel on left, form on right
//

import SwiftUI

struct LoginView: View {
    @Environment(Session.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
    }

    // MARK: - iPhone (compact)
    private var iPhoneLayout: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            // Scrolls when the text is large or the keyboard is up, so the
            // titles wrap instead of truncating and Sign in stays reachable;
            // centred as before when everything fits
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        // Top brand
                        HStack(spacing: 8) {
                            BrandMarkSquare(size: 24)
                            Text("Durigo's")
                                .font(.system(.subheadline, weight: .semibold))
                        }
                        .padding(.top, 16)

                        Spacer(minLength: 24)

                        LoginFormCard(maxWidth: 360)
                            .padding(.horizontal, 24)

                        Spacer(minLength: 24)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    // MARK: - iPad (regular)
    private var iPadLayout: some View {
        HStack(spacing: 0) {
            // Brand panel (left)
            BrandPanel()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Form panel (right)
            ZStack(alignment: .topTrailing) {
                Color(.systemBackground).ignoresSafeArea()

                HStack(spacing: 8) {
                    BrandMarkSquare(size: 24)
                    Text("Durigo's")
                        .font(.system(.subheadline, weight: .semibold))
                }
                .padding([.top, .trailing], 32)

                GeometryReader { geo in
                    ScrollView {
                        LoginFormCard(maxWidth: 360)
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Brand mark (small icon)

private struct BrandMarkSquare: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(Color.primary.opacity(0.15))
            Image(systemName: "fork.knife")
                .font(.system(size: size * 0.55, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Brand panel (left side on iPad — mirrors web's `bg-primary` panel)

private struct BrandPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            // On the web this is `bg-primary` which is light/off-white in dark mode.
            // We use a soft contrasting background that adapts to the system theme.
            Color(.secondarySystemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.primary)
                }

                Text("Streamline Your\nRestaurant Operations")
                    .font(.system(.largeTitle, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.primary)

                Text("Manage orders, tables, kitchen workflow, and billing all in one place.")
                    .font(.title3)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                LazyVGrid(
                    // One column at accessibility text sizes, so words don't split
                    columns: dynamicTypeSize.isAccessibilitySize
                        ? [GridItem(.flexible(), alignment: .leading)]
                        : [GridItem(.flexible(), alignment: .leading),
                           GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    FeatureBullet("Point of Sale")
                    FeatureBullet("Kitchen Display")
                    FeatureBullet("Table Management")
                    FeatureBullet("Sales Reports")
                }
                .frame(maxWidth: 360)
                .padding(.top, 8)
            }
            .padding(48)
        }
    }
}

private struct FeatureBullet: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.primary.opacity(0.6))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.7))
        }
    }
}

// MARK: - Login form (the right side; same on iPhone + iPad)

private struct LoginFormCard: View {
    @Environment(Session.self) private var session
    @State private var username: String = LoginFormCard.initialUsername()
    @State private var password: String = LoginFormCard.initialPassword()
    @State private var errorMessage: String?
    @FocusState private var focused: Field?
    let maxWidth: CGFloat

    /// Debug-only: --autologin-username / --autologin-password launch args pre-fill
    /// the form. Combined with --autologin (no value) the app submits automatically.
    private static func initialUsername() -> String {
        #if DEBUG
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--autologin-username=") {
                return String(arg.dropFirst("--autologin-username=".count))
            }
        }
        #endif
        return ""
    }

    private static func initialPassword() -> String {
        #if DEBUG
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--autologin-password=") {
                return String(arg.dropFirst("--autologin-password=".count))
            }
        }
        #endif
        return ""
    }

    enum Field {
        case username, password
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Welcome back")
                    .font(.system(.largeTitle, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sign in to your account to continue")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                FormField(label: "Username") {
                    TextField("Enter your username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .accessibilityIdentifier("loginUsername")
                }

                FormField(label: "Password") {
                    SecureField("Enter your password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                        .accessibilityIdentifier("loginPassword")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("loginError")
                }
            }

            Button(action: { Task { await submit() } }) {
                HStack {
                    if session.isSigningIn {
                        ProgressView()
                            .tint(Color(.systemBackground))
                    }
                    Text(session.isSigningIn ? "Signing in…" : "Sign in")
                        .font(.system(.body, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canSubmit ? Color.primary : Color.gray.opacity(0.4))
                )
                .foregroundStyle(Color(.systemBackground))
            }
            .disabled(!canSubmit || session.isSigningIn)
            .accessibilityIdentifier("loginSubmit")
        }
        .frame(maxWidth: maxWidth)
        .onAppear {
            focused = .username
            #if DEBUG
            if CommandLine.arguments.contains("--autologin"),
               !username.isEmpty, !password.isEmpty {
                Task { await submit() }
            }
            #endif
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty
    }

    private func submit() async {
        guard canSubmit, !session.isSigningIn, !session.isSignedIn else { return }
        errorMessage = nil
        do {
            try await session.signIn(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password
            )
        } catch let err as AuthError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Form field with label above (matches web's `Label` + `Input`)

private struct FormField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(.subheadline, weight: .semibold))
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

#Preview("iPhone") {
    LoginView()
        .environment(Session())
}

#Preview("iPad", traits: .landscapeLeft) {
    LoginView()
        .environment(Session())
}
