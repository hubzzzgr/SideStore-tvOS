import SwiftUI
import UniformTypeIdentifiers

struct TVContainerServerView: View {
    @ObservedObject private var model = TVContainerServerModel.shared
    @State private var picker = false

    var body: some View {
        Form {
            Section {
                Toggle("Start Local Server", isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                if model.starting { ProgressView("Starting server…") }
                if let address = model.address {
                    LabeledContent("Address", value: address).textSelection(.enabled)
                    LabeledContent("Discovery", value: model.discoveryReady ? "_sidetvstore._tcp" : (model.discoveryWarning == nil ? "Registering…" : "Unavailable"))
                    if let warning = model.discoveryWarning {
                        Text(warning).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("TVcontainer Server") }
            footer: { Text("Share only the files below with devices on the same local network. The server stops when you turn it off, leave the app, or restart it. It does not keep the app awake or run a background service.") }
            Section {
                SwiftUI.Button { picker = true } label: { Label("Add Files", systemImage: "doc.badge.plus") }
                    .disabled(model.importing)
                if model.importing { ProgressView("Adding files…") }
                if model.files.isEmpty { Text("No files shared").foregroundStyle(.secondary) }
                ForEach(model.files) { file in
                    HStack {
                        Image(systemName: "doc").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(file.name).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        if let url = model.downloadURL(for: file) {
                            SwiftUI.Button("Copy Download Link", systemImage: "link") {
                                UIPasteboard.general.setItems([["public.url": url]], options: [
                                    .localOnly: true, .expirationDate: Date().addingTimeInterval(300)
                                ])
                            }
                            ShareLink(item: url)
                        }
                    }
                }.onDelete(perform: model.remove)
            } header: { Text("Shared Files") }
            footer: { Text("Swipe left to remove a file. Adding a file makes a separate copy for sharing; removing it leaves your original file unchanged. Anyone on this local network can download these files while the server is on.") }
        }
        .navigationTitle("TVcontainer Server")
        .sheet(isPresented: $picker) { TVContainerFilePicker { urls in picker = false; model.add(urls) } }
        .alert("TVcontainer Server", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            SwiftUI.Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct TVContainerFilePicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: ([URL]) -> Void
        init(_ completion: @escaping ([URL]) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion([]) }
    }
}
