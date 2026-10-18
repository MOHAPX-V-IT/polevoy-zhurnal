import XCTest
@testable import JournalCore

final class JournalCoreTests: XCTestCase {
    func testArchiveRoundTripWithPhoto() throws {
        var record = FieldRecord(title: "Переговорная", location: "Третий этаж")
        record.photos = [FieldPhoto(caption: "Кабель", jpegData: Data([1, 2, 3]))]
        record.checkpoints[0].state = .attention
        let archive = try JournalArchive.decode(JournalArchive(records: [record]).encoded())
        XCTAssertEqual(archive.records[0].photos[0].jpegData, Data([1, 2, 3]))
        XCTAssertEqual(archive.records[0].attentionCount, 1)
    }
    func testInvalidRecordAndDuplicateIDsRejected() throws {
        let blank = FieldRecord(title: " ")
        XCTAssertThrowsError(try blank.validated())
        let valid = FieldRecord(title: "Проверка")
        XCTAssertThrowsError(try JournalArchive.decode(JournalArchive(records: [valid, valid]).encoded()))
    }
    func testMergeKeepsNewerAndOtherRecords() {
        var first = FieldRecord(title: "Старая")
        var newer = first; newer.title = "Обновлённая"; newer.updatedAt = first.updatedAt.addingTimeInterval(10)
        let second = FieldRecord(title: "Другая")
        first.updatedAt = first.updatedAt.addingTimeInterval(-10)
        let merged = JournalArchive(records: [first, second]).merging(JournalArchive(records: [newer]))
        XCTAssertEqual(merged.records.count, 2)
        XCTAssertEqual(merged.records.first(where: { $0.id == first.id })?.title, "Обновлённая")
    }
    func testAtomicSaveAndRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = JournalVault(file: folder.appendingPathComponent("journal.json"))
        let first = JournalArchive(records: [FieldRecord(title: "До изменения")])
        try await vault.save(first)
        try await vault.save(JournalArchive(records: [FieldRecord(title: "После изменения")]))
        let restored = try await vault.recoverPrevious()
        XCTAssertEqual(restored.records[0].title, "До изменения")
    }
    func testReportAndCompletion() {
        var record = FieldRecord(title: "Склад")
        record.checkpoints[0].state = .passed
        record.checkpoints[1].state = .attention
        XCTAssertEqual(record.completedCount, 2)
        XCTAssertTrue(record.textReport().contains("Проверено: 2/5"))
    }
    func testOversizedAggregateRejectedBeforeSaving() {
        var record = FieldRecord(title: "Фото")
        record.photos = (0..<12).map { _ in FieldPhoto(jpegData: Data(repeating: 1, count: 4_000_000)) }
        XCTAssertThrowsError(try JournalArchive(records: [record]).validateCapacity())
    }
}
