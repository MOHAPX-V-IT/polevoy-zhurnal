import SwiftUI
import JournalCore

@MainActor final class JournalStore: ObservableObject {
    @Published private(set) var records: [FieldRecord] = []
    @Published var error: String?
    @Published var message = "Все изменения сохраняются на устройстве"
    @Published var syncing = false
    @Published var conflictID: UUID?
    @Published private(set) var loading = true
    @Published var serverAddress = "https://example.invalid"
    @Published var serverToken = ""
    private var saveTask: Task<Void, Never>?
    private let vault: JournalVault
    private var ready = false

    init() {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("PolevoyJournal", isDirectory: true)
        vault = JournalVault(file: folder.appendingPathComponent("journal.json"))
        serverAddress = UserDefaults.standard.string(forKey: "sync.address") ?? "https://example.invalid"
        Task {
            defer { loading = false }
            do { records = try await vault.load().records; ready = true }
            catch { self.error = "Журнал не прочитан: \(error.localizedDescription). Попробуйте восстановить предыдущую копию." }
        }
    }
    func record(_ id: UUID) -> FieldRecord? { records.first { $0.id == id } }
    @discardableResult func create(title: String, location: String, inspector: String) -> UUID? {
        guard !loading, ready else { error = "Сначала загрузите или восстановите журнал"; return nil }
        let record = FieldRecord(title: title, location: location, inspector: inspector)
        do { try JournalArchive(records: [record] + records).validateCapacity() } catch { self.error = error.localizedDescription; return nil }
        records.insert(record, at: 0); scheduleSave(); return record.id
    }
    func change(_ id: UUID, _ edit: (inout FieldRecord) -> Void) {
        guard !loading, ready else { error = "Сначала загрузите или восстановите журнал"; return }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var updated = records[index]; edit(&updated); updated.updatedAt = Date(); updated.revision += 1
        do { var candidate = records; candidate[index] = updated; try JournalArchive(records: candidate).validateCapacity() } catch { self.error = error.localizedDescription; return }
        records[index] = updated; scheduleSave()
    }
    func scheduleSave() {
        guard ready else { error = "Сначала восстановите читаемый журнал. Новые данные не будут записаны поверх повреждённого файла."; return }
        saveTask?.cancel(); let snapshot = JournalArchive(records: records)
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await vault.save(snapshot)
                message = "Сохранено на устройстве в \(Date().formatted(date: .omitted, time: .shortened))"
            } catch is CancellationError { } catch { self.error = "Не удалось сохранить: \(error.localizedDescription). Выгрузите резервную копию." }
        }
    }
    func flush() async {
        saveTask?.cancel(); guard ready, !loading else { return }
        do { try await vault.save(JournalArchive(records: records)) } catch { self.error = error.localizedDescription }
    }
    func restorePrevious() async {
        guard !loading, !syncing else { error = "Дождитесь завершения текущего обмена или загрузки"; return }
        saveTask?.cancel(); loading = true; defer { loading = false }
        do { records = try await vault.recoverPrevious().records; ready = true; message = "Восстановлена предыдущая копия" }
        catch { self.error = "Восстановление не удалось: \(error.localizedDescription)" }
    }
    func importArchive(_ data: Data) {
        guard !loading, !syncing else { error = "Дождитесь загрузки журнала или завершения обмена"; return }
        do {
            let incoming = try JournalArchive.decode(data)
            let merged = JournalArchive(records: records).merging(incoming)
            try merged.validateCapacity(); records = merged.records
            ready = true; scheduleSave(); message = "Резервная копия объединена с журналом"
        } catch { self.error = error.localizedDescription }
    }
    func exportArchive() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("polevoy-journal-\(UUID().uuidString.prefix(8)).json")
        try JournalArchive(records: records).encoded().write(to: url, options: .atomic)
        return url
    }
    func exportReport(_ record: FieldRecord) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-\(record.id).txt")
        try Data(record.textReport().utf8).write(to: url, options: .atomic); return url
    }
    private func client() throws -> JournalSync {
        guard let url = URL(string: serverAddress), url.host != nil, !serverToken.isEmpty else { throw JournalError.invalid("Укажите адрес сервера и токен") }
        let normalized = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let bound = UserDefaults.standard.string(forKey: "sync.boundAddress"), bound != normalized { throw JournalError.invalid("Журнал связан с другим сервером. Подтвердите смену сервера в настройках, чтобы отправить записи заново.") }
        UserDefaults.standard.set(serverAddress, forKey: "sync.address")
        // The token remains only in memory and is never written into exports or UserDefaults.
        return JournalSync(baseURL: url, token: serverToken)
    }
    func synchronize() async {
        guard !syncing, !loading, ready else { return }; syncing = true; defer { syncing = false }
        do {
            let client = try client()
            for record in records.filter(\.needsSync) {
                do {
                    let response = try await client.push(record)
                    guard let index = records.firstIndex(where: { $0.id == record.id }) else { continue }
                    // Preserve edits made while the request was in flight.
                    records[index].remoteRevision = response.revision
                    UserDefaults.standard.set(client.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "sync.boundAddress")
                } catch JournalError.conflict { conflictID = record.id; message = "Есть конфликт версий"; return }
            }
            await flush(); message = "Изменения отправлены"
        } catch { self.error = error.localizedDescription }
    }
    func resetSyncTarget() {
        guard !loading, !syncing else { return }
        UserDefaults.standard.removeObject(forKey: "sync.boundAddress")
        for index in records.indices { records[index].remoteRevision = 0 }
        scheduleSave(); message = "Следующая отправка создаст записи на выбранном сервере"
    }
    func useServerVersion(id: UUID) async {
        guard !loading, !syncing, let original = record(id) else { return }
        syncing = true; defer { syncing = false }
        do {
            var remote = try await client().pull(id: id).record
            _ = try remote.validated()
            remote.remoteRevision = remote.revision
            if let index = records.firstIndex(where: { $0.id == id }) {
                guard records[index].revision == original.revision else { throw JournalError.invalid("Запись изменилась во время загрузки. Правки сохранены; повторите разрешение конфликта.") }
                var candidate = records; candidate[index] = remote; try JournalArchive(records: candidate).validateCapacity(); records = candidate
            }
            conflictID = nil; await flush(); message = "Загружена серверная версия"
        } catch { self.error = error.localizedDescription }
    }
    func keepBothVersions(id: UUID) async {
        guard !loading, !syncing, var copy = record(id) else { return }
        copy.id = UUID(); copy.title = String(copy.title.prefix(180)) + " (локальная копия)"; copy.revision = 1; copy.remoteRevision = 0
        do { try JournalArchive(records: [copy] + records).validateCapacity() } catch { self.error = error.localizedDescription; return }
        records.insert(copy, at: 0)
        await useServerVersion(id: id); await flush()
    }
}
