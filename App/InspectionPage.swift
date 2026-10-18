import SwiftUI
import PhotosUI
import JournalCore

struct InspectionPage: View {
    let id: UUID
    @EnvironmentObject private var store: JournalStore
    @State private var chosenPhoto: PhotosPickerItem?
    @State private var newCheckpoint = ""
    @State private var cameraOpen = false
    @State private var reportURL: URL?
    private var record: FieldRecord? { store.record(id) }
    private func field(_ keyPath: WritableKeyPath<FieldRecord, String>) -> Binding<String> {
        Binding(get: { record?[keyPath: keyPath] ?? "" }, set: { value in store.change(id) { $0[keyPath: keyPath] = value } })
    }
    var body: some View {
        Group {
            if let record {
                Form {
                    Section("Объект") { TextField("Название", text: field(\.title)); TextField("Место", text: field(\.location)); TextField("Инспектор", text: field(\.inspector)) }
                    Section {
                        ForEach(record.checkpoints) { point in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(point.title).font(.headline)
                                Picker("Результат: \(point.title)", selection: Binding(get: { self.record?.checkpoints.first(where: { $0.id == point.id })?.state ?? .pending }, set: { value in store.change(id) { record in if let index = record.checkpoints.firstIndex(where: { $0.id == point.id }) { record.checkpoints[index].state = value } } })) { ForEach(FindingState.allCases, id: \.self) { Text($0.title).tag($0) } }
                                TextField("Замечание к пункту", text: Binding(get: { self.record?.checkpoints.first(where: { $0.id == point.id })?.note ?? "" }, set: { value in store.change(id) { record in if let index = record.checkpoints.firstIndex(where: { $0.id == point.id }) { record.checkpoints[index].note = value } } }), axis: .vertical)
                            }.padding(.vertical, 5).swipeActions { Button("Удалить пункт", role: .destructive) { store.change(id) { $0.checkpoints.removeAll { $0.id == point.id } } } }
                        }
                        HStack { TextField("Новый пункт", text: $newCheckpoint); Button { let title = newCheckpoint.trimmingCharacters(in: .whitespacesAndNewlines); guard !title.isEmpty else { return }; store.change(id) { $0.checkpoints.append(Checkpoint(title: title)) }; newCheckpoint = "" } label: { Image(systemName: "plus.circle.fill") }.accessibilityLabel("Добавить пункт") }
                    } header: { Text("Контрольные точки: \(record.completedCount)/\(record.checkpoints.count)") }
                    Section("Общие замечания") { TextField("Что нужно исправить или уточнить?", text: field(\.notes), axis: .vertical).lineLimit(4...12) }
                    Section("Фотографии: \(record.photos.count)/30") {
                        ForEach(record.photos) { photo in
                            VStack(alignment: .leading) {
                                if let image = UIImage(data: photo.jpegData) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(photo.caption.isEmpty ? "Фотография обследования" : photo.caption) }
                                TextField("Подпись к фотографии", text: Binding(get: { self.record?.photos.first(where: { $0.id == photo.id })?.caption ?? "" }, set: { caption in store.change(id) { record in if let index = record.photos.firstIndex(where: { $0.id == photo.id }) { record.photos[index].caption = caption } } }))
                            }.swipeActions { Button("Удалить фото", role: .destructive) { store.change(id) { $0.photos.removeAll { $0.id == photo.id } } } }
                        }
                        if record.photos.count < 30 {
                            PhotosPicker(selection: $chosenPhoto, matching: .images) { Label("Выбрать фотографию", systemImage: "photo") }
                            if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { cameraOpen = true } label: { Label("Сделать снимок", systemImage: "camera") } }
                        }
                    }
                    Section("Отчёт") {
                        Button("Подготовить текстовый отчёт") { do { reportURL = try store.exportReport(record) } catch { store.error = error.localizedDescription } }
                        if let reportURL { ShareLink("Сохранить или отправить отчёт", item: reportURL) }
                        Button(record.archived ? "Вернуть из архива" : "Убрать в архив") { store.change(id) { $0.archived.toggle() } }
                        Text(store.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }.navigationTitle(record.title).navigationBarTitleDisplayMode(.inline)
            } else { ContentUnavailableView("Запись не найдена", systemImage: "doc.questionmark") }
        }
        .onChange(of: chosenPhoto) { _, item in
            Task { do { if let data = try await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) { addPhoto(image) } } catch { store.error = error.localizedDescription }; chosenPhoto = nil }
        }
        .sheet(isPresented: $cameraOpen) { CameraSheet { image in if let image { addPhoto(image) }; cameraOpen = false }.ignoresSafeArea() }
    }
    private func addPhoto(_ image: UIImage) {
        let maxSide: CGFloat = 1800
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.8) else { store.error = "Не удалось обработать фотографию"; return }
        store.change(id) { $0.photos.append(FieldPhoto(jpegData: data)) }
    }
}

struct CameraSheet: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    @MainActor final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion(info[.originalImage] as? UIImage) }
    }
}
