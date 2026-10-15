//
//  APIClient.swift
//  Durigo
//
//  Thin URLSession wrapper that sends the auth-token cookie on every request.
//  All future iOS-side API calls should go through this.
//

import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(code: Int, body: String?)
    case network(Error)
    case decoding(Error)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Session expired — please sign in again."
        case .server(let code, let body):
            // Prefer the server's own message ({"error": "..."}), which is written for staff
            if let data = body?.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String {
                return message
            }
            return "Server returned \(code)\(body.map { ": \($0)" } ?? "")"
        case .network(let err): return "Network error: \(err.localizedDescription)"
        case .decoding(let err): return "Couldn't decode response: \(err.localizedDescription)"
        case .badResponse: return "Unexpected response from server."
        }
    }
}

@MainActor
final class APIClient {
    let baseURL: URL
    private let session: URLSession
    private weak var authSession: Session?

    init(session: Session,
         baseURL: URL = URL(string: Config.shared.serverURL) ?? URL(string: "http://localhost:3000")!,
         urlSession: URLSession = NetworkHelper.shared.currentSession) {
        self.authSession = session
        self.baseURL = baseURL
        self.session = urlSession
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await execute(method: "GET", path: path, query: query, body: nil)
    }

    func post(_ path: String, body: Data?, query: [URLQueryItem] = []) async throws -> Data {
        try await execute(method: "POST", path: path, query: query, body: body)
    }

    func postJSON<T: Encodable>(_ path: String, payload: T, query: [URLQueryItem] = []) async throws -> Data {
        let body = try JSONEncoder().encode(payload)
        return try await execute(method: "POST", path: path, query: query, body: body)
    }

    func putJSON<T: Encodable>(_ path: String, payload: T, query: [URLQueryItem] = []) async throws -> Data {
        let body = try JSONEncoder().encode(payload)
        return try await execute(method: "PUT", path: path, query: query, body: body)
    }

    @discardableResult
    func patch(_ path: String, body: Data? = nil, query: [URLQueryItem] = []) async throws -> Data {
        try await execute(method: "PATCH", path: path, query: query, body: body)
    }

    @discardableResult
    func delete(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await execute(method: "DELETE", path: path, query: query, body: nil)
    }

    private func execute(method: String, path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        if SkeletonPreview.isActive && method == "GET" { try await SkeletonPreview.hang() }
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw APIError.badResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60

        if let token = authSession?.token {
            // Send as Cookie (matches what proxy.ts reads).
            request.setValue("auth-token=\(token)", forHTTPHeaderField: "Cookie")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse
        }

        if http.statusCode == 401 {
            // Token expired or invalid — sign out so app shows the login screen.
            authSession?.signOut()
            throw APIError.unauthorized
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            throw APIError.server(code: http.statusCode, body: bodyStr)
        }

        return data
    }

    // MARK: - Server-Sent Events

    /// One parsed SSE event. `event` defaults to `"message"` if the stream
    /// didn't specify one (matches the EventSource spec).
    struct SSEEvent: Sendable, Equatable {
        let id: String?
        let event: String
        let data: String
    }

    /// Open an SSE stream. Yields each parsed event until the task is
    /// cancelled or the connection drops. Caller is responsible for
    /// cancelling the consuming Task to close the connection.
    ///
    /// On 401, this signs the session out and throws `.unauthorized`. On
    /// network/parse errors, throws and the caller should retry with backoff.
    func eventStream(_ path: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    if SkeletonPreview.isActive { try await SkeletonPreview.hang() }
                    let url = baseURL.appending(path: path)
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    request.timeoutInterval = .infinity
                    if let token = authSession?.token {
                        request.setValue("auth-token=\(token)", forHTTPHeaderField: "Cookie")
                    }

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.badResponse
                    }
                    if http.statusCode == 401 {
                        authSession?.signOut()
                        throw APIError.unauthorized
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw APIError.server(code: http.statusCode, body: nil)
                    }

                    // Parse SSE: blank-line-separated event blocks. Each block
                    // contains `id:`, `event:`, `data:` fields. `data:` can
                    // span multiple lines (rare but spec-compliant).
                    var currentId: String?
                    var currentEvent = "message"
                    var currentData = ""

                    // Parse raw bytes into lines manually — `bytes.lines`
                    // collapses the blank lines that delimit SSE events on
                    // some iOS versions, swallowing the event boundary.
                    var lineBuf: [UInt8] = []
                    for try await byte in bytes {
                        if Task.isCancelled { return }
                        if byte == 0x0A { // LF
                            // Drop a trailing CR for CRLF-formatted servers.
                            if lineBuf.last == 0x0D { lineBuf.removeLast() }
                            let line = String(decoding: lineBuf, as: UTF8.self)
                            lineBuf.removeAll(keepingCapacity: true)
                            if line.isEmpty {
                                if !currentData.isEmpty {
                                    let trimmed = currentData.hasSuffix("\n")
                                        ? String(currentData.dropLast())
                                        : currentData
                                    continuation.yield(SSEEvent(id: currentId, event: currentEvent, data: trimmed))
                                }
                                currentId = nil
                                currentEvent = "message"
                                currentData = ""
                                continue
                            }
                            if line.hasPrefix(":") { continue }
                            if line.hasPrefix("id:") {
                                currentId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("event:") {
                                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                if !currentData.isEmpty { currentData += "\n" }
                                currentData += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            }
                        } else {
                            lineBuf.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
