//
//  BillUploader.swift
//  Durigo
//
//  Bidirectional bill sync between SwiftData (local cache) and the web backend.
//
//   - uploadOne / uploadMany: push local-only bills (syncedAt == nil) to the
//     server. Idempotent server-side via Order.externalId = BillHistoryItem.id.
//
//   - downloadPage(cursor:): fetch ONE page of server bills and upsert into
//     SwiftData. Use repeatedly with the previous page's nextCursor for
//     infinite-scroll pagination. UI never blocks waiting for the whole tail.
//
//   - syncAllUnsynced: convenience for "push everything pending"; called on
//     foreground.
//

import Foundation
import SwiftData

enum BillSyncError: LocalizedError {
    case notSignedIn
    case unauthorized
    case server(code: Int, body: String?)
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in."
        case .unauthorized:
            return "Session expired — please sign in again."
        case .server(let code, let body):
            return "Server returned \(code)\(body.map { ": \($0)" } ?? "")"
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .decoding(let underlying):
            return "Couldn't decode server response: \(underlying.localizedDescription)"
        }
    }
}

struct UploadSummary {
    let attempted: Int
    let succeeded: [UUID]
    let failed: [(id: UUID, error: BillSyncError)]
}

struct PullPageResult {
    let inserted: Int
    let updated: Int
    let nextCursor: String?
    var hasMore: Bool { nextCursor != nil }
}

@MainActor
@Observable
final class BillUploader {
    private let session: Session
    private let urlSession: URLSession
    private let baseURL: URL

    var isUploading: Bool = false
    var isDownloading: Bool = false
    var lastError: BillSyncError?
    var progress: (done: Int, total: Int)?

    init(session: Session,
         baseURL: URL? = nil,
         urlSession: URLSession = NetworkHelper.shared.currentSession) {
        self.session = session
        self.baseURL = baseURL
            ?? URL(string: Config.shared.serverURL)
            ?? URL(string: "http://127.0.0.1:3000")!
        self.urlSession = urlSession
    }

    // MARK: - URL builders

    private func uploadURL() -> URL {
        let trimmed = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/api/bills/upload")!
    }

    private func billsURL(cursor: String?, limit: Int) -> URL {
        let trimmed = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(trimmed)/api/bills")!
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query
        return components.url!
    }

    // MARK: - Auth

