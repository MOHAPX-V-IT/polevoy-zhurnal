import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor JournalVault {
    private let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> JournalArchive {
        guard FileManager.default.fileExists(atPath: file.path) else { return JournalArchive(records: []) }
        return try JournalArchive.decode(Data(contentsOf: file))
    }
    public func save(_ archive: JournalArchive) throws {
        try Task.checkCancellation()
        let data = try archive.encoded()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep one known-readable previous snapshot before replacing the current one.
        if let previous = try? Data(contentsOf: file), (try? JournalArchive.decode(previous)) != nil {
            try previous.write(to: file.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: file, options: .atomic)
    }
    public func recoverPrevious() throws -> JournalArchive {
        let data = try Data(contentsOf: file.appendingPathExtension("previous"))
        let archive = try JournalArchive.decode(data)
        try data.write(to: file, options: .atomic)
        return archive
    }
}

public struct SyncEnvelope: Codable, Sendable {
    public var revision: Int
    public var record: FieldRecord
    public init(revision: Int, record: FieldRecord) { self.revision = revision; self.record = record }
}

public struct JournalSync: Sendable {
    public var baseURL: URL
    public var token: String
    public init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }
    private func request(id: UUID, method: String) throws -> URLRequest {
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && ["127.0.0.1", "localhost"].contains(baseURL.host ?? "")) else { throw JournalError.invalid("Для синхронизации нужен HTTPS. HTTP допускается только для localhost.") }
        var request = URLRequest(url: baseURL.appendingPathComponent("records").appendingPathComponent(id.uuidString))
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    public func push(_ record: FieldRecord) async throws -> SyncEnvelope {
        _ = try record.validated()
        var request = try request(id: record.id, method: "PUT")
        request.setValue(String(record.remoteRevision), forHTTPHeaderField: "If-Match")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(record.id)-\(record.revision)", forHTTPHeaderField: "Idempotency-Key")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(record)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw JournalError.server(0) }
        if response.statusCode == 409 { throw JournalError.conflict }
        guard response.statusCode == 200 else { throw JournalError.server(response.statusCode) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SyncEnvelope.self, from: data)
        _ = try envelope.record.validated()
        guard envelope.record.id == record.id, envelope.revision == record.revision, envelope.record.revision == envelope.revision, envelope.record.remoteRevision == envelope.revision else { throw JournalError.invalid("Некорректное подтверждение сервера") }
        return envelope
    }
    public func pull(id: UUID) async throws -> SyncEnvelope {
        let (data, response) = try await URLSession.shared.data(for: request(id: id, method: "GET"))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw JournalError.server((response as? HTTPURLResponse)?.statusCode ?? 0) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SyncEnvelope.self, from: data)
        _ = try envelope.record.validated()
        guard envelope.record.id == id, envelope.revision == envelope.record.revision, envelope.record.remoteRevision == envelope.revision else { throw JournalError.invalid("Некорректная серверная запись") }
        return envelope
    }
}
