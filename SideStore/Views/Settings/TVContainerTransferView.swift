#if !os(tvOS)
import SwiftUI
import UniformTypeIdentifiers
import TVPairCore

struct TVContainerTransferView: View {
    var initialIPA: URL? = nil
    @StateObject private var model = TVContainerTransferModel()
    @StateObject private var discovery = TVContainerDiscovery()
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickingIPA = false
    @State private var pickedURL: URL?
    @State private var certificateConsent = false
    @State private var forgetting: TVContainerIdentityStore.Pin?

    private var selected: TVContainerDevice? { discovery.devices.first { $0.id == model.selectedID && $0.supported } }

    var body: some View {
        List {
            Section {
                Text("Open TVContainer's launcher on Apple TV and enable Settings → SideTVStore TCP Server. Keep the launcher open and both devices on the same local network.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
            } header: { heading("TVCONTAINER") }
            .listRowBackground(Color.white.opacity(0.15))

            Section {
                ForEach(discovery.devices) { device in
                    SwiftUI.Button { model.connect(device) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "appletv.fill").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.system(size: 17, weight: .bold))
                                Text("TVContainer \(device.appVersion.isEmpty ? "Unknown version" : device.appVersion)")
                                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                                if !device.supported {
                                    Text("Unsupported protocol: \(device.protocolVersion.isEmpty ? "not advertised" : device.protocolVersion)")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                // Bonjour names may be duplicated; the service endpoint
                                // disambiguates rows but never authenticates the TV.
                                Text(device.id).font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: device.id == model.selectedID ? "checkmark.circle.fill" : "chevron.right")
                        }.padding(.vertical, 4)
                    }.disabled(model.busy || !device.supported)
                }
                if discovery.devices.isEmpty {
                    Text(discovery.issue ?? "No TVContainers found. Enable the server on Apple TV, check that both devices share Wi-Fi, and allow Local Network access in iPhone Settings. Guest apps also need their host to permit _tvcontainer._tcp.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                } else if let issue = discovery.issue {
                    Text(issue).font(.subheadline)
                }
                SwiftUI.Button { discovery.start() } label: { Label("Scan Again", systemImage: "arrow.clockwise").bold() }
                    .disabled(model.busy)
            } header: { heading("NEARBY APPLE TVS") }
            .listRowBackground(Color.white.opacity(0.15))

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.status).font(.system(size: 17, weight: .semibold))
                    if model.selectedID != nil && selected == nil && !model.busy {
                        Text("The selected service is no longer available. Wait for it to appear again before sending.").font(.caption)
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

            if let fingerprint = model.phoneFingerprint {
                Section {
                    Text(TVContainerIdentityStore.displayFingerprint(fingerprint))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } header: { heading("THIS IPHONE'S TLS FINGERPRINT") } footer: {
                    Text("Compare this phone fingerprint with the Apple TV Pair popup. Transfer pairing is separate from developer-device pairing.")
                        .foregroundStyle(.white.opacity(0.7))
                }.listRowBackground(Color.white.opacity(0.15))
            }
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
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .foregroundStyle(.white).tint(.white)
        .navigationTitle("TVContainer").navigationBarTitleDisplayMode(.large)
        .task { model.open(initialIPA: initialIPA); discovery.start() }
        .onDisappear { discovery.stop(); model.close() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancel(); discovery.stop() } else if phase == .active { discovery.start() } }
        .sheet(isPresented: $pickingIPA, onDismiss: {
            if let pickedURL { model.stage(pickedURL, sendTo: selected); self.pickedURL = nil }
        }) {
            TVContainerIPAPicker { url in pickedURL = url; pickingIPA = false }
        }
        .sheet(item: Binding(get: { model.pairingPrompt }, set: { if $0 == nil { model.answerPairing(false) } })) { prompt in
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
        init(_ selected: @escaping (URL?) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
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