    private func authedRequest(url: URL, method: String) throws -> URLRequest {
        guard let token = session.token else {
            throw BillSyncError.notSignedIn
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("auth-token=\(token)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 60
        return request
    }

    // MARK: - Upload (push)

    /// Upload a single bill. Sets `syncedAt` on success.
    func uploadOne(_ bill: BillHistoryItem) async throws {
        try await uploadMany([bill])
    }

    /// Upload many bills in one request. Sets `syncedAt` on each that the server confirms.
    @discardableResult
    func uploadMany(_ bills: [BillHistoryItem]) async throws -> UploadSummary {
        guard !bills.isEmpty else {
            return UploadSummary(attempted: 0, succeeded: [], failed: [])
        }

        isUploading = true
        progress = (done: 0, total: bills.count)
        lastError = nil
        defer {
            isUploading = false
            progress = nil
        }

        var request = try authedRequest(url: uploadURL(), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let payload = DurigoBills(items: bills.map { BillHistoryItemCopy(billHistoryItem: $0) })
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            lastError = .decoding(error)
            throw BillSyncError.decoding(error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            lastError = .network(error)
            throw BillSyncError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            let err = BillSyncError.server(code: -1, body: nil)
            lastError = err
            throw err
        }

        if http.statusCode == 401 {
            session.signOut()
            lastError = .unauthorized
            throw BillSyncError.unauthorized
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            let err = BillSyncError.server(code: http.statusCode, body: bodyStr)
            lastError = err
            throw err
        }

        struct Result: Decodable { let externalId: String; let created: Bool }
        struct Response: Decodable {
            let uploaded: Int
            let created: Int
            let updated: Int
            let failed: Int?
            let results: [Result]
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            lastError = .decoding(error)
            throw BillSyncError.decoding(error)
        }

        let now = Date()
        let confirmed = Set(decoded.results.compactMap { UUID(uuidString: $0.externalId) })
        var succeeded: [UUID] = []
        for bill in bills where confirmed.contains(bill.id) {
            bill.syncedAt = now
            succeeded.append(bill.id)
        }

        let failed: [(id: UUID, error: BillSyncError)] = bills
            .filter { !confirmed.contains($0.id) }
            .map { ($0.id, BillSyncError.server(code: 200, body: "not in server response")) }

        progress = (done: bills.count, total: bills.count)
        return UploadSummary(attempted: bills.count, succeeded: succeeded, failed: failed)
    }

    // MARK: - Download (pull) — single page for infinite scroll

    /// Fetch ONE page of bills from the server and upsert into SwiftData.
    /// Returns the next cursor (nil if no more pages). Bills returned are
    /// authoritative: existing local copies are overwritten.
    func downloadPage(cursor: String?, into context: ModelContext, pageSize: Int = 50) async throws -> PullPageResult {
        isDownloading = true
        defer { isDownloading = false }

        let request = try authedRequest(url: billsURL(cursor: cursor, limit: pageSize), method: "GET")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            lastError = .network(error)
            throw BillSyncError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            let err = BillSyncError.server(code: -1, body: nil)
            lastError = err
            throw err
        }

        if http.statusCode == 401 {
            session.signOut()
            lastError = .unauthorized
            throw BillSyncError.unauthorized
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            let err = BillSyncError.server(code: http.statusCode, body: bodyStr)
            lastError = err
            throw err
        }

        struct PageResponse: Decodable {
            let items: [BillHistoryItemCopy]
            let nextCursor: String?
        }

        let page: PageResponse
        do {
            page = try JSONDecoder().decode(PageResponse.self, from: data)
        } catch {
            lastError = .decoding(error)
            throw BillSyncError.decoding(error)
        }

        let now = Date()
        var inserted = 0
        var updated = 0

        for copy in page.items {
            let id = copy.id
            let descriptor = FetchDescriptor<BillHistoryItem>(predicate: #Predicate { $0.id == id })
            let existing = (try? context.fetch(descriptor))?.first

            if let existing {
                existing.date = copy.date
                existing.tableNumber = copy.tableNumber
                existing.waiter = copy.waiter
                existing.waiterId = copy.waiterId
                existing.customerName = copy.customerName
                existing.customerPhone = copy.customerPhone
                existing.paymentStatus = BillHistoryItemStatus(rawValue: copy.paymentStatus.rawValue) ?? .pending
                existing.items = copy.items
                existing.syncedAt = now
                updated += 1
            } else {
                let bill = copy.convertToBillHistoryItem()
                bill.syncedAt = now
                context.insert(bill)
                inserted += 1
            }
        }
        try? context.save()

        return PullPageResult(inserted: inserted, updated: updated, nextCursor: page.nextCursor)
    }

    // MARK: - Sync orchestration (used on foreground)

    /// Push every bill with `syncedAt == nil` to the server. Returns total succeeded/failed.
    @discardableResult
    func syncAllUnsynced(in context: ModelContext, batchSize: Int = 200) async throws -> UploadSummary {
        let descriptor = FetchDescriptor<BillHistoryItem>(predicate: #Predicate { $0.syncedAt == nil })
        let unsynced = (try? context.fetch(descriptor)) ?? []
        guard !unsynced.isEmpty else {
            return UploadSummary(attempted: 0, succeeded: [], failed: [])
        }

        var totalSucceeded: [UUID] = []
        var totalFailed: [(id: UUID, error: BillSyncError)] = []
        for chunkStart in stride(from: 0, to: unsynced.count, by: batchSize) {
            let slice = Array(unsynced[chunkStart..<min(chunkStart + batchSize, unsynced.count)])
            let summary = try await uploadMany(slice)
            totalSucceeded.append(contentsOf: summary.succeeded)
            totalFailed.append(contentsOf: summary.failed)
            try? context.save()
        }

        return UploadSummary(attempted: unsynced.count, succeeded: totalSucceeded, failed: totalFailed)
    }
}
