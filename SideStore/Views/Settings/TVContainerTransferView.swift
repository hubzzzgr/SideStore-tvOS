#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers
import TVPairCore

struct TVContainerTransferView: View {
    var initialIPA: URL? = nil
    @StateObject private var model = TVContainerTransferModel()
    @ObservedObject private var appleTV = AppleTVManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickingIPA = false
    @State private var initialized = false
    @State private var certificateConsent = false
    @State private var forgetting: TVContainerIdentityStore.Pin?
    @State private var manualPort = ""
    @State private var pairedTVID: UUID?
    @State private var target: TVContainerDevice?
    @State private var manualError: String?

    private var selected: TVContainerDevice? {
        guard let target, target.id == model.selectedID,
              appleTV.saved.contains(where: { $0.id == target.pairingID }) else { return nil }
        return target
    }

    var body: some View {
        menu
        .navigationTitle("TVContainer").navigationBarTitleDisplayMode(.large)
        .task {
            // A full-screen Files picker can make this view appear again.
            // Do not restore another TV/port over the in-progress selection.
            guard !initialized else { return }
            initialized = true
            model.open(initialIPA: initialIPA)
            do {
                try await appleTV.load()
                pairedTVID = appleTV.selectedID
                restorePort()
            }
            catch { manualError = error.localizedDescription }
        }
        .onDisappear {
            // Presenting Files or the fingerprint sheet is not leaving this flow.
            if !pickingIPA && model.pairingPrompt == nil { model.close() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancel() } }
        .onChange(of: pairedTVID) { _, _ in
            target = nil; manualError = nil; model.resetDestination(); restorePort()
        }
        .onChange(of: manualPort) { _, _ in target = nil; model.resetDestination() }
        .sheet(isPresented: $pickingIPA) {
            TVContainerIPAPicker { url in
                // Consume the delegate result directly rather than depending on
                // a second onDismiss callback to retrieve transient picker state.
                if let url { model.stage(url) }
                pickingIPA = false
            }
        }
        .sheet(item: Binding(get: { model.pairingPrompt }, set: { if $0 == nil { model.answerPairing(false) } })) { prompt in
            pairingSheet(prompt)
        }
        .confirmationDialog("Send the current signing certificate?", isPresented: $certificateConsent, titleVisibility: .visible) {
            SwiftUI.Button("Send certificate and private key") { if let selected { model.sendCertificate(to: selected) } }
            SwiftUI.Button("Cancel", role: .cancel) {}
        } message: {
            Text("This shares your current signing identity with the selected, paired TVContainer. A protected temporary P12 is exported without a password and sent only over mutual TLS. Confirm Import on Apple TV and leave its password empty. An existing TVContainer certificate cannot be replaced.")
        }
        .confirmationDialog("Forget this TVContainer?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            SwiftUI.Button("Forget TV", role: .destructive) { if let forgetting { model.forget(forgetting) }; forgetting = nil }
        } message: { Text("This removes the phone's saved TV fingerprint. Pair again only after comparing both fingerprints. Standalone Apple TV pairing is unaffected.") }
    }

