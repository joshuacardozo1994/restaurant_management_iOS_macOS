//
//  Session.swift
//  Durigo
//
//  Source-of-truth for auth state. Stores JWT in Keychain. Provides signIn /
//  signOut. SwiftUI views inject via @Environment(Session.self).
//

import Foundation

struct CurrentUser: Codable, Equatable {
    let id: String
    let username: String
    let name: String
    let role: String
}

enum AuthError: LocalizedError {
    case badResponse
    case unauthorized(String)
    case server(code: Int, body: String?)
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from server."
        case .unauthorized(let msg): return msg
        case .server(let code, let body): return "Server returned \(code)\(body.map { ": \($0)" } ?? "")"
        case .network(let err): return "Network error: \(err.localizedDescription)"
        case .decoding(let err): return "Couldn't decode response: \(err.localizedDescription)"
        }
    }
}

@MainActor
@Observable
final class Session {
    var token: String?
    var user: CurrentUser?
    var isSigningIn: Bool = false
    var lastError: String?

    var isSignedIn: Bool { token != nil }

    init() {
        #if DEBUG
        // UI tests that start at the login screen (`--signed-out`)
        if CommandLine.arguments.contains("--signed-out") {
            for key in [KeychainHelper.Key.authToken, .authUserId, .authUsername, .authUserName, .authUserRole] {
                _ = KeychainHelper.delete(key)
            }
        }
        #endif
        // Restore from Keychain on launch.
        self.token = KeychainHelper.load(.authToken)
        if let id = KeychainHelper.load(.authUserId),
           let username = KeychainHelper.load(.authUsername),
           let name = KeychainHelper.load(.authUserName),
           let role = KeychainHelper.load(.authUserRole) {
            self.user = CurrentUser(id: id, username: username, name: name, role: role)
        }
    }

    func signIn(username: String, password: String) async throws {
        // Reentrancy guard — if a sign-in is already in flight, drop subsequent calls.
        guard !isSigningIn, !isSignedIn else { return }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }

        let baseString = Config.shared.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseString)/api/auth/login") else {
            throw AuthError.badResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])
        request.httpBody = body
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await NetworkHelper.shared.currentSession.data(for: request)
        } catch {
            lastError = error.localizedDescription
            throw AuthError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            lastError = "Bad response"
            throw AuthError.badResponse
        }

        if http.statusCode == 401 || http.statusCode == 429 {
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? "Invalid username or password"
            lastError = msg
            throw AuthError.unauthorized(msg)
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            lastError = "Server returned \(http.statusCode)"
            throw AuthError.server(code: http.statusCode, body: bodyStr)
        }

        let decoded: LoginResponse
        do {
            decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        } catch {
            lastError = "Couldn't decode login response"
            throw AuthError.decoding(error)
        }

        // Persist
        KeychainHelper.save(decoded.token, for: .authToken)
        KeychainHelper.save(decoded.user.id, for: .authUserId)
        KeychainHelper.save(decoded.user.username, for: .authUsername)
        KeychainHelper.save(decoded.user.name, for: .authUserName)
        KeychainHelper.save(decoded.user.role, for: .authUserRole)

        self.token = decoded.token
        self.user = decoded.user
    }

    func signOut() {
        KeychainHelper.delete(.authToken)
        KeychainHelper.delete(.authUserId)
        KeychainHelper.delete(.authUsername)
        KeychainHelper.delete(.authUserName)
        KeychainHelper.delete(.authUserRole)
        self.token = nil
        self.user = nil
    }

    /// Debug-only auto-signin from a launch arg (`--auto-signin=user:pass`).
    /// Lets me skip the Login screen during simulator-driven testing where
    /// UI automation isn't available. No-op in Release builds and when
    /// already signed in.
    func attemptDebugAutoSignIn() async {
        #if DEBUG
        for arg in CommandLine.arguments where arg.hasPrefix("--auto-signin=") {
            let value = String(arg.dropFirst("--auto-signin=".count))
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return }
            // Already signed in as this user: nothing to do. As someone else
            // (a test switching roles): sign them out here first.
            if isSignedIn {
                if user?.username == parts[0] { return }
                signOut()
            }
            try? await signIn(username: parts[0], password: parts[1])
            return
        }
        #endif
    }

    /// User-initiated logout: tells the server to revoke the token (so the
    /// JWT can't be reused even if leaked) before clearing local state.
    /// Network failure is non-fatal — local state is always cleared.
    func signOutRemotely() async {
        if let currentToken = self.token {
            let baseString = Config.shared.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let url = URL(string: "\(baseString)/api/auth/logout") {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("auth-token=\(currentToken)", forHTTPHeaderField: "Cookie")
                request.timeoutInterval = 10
                _ = try? await NetworkHelper.shared.currentSession.data(for: request)
            }
        }
        signOut()
    }
}

private struct LoginResponse: Decodable {
    let token: String
    let user: CurrentUser
}

private struct ErrorResponse: Decodable {
    let error: String
}
