//
//  LoginView.swift
//  Durigo
//
//  The signed-out screen: the restaurant's name and a grouped form, the
//  same on iPhone, iPad and Mac (a narrow column in the middle of wide
//  screens).
//

import SwiftUI

struct LoginView: View {
    @Environment(Session.self) private var session
    @State private var username: String = LoginView.initialUsername()
    @State private var password: String = LoginView.initialPassword()
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

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
        Form {
            Section {
                VStack(spacing: DesignTokens.spacingS) {
                    Image(systemName: "fork.knife")
                        .font(.largeTitle)
                        .foregroundStyle(SN.teal)
                        .accessibilityHidden(true)
                    Text("Durigo's")
                        .font(.largeTitle.weight(.bold))
                    Text("Sign in to start service")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, DesignTokens.spacingL)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }

            Section {
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                    .accessibilityIdentifier("loginUsername")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
                    .accessibilityIdentifier("loginPassword")
            } footer: {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("loginError")
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: DesignTokens.spacingS) {
                        if session.isSigningIn { ProgressView() }
                        Text(session.isSigningIn ? "Signing in…" : "Sign in")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(SN.ink)
                .disabled(!canSubmit || session.isSigningIn)
                .keyboardShortcut(.defaultAction)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("loginSubmit")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
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

#Preview("iPhone") {
    LoginView()
        .environment(Session())
}

#Preview("iPad", traits: .landscapeLeft) {
    LoginView()
        .environment(Session())
}
