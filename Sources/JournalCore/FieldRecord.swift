import Foundation

public enum FindingState: String, Codable, CaseIterable, Sendable {
    case pending, passed, attention, notApplicable
    public var title: String {
        switch self {
        case .pending: "Не проверено"
        case .passed: "В порядке"
        case .attention: "Нужна работа"
        case .notApplicable: "Не относится"
        }
    }
}

public struct Checkpoint: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var state: FindingState
    public var note: String
    public init(id: UUID = UUID(), title: String, state: FindingState = .pending, note: String = "") {
        self.id = id; self.title = title; self.state = state; self.note = note
    }
}

public struct FieldPhoto: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var caption: String
    public var jpegData: Data
    public init(id: UUID = UUID(), caption: String = "", jpegData: Data) {
        self.id = id; self.caption = caption; self.jpegData = jpegData
    }
}

public struct FieldRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var location: String
    public var inspector: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var remoteRevision: Int
    public var checkpoints: [Checkpoint]
    public var photos: [FieldPhoto]
    public var archived: Bool

    public init(id: UUID = UUID(), title: String, location: String = "", inspector: String = "", checkpoints: [Checkpoint] = FieldRecord.officeChecklist) {
        self.id = id; self.title = title; self.location = location; self.inspector = inspector
        notes = ""; createdAt = Date(); updatedAt = createdAt; revision = 1; remoteRevision = 0
        self.checkpoints = checkpoints; photos = []; archived = false
    }
    public static var officeChecklist: [Checkpoint] { ["Вход и проходы", "Освещение", "Оборудование", "Безопасность", "Чистота и порядок"].map { Checkpoint(title: $0) } }
    public var completedCount: Int { checkpoints.filter { $0.state != .pending }.count }
    public var attentionCount: Int { checkpoints.filter { $0.state == .attention }.count }
    public var needsSync: Bool { revision > remoteRevision }

    public func validated() throws -> FieldRecord {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else { throw JournalError.invalid("Название: от 1 до 200 символов") }
        guard location.count <= 500, inspector.count <= 200, notes.count <= 30_000 else { throw JournalError.invalid("Слишком длинное описание") }
        guard revision >= 1, remoteRevision >= 0, remoteRevision <= revision else { throw JournalError.invalid("Некорректная версия записи") }
        guard checkpoints.count <= 200, Set(checkpoints.map(\.id)).count == checkpoints.count else { throw JournalError.invalid("Чек-лист содержит повторы или больше 200 пунктов") }
        guard checkpoints.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.title.count <= 300 && $0.note.count <= 10_000 }) else { throw JournalError.invalid("Некорректный пункт чек-листа") }
        guard photos.count <= 30, Set(photos.map(\.id)).count == photos.count else { throw JournalError.invalid("До 30 фотографий с уникальными идентификаторами") }
        guard photos.allSatisfy({ $0.jpegData.count <= 5_000_000 && $0.caption.count <= 1000 }) else { throw JournalError.invalid("Фотография больше 5 МБ или слишком длинная подпись") }
        return self
    }

    public func textReport() -> String {
        var lines = [title, "Место: \(location)", "Проверил: \(inspector)", "Изменено: \(updatedAt.formatted())", "Проверено: \(completedCount)/\(checkpoints.count)", ""]
        for point in checkpoints { lines.append("[\(point.state.title)] \(point.title)"); if !point.note.isEmpty { lines.append("  \(point.note)") } }
        if !notes.isEmpty { lines += ["", "Замечания", notes] }
        lines += ["", "Фотографий: \(photos.count)"]
        return lines.joined(separator: "\n")
    }
}

public enum JournalError: Error, LocalizedError, Sendable {
    case invalid(String), unsupportedVersion, conflict, server(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .unsupportedVersion: "Неизвестная версия резервной копии"
        case .conflict: "Запись изменена на другом устройстве. Сохраните обе версии или загрузите серверную."
        case .server(let code): "Сервер вернул код \(code)"
        }
    }
}

public struct JournalArchive: Codable, Sendable {
    public var schemaVersion: Int
    public var records: [FieldRecord]
    public init(records: [FieldRecord]) { schemaVersion = 1; self.records = records }
    public func validateCapacity() throws {
        guard records.count <= 1000, Set(records.map(\.id)).count == records.count else { throw JournalError.invalid("Повторяющиеся записи или больше 1000 проверок") }
        var budget = records.count * 800
        for record in records {
            _ = try record.validated()
            budget += [record.title, record.location, record.inspector, record.notes].reduce(0) { $0 + $1.utf8.count * 6 }
            budget += record.checkpoints.reduce(0) { $0 + 200 + ($1.title.utf8.count + $1.note.utf8.count) * 6 }
            budget += record.photos.reduce(0) { $0 + 200 + $1.caption.utf8.count * 6 + $1.jpegData.count * 2 }
        }
        guard budget <= 90_000_000 else { throw JournalError.invalid("Локальный журнал слишком большой. Выгрузите часть фотографий отдельно или уменьшите их количество.") }
    }
    public func encoded() throws -> Data {
        try validateCapacity()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard data.count <= 100_000_000 else { throw JournalError.invalid("Копия больше 100 МБ") }
        return data
    }
    public static func decode(_ data: Data) throws -> JournalArchive {
        guard data.count <= 100_000_000 else { throw JournalError.invalid("Копия больше 100 МБ") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Self.self, from: data)
        guard archive.schemaVersion == 1 else { throw JournalError.unsupportedVersion }
        guard archive.records.count <= 1000, Set(archive.records.map(\.id)).count == archive.records.count else { throw JournalError.invalid("Повторяющиеся записи или больше 1000 проверок") }
        for record in archive.records { _ = try record.validated() }
        try archive.validateCapacity()
        return archive
    }
    public func merging(_ incoming: JournalArchive) -> JournalArchive {
        var byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for record in incoming.records { if let old = byID[record.id], old.updatedAt >= record.updatedAt { continue }; byID[record.id] = record }
        return JournalArchive(records: byID.values.sorted { $0.updatedAt > $1.updatedAt })
    }
}
