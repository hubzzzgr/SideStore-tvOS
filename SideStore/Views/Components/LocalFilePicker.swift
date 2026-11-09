import SwiftUI
import UniformTypeIdentifiers

struct ImportedLocalFile: Sendable {
    let filename: String
    let data: Data

    static func read(_ url: URL, maximumBytes: Int) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "Choose a non-empty file smaller than \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))."])
        }
        return Self(filename: url.lastPathComponent, data: data)
    }
}

/// Import a local copy before dismissing Files. Consumers process the result in
/// their sheet's onDismiss, so a password prompt cannot compete with the picker.
struct LocalFilePicker: UIViewControllerRepresentable {
    var allowsMultipleSelection = false
    var maximumBytes = 16 * 1024 * 1024
    let completion: (Result<[ImportedLocalFile], Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Files providers disagree on the UTIs of p12/pfx/pem/plist files. The
        // importer validates bytes and format after selection, rather than
        // disabling otherwise valid files based on a provider's type label.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: LocalFilePicker
        private var completed = false
        init(_ parent: LocalFilePicker) { self.parent = parent }
        private func finish(_ result: Result<[ImportedLocalFile], Error>) {
            guard !completed else { return }
            completed = true; parent.completion(result)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(Result { try urls.map { try ImportedLocalFile.read($0, maximumBytes: parent.maximumBytes) } })
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(.success([])) }
    }
}