    private var menu: some View {
        List {
            introduction
            pairedConnection
            connectionSection
            sendingSection
            phoneSection
            pinsSection
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .foregroundStyle(.white).tint(.white)
    }

    private var introduction: some View {
        Section {
            Text("Open TVContainer's launcher on Apple TV and enable Settings → SideTVStore TCP Server. Keep the launcher open and both devices on the same local network.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.8))
        } header: { heading("TVCONTAINER") }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private var pairedConnection: some View {
        Section {
            if appleTV.saved.isEmpty {
                Text("Pair an Apple TV in the Apple TV tab first, then return here.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            } else {
                Picker("Apple TV", selection: $pairedTVID) {
                    Text("Choose a paired TV").tag(Optional<UUID>.none)
                    ForEach(appleTV.saved) { tv in Text(tv.name).tag(Optional(tv.id)) }
                }.disabled(model.busy)
                TextField("Current TVContainer TCP port", text: $manualPort)
                    .keyboardType(.numberPad).disabled(model.busy)
                    .accessibilityLabel("Current TVContainer port")
                SwiftUI.Button(action: connectPairedTV) {
                    Label("Connect to TVContainer", systemImage: "appletv.fill").bold()
                }.disabled(model.busy || pairedTVID == nil || manualPort.isEmpty)
            }
            if let manualError { Text(manualError).font(.caption).foregroundStyle(.orange) }
        } header: { heading("PAIRED APPLE TV") } footer: {
            Text("The address comes from your saved Apple TV pairing and is resolved again for each connection. The last port used for this TV is pre-filled; update it if TVContainer shows a different port. The connection check closes when finished; TVContainer shows connected during a transfer. Keep Local Network access enabled for LiveContainer.")
                .foregroundStyle(.white.opacity(0.7))
        }.listRowBackground(Color.white.opacity(0.15))
    }

    private func restorePort() {
        guard let id = pairedTVID else { manualPort = ""; return }
        manualPort = UserDefaults.standard.string(forKey: "TVContainer.lastPort.\(id.uuidString)") ?? ""
    }

    private func connectPairedTV() {
        guard let id = pairedTVID, let tv = appleTV.saved.first(where: { $0.id == id }) else {
            manualError = "Choose an already paired Apple TV."; return
        }
        guard let port = UInt16(manualPort.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            manualError = "Enter TVContainer's current TCP port (1–65535), not the Apple TV pairing port."; return
        }
        // Routing preference only, scoped to the saved TV rather than its name/IP.
        // Remember valid attempts even if the TV is offline or pairing is declined.
        UserDefaults.standard.set(String(port), forKey: "TVContainer.lastPort.\(id.uuidString)")
        let device = TVContainerDevice(pairingID: id, name: tv.name, port: port)
        manualError = nil; target = device
        model.connect(device)
    }

    private var connectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.status).font(.system(size: 17, weight: .semibold))
                if let selected { Text(selected.name).font(.subheadline).foregroundStyle(.white.opacity(0.7)) }
                if model.selectedID != nil && selected == nil && !model.busy {
                    Text("Choose a paired TV and connect using its current TVContainer port.").font(.caption)
                }
                if model.total > 0 {
                    ProgressView(value: Double(model.completed), total: Double(model.total)).tint(.white)
                    Text("\(bytes(model.completed)) / \(bytes(model.total))")
                        .font(.system(.subheadline, design: .monospaced)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.busy {
                    SwiftUI.Button("Cancel", role: .cancel) { model.cancel() }.bold()
                }
                if let result = model.result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? Color.green : Color.orange).font(.subheadline)
                }
                if let error = model.error { Text(error).font(.subheadline).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(.vertical, 4)
        } header: { heading("CONNECTION & TRANSFER") } footer: {
            Text("After uploading, confirm Install or Import on Apple TV. TVContainer sends its final result after the operation finishes. Upload progress alone does not confirm installation.")
                .foregroundStyle(.white.opacity(0.7))
        }.listRowBackground(Color.white.opacity(0.15))
    }

    private var sendingSection: some View {
        Section {
            SwiftUI.Button {
                if model.staged != nil, let selected { model.sendIPA(to: selected) }
                else { pickingIPA = true }
            } label: {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.up.document.fill").font(.system(size: 54))
                    Text("Send and install IPA").font(.system(size: 19, weight: .bold))
                    if let file = model.staged { Text(file.name).font(.subheadline).lineLimit(2) }
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }.disabled(model.busy || selected == nil)
            if model.staged != nil {
                SwiftUI.Button { pickingIPA = true } label: { Label("Choose Another IPA", systemImage: "folder").bold() }
                    .disabled(model.busy)
            }
            SwiftUI.Button { certificateConsent = true } label: {
                Label("Send SideTVStore certificate", systemImage: "signature").font(.system(size: 17, weight: .bold))
            }.disabled(model.busy || selected == nil || model.certificateAlreadySent)
            if model.certificateAlreadySent {
                Text("Certificate import was confirmed on this TV during this session.").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        } footer: {
            Text("IPAs are sent unchanged. TVContainer requires a signing certificate before installing. Protocol 1 has no certificate-status query; it rejects an existing certificate without replacing it.")
                .foregroundStyle(.white.opacity(0.7))
        }.listRowBackground(Color.white.opacity(0.15))
    }

    @ViewBuilder
    private var phoneSection: some View {
        if let fingerprint = model.phoneFingerprint {
            Section {
                Text(TVContainerIdentityStore.displayFingerprint(fingerprint))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } header: { heading("THIS IPHONE'S TLS FINGERPRINT") } footer: {
                Text("Compare this phone fingerprint with the Apple TV Pair popup. Transfer pairing is separate from developer-device pairing.")
                    .foregroundStyle(.white.opacity(0.7))
            }.listRowBackground(Color.white.opacity(0.15))
        }
    }

    @ViewBuilder
    private var pinsSection: some View {
        if !model.pins.isEmpty {
            Section {
                ForEach(model.pins) { pin in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pin.name).bold()
                        Text(TVContainerIdentityStore.displayFingerprint(pin.fingerprint))
                            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        SwiftUI.Button("Forget TV / Pair again", role: .destructive) { forgetting = pin }
                            .disabled(model.busy)
                    }.padding(.vertical, 4)
                }
            } header: { heading("APPROVED TVCONTAINERS") }.listRowBackground(Color.white.opacity(0.15))
        }
    }

    private func pairingSheet(_ prompt: TVContainerTransferModel.PairingPrompt) -> some View {
        NavigationStack {
            List {
                Section("Compare the TV fingerprint") {
                    Text("Keep TVContainer Settings visible on Apple TV. Confirm that its TLS fingerprint exactly matches this one before continuing.")
                    Text(TVContainerIdentityStore.displayFingerprint(prompt.tvFingerprint))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }.listRowBackground(Color.white.opacity(0.15))
                Section("Then approve this iPhone on TV") {
                    Text("After approving here, Apple TV can show Pair / Cancel. Compare this phone fingerprint with that popup and approve on the TV.")
                    Text(TVContainerIdentityStore.displayFingerprint(prompt.phoneFingerprint))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }.listRowBackground(Color.white.opacity(0.15))
                Section {
                    SwiftUI.Button("TV fingerprint matches") { model.answerPairing(true) }.bold()
                    SwiftUI.Button("Cancel pairing", role: .cancel) { model.answerPairing(false) }
                }.listRowBackground(Color.white.opacity(0.15))
                Text("Pairing expires after about 90 seconds. Restart the connection if it expires.").font(.caption)
            }.scrollContentBackground(.hidden).foregroundStyle(.white).tint(.white)
                .background(Color(uiColor: .settingsBackground).ignoresSafeArea()).navigationTitle("Verify fingerprints")
        }
    }

    private func heading(_ text: String) -> some View { Text(text).foregroundStyle(.white.opacity(0.65)) }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

private struct TVContainerIPAPicker: UIViewControllerRepresentable {
    let selected: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .item keeps third-party IPA UTIs selectable in Files and LiveContainer.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL?) -> Void
        private var completed = false
        init(_ selected: @escaping (URL?) -> Void) { self.selected = selected }
        private func finish(_ url: URL?) {
            guard !completed else { return }
            completed = true; selected(url)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
}

@MainActor
enum TVContainerPresentation {
    static func open(from controller: UIViewController, ipa: URL? = nil) {
        let host = UIHostingController(rootView: TVContainerTransferView(initialIPA: ipa))
        host.view.backgroundColor = .settingsBackground
        if let navigation = controller.navigationController { navigation.pushViewController(host, animated: true) }
        else { controller.present(UINavigationController(rootViewController: host), animated: true) }
    }
}
#endif
