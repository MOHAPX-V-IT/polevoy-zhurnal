import SwiftUI
import UniformTypeIdentifiers
import JournalCore

struct JournalHome: View {
    @EnvironmentObject private var store: JournalStore
    @State private var query = ""
    @State private var showNew = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var showArchived = false
    @State private var exportURL: URL?
    @State private var confirmServerChange = false
    private var visible: [FieldRecord] {
        store.records.filter { $0.archived == showArchived && (query.isEmpty || "\($0.title) \($0.location) \($0.inspector)".localizedCaseInsensitiveContains(query)) }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ПОЛЕВОЙ ЖУРНАЛ").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        Text("Проверяйте внимательно.").font(.largeTitle.bold())
                        Text("Объекты, замечания и фотографии. Работает без сети.").foregroundStyle(.secondary)
                        HStack { Label("\(store.records.filter { !$0.archived }.count) обходов", systemImage: "checklist"); Spacer(); Text("RC 1").font(.caption.monospaced()) }.foregroundStyle(.teal)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section {
                    Toggle("Показывать архив", isOn: $showArchived)
                    if visible.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "Нет обследований" : "Ничего не найдено", systemImage: "list.clipboard", description: Text("Создайте обход или измените поиск."))
                    }
                    ForEach(visible) { record in
                        NavigationLink { InspectionPage(id: record.id) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(record.title).font(.headline); Spacer(); if record.needsSync { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).accessibilityLabel("Есть неотправленные изменения") } }
                                Text(record.location.isEmpty ? "Место не указано" : record.location).font(.subheadline).foregroundStyle(.secondary)
                                ProgressView(value: Double(record.completedCount), total: Double(max(1, record.checkpoints.count))).tint(record.attentionCount > 0 ? .orange : .teal)
                                HStack { Text("\(record.completedCount) из \(record.checkpoints.count)"); Spacer(); Text("Замечаний: \(record.attentionCount)") }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                    }
                } header: { Text(showArchived ? "Архив" : "Мои объекты") }
                Section { Text(store.message).font(.footnote).foregroundStyle(.secondary) }
            }
            .searchable(text: $query, prompt: "Объект, адрес, инспектор")
            .navigationTitle("Журнал").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Настройки и резервные копии") }
                ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("Новый обход").disabled(store.loading) }
            }
            .sheet(isPresented: $showNew) { NewInspection().environmentObject(store) }
            .sheet(isPresented: $showSettings) { settings }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; store.importArchive(try Data(contentsOf: url)) }
                catch { store.error = error.localizedDescription }
            }
            .alert("Нужно внимание", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("Понятно", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
            .confirmationDialog("Конфликт с серверной версией", isPresented: Binding(get: { store.conflictID != nil }, set: { if !$0 { store.conflictID = nil } }), titleVisibility: .visible) {
                Button("Сохранить обе версии") { [id = store.conflictID] in if let id { Task { await store.keepBothVersions(id: id) } } }
                Button("Заменить локальную серверной", role: .destructive) { [id = store.conflictID] in if let id { Task { await store.useServerVersion(id: id) } } }
                Button("Разобраться позже", role: .cancel) { store.conflictID = nil }
            } message: { Text("Локальные изменения не отправлены. Можно сохранить их отдельной копией.") }
        }.tint(.teal)
    }
    private var settings: some View {
        NavigationStack { Form {
            Section("Резервная копия") {
                Button("Подготовить JSON с фотографиями") { do { exportURL = try store.exportArchive() } catch { store.error = error.localizedDescription } }
                if let exportURL { ShareLink("Сохранить или отправить копию", item: exportURL) }
                Button("Импортировать и объединить") { showSettings = false; importing = true }.disabled(store.loading)
                Button("Восстановить предыдущую локальную копию") { Task { await store.restorePrevious() } }
                Text("Храните копии отдельно от устройства. Импорт объединяет записи по идентификатору и времени изменения.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Отправка на свой сервер") {
                TextField("HTTPS-адрес", text: $store.serverAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Токен", text: $store.serverToken)
                Button(store.syncing ? "Отправляем…" : "Отправить изменения") { showSettings = false; Task { await store.synchronize() } }.disabled(store.syncing || store.loading)
                Button("Подтвердить смену сервера") { confirmServerChange = true }.disabled(store.syncing || store.loading)
                Text("Отправляются изменённые записи этого журнала. Токен хранится только до закрытия приложения. Автоматическая загрузка новых записей с других устройств не включена.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("О версии") { Text("Полевой журнал 0.1.0-rc.1"); Text("Локальный журнал обследований. Без рекламных сервисов и обязательного аккаунта.").foregroundStyle(.secondary) }
        }.navigationTitle("Настройки").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showSettings = false } } }
        .confirmationDialog("Отправить весь журнал на другой сервер?", isPresented: $confirmServerChange, titleVisibility: .visible) { Button("Сбросить привязку к серверу") { store.resetSyncTarget() }; Button("Отмена", role: .cancel) {} } message: { Text("Локальные записи сохранятся. На старом сервере данные останутся; следующий обмен создаст их на новом.") } }
    }
}

struct NewInspection: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var location = ""
    @State private var inspector = ""
    var body: some View {
        NavigationStack { Form {
            Section("Объект") { TextField("Название обследования", text: $title); TextField("Место или адрес", text: $location); TextField("Инспектор", text: $inspector) }
            Section { Text("Начальный список: вход и проходы, освещение, оборудование, безопасность и порядок. Пункты можно добавлять и удалять.").foregroundStyle(.secondary) }
        }.navigationTitle("Новый обход").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Создать") { if store.create(title: title, location: location, inspector: inspector) != nil { dismiss() } }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        } }
    }
}
