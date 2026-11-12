import SwiftUI
import TVPairCore
import UniformTypeIdentifiers

struct AppleTVSetupView: View {
    @ObservedObject private var model = AppleTVManager.shared
    @ObservedObject private var discovery = AppleTVManager.shared.discovery
    @ObservedObject private var theme = ThemeManager.shared
    @State private var host = ""
    @State private var error: String?
    @State private var working = false
    @State private var ready = false
    @State private var pendingForget: SavedDevice?
    @State private var showPairingImporter = false
    @State private var selectedPairing: Result<[ImportedLocalFile], Error>?
    @State private var pairingExport: PairingFileDocument?
    @State private var showPairingExporter = false
    @State private var fileNotice: String?
    @FocusState private var codeFocused: Bool

    private var busy: Bool { model.busy || working }
    private var nearby: [AppleTVDevice] {
        discovery.devices.filter { $0.deviceFamily == .appleTV || $0.service == .manualPairing }
    }

    var body: some View {
        List {
            introduction
            if model.needsPIN { codeEntry }
            connectionStatus
            if !model.saved.isEmpty { savedTVs }
            nearbyTVs
            manualAddress
            pairingFiles
            if ready && !busy { installedApps }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(.white)
        .navigationTitle("Apple TV")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showPairingImporter, onDismiss: importSelectedPairing) {
            LocalFilePicker(maximumBytes: 1_048_576) { result in
                selectedPairing = result; showPairingImporter = false
            }
        }
        .fileExporter(isPresented: $showPairingExporter, document: pairingExport, contentType: .propertyList, defaultFilename: "AppleTV-Pairing") { result in
            pairingExport = nil
            switch result {
            case .success: fileNotice = "Pairing file exported."
            case let .failure(error): self.error = error.localizedDescription
            }
        }
        .onReceive(model.readiness) { result in ready = (try? result.get()) == true }
        .onChange(of: model.needsPIN) { _, needsPIN in codeFocused = needsPIN }
        .onChange(of: model.pin) { _, value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != value { model.pin = digits }
        }
        .confirmationDialog("Forget this Apple TV?", isPresented: Binding(
            get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }
        ), titleVisibility: .visible) {
            SwiftUI.Button("Forget Pairing", role: .destructive) {
                if let device = pendingForget { perform { try await model.delete(device.id) } }
                pendingForget = nil
            }
        } message: {
            Text("You will need the code on your TV to pair again. This does not revoke trust on the TV.")
        }
        .task {
            do { try await model.load() } catch { self.error = error.localizedDescription }
            model.startDiscovery()
        }
    }

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 18) {
                Label("Your apps. On the big screen.", systemImage: "appletv.fill")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text("Pair once to install and refresh tvOS apps from your iPhone.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                step("1", title: "Use the same Wi-Fi", detail: "Keep your iPhone and Apple TV on the same local network.")
                step("2", title: "Open pairing on your TV", detail: "Settings → Remotes and Devices → Remote App and Devices")
                step("3", title: "Choose your TV below", detail: "Enter the code shown on your TV. SideTVstore sets up developer access automatically.")
            }.padding(.vertical, 8)
        } header: { Text("SETUP").foregroundStyle(.white.opacity(0.65)) }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Color.white.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var codeEntry: some View {
        Section {
            Text("Enter the six-digit code displayed on your Apple TV.").font(.subheadline)
            SecureField("Pairing code", text: $model.pin)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit()).focused($codeFocused)
                .accessibilityLabel("Six-digit Apple TV pairing code")
            actionRow("Confirm Code") { codeFocused = false; model.submitPIN() }.disabled(model.pin.count != 6)
        } header: { Text("ENTER YOUR CODE").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.65)) }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private var connectionStatus: some View {
        Section {
            HStack(spacing: 12) {
                if busy { ProgressView() }
                else { Image(systemName: ready ? "checkmark.circle.fill" : "appletv").foregroundStyle(ready ? Color.green : Color.white) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(busy ? "Connecting to Apple TV…" : ready ? "Ready to Install" : "Connection").font(.headline)
                    Text(ready && !busy ? "Import a tvOS IPA in My Apps to get started." : model.status)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
            }.padding(.vertical, 4)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red) }
            if busy { SwiftUI.Button("Cancel", role: .cancel) { model.cancelSetup() } }
            if let info = model.information {
                DisclosureGroup("Connection Details") {
                    LabeledContent("Apple TV", value: info.name ?? "Apple TV")
                    LabeledContent("tvOS", value: info.osVersion ?? "Unavailable")
                    Text(info.developerServiceDetail).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        } footer: {
            if !ready { Text("Pairing is followed by developer access and installation checks. Keep your TV awake until setup finishes.") }
        }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private var savedTVs: some View {
        Section {
            ForEach(model.saved) { device in
                HStack(spacing: 12) {
                    Image(systemName: "appletv.fill").foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.headline)
                        Text(model.selectedID == device.id ? "Selected Apple TV" : "Saved pairing").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    SwiftUI.Button("Connect") { perform { try await model.selectLibrary(device.id); _ = try await model.ready(force: true) } }
                        .buttonStyle(.borderless).font(.system(size: 17, weight: .bold)).disabled(busy)
                    Menu {
                        SwiftUI.Button("Export Pairing File", systemImage: "square.and.arrow.up") { exportPairing(device.id) }
                        SwiftUI.Button("Forget Pairing", role: .destructive) { pendingForget = device }
                    } label: { Image(systemName: "ellipsis.circle").padding(.vertical, 8) }
                    .disabled(busy).accessibilityLabel("Options for \(device.name)")
                }.padding(.vertical, 4)
            }
        } header: { Text("YOUR APPLE TVS").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.65)) }
        footer: { Text("Pairing credentials are kept securely in this iPhone’s Keychain. Saved TVs reconnect automatically when available.") }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private var nearbyTVs: some View {
        Section {
            if nearby.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(discovery.scanning ? "Looking for Apple TVs…" : "No Apple TVs Found", systemImage: "wifi").font(.headline)
                    Text("Allow Local Network access for SideTVstore and leave the pairing screen open on your TV.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }.padding(.vertical, 8)
            }
            ForEach(nearby) { device in
                SwiftUI.Button {
                    guard let address = device.addresses.first(where: { !$0.contains(":") }) ?? device.addresses.first else { return }
                    error = nil; model.setup(host: address)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "appletv.fill").foregroundStyle(.white)
                        Text(device.name).foregroundStyle(.white)
                        Spacer()
                        Text("Pair").font(.subheadline.bold()).foregroundStyle(.white)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }.padding(.vertical, 6)
                }.disabled(busy || device.addresses.isEmpty)
            }
            actionRow("Scan Again") { model.startDiscovery() }.disabled(busy)
        } header: { Text("NEARBY APPLE TVS").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.65)) }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private var manualAddress: some View {
        Section {
            DisclosureGroup("Can’t Find Your TV?") {
                Text("Check the Wi-Fi and Local Network permission first. You can also enter the IP address shown in your Apple TV’s Network settings.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                TextField("Apple TV IP address", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                SwiftUI.Button("Pair Using IP Address") {
                    error = nil; model.setup(host: host.trimmingCharacters(in: .whitespacesAndNewlines))
                }.disabled(busy || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(discovery.networkStatus).font(.caption).foregroundStyle(.white.opacity(0.7))
                if let message = discovery.discoveryMessage { Text(message).font(.caption).foregroundStyle(.white.opacity(0.7)) }
            }
        }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private var installedApps: some View {
        Section {
            actionRow("Load Installed Apps") { perform { try await model.inventory() } }.disabled(busy)
            ForEach(model.installedApps.keys.sorted(), id: \.self) { identifier in
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.installedApps[identifier] ?? identifier)
                    Text(identifier).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
        } header: { Text("ON YOUR APPLE TV").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.65)) }
        footer: { Text("Use My Apps to manage packages you’ve imported into SideTVstore.") }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private var pairingFiles: some View {
        Section {
            actionRow("Import Pairing File") {
                error = nil; fileNotice = nil; selectedPairing = nil; showPairingImporter = true
            }.disabled(busy)
            if let id = model.selectedID {
                actionRow("Export Selected TV Pairing") { exportPairing(id) }.disabled(busy)
            }
            if let fileNotice { Text(fileNotice).font(.caption).foregroundStyle(.white.opacity(0.7)) }
        } header: { Text("PAIRING FILES").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.65)) }
        footer: { Text("Import a Remote Pairing plist from SideTVstore or TVPair. Exported files contain private pairing credentials; keep them private. Saved credentials remain in Keychain.") }
        .listRowBackground(Color.white.opacity(0.15))
    }

    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            HStack {
                Text(title).font(.system(size: 17, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold))
            }.foregroundStyle(.white).padding(.vertical, 3)
        }
    }

    private func importSelectedPairing() {
        guard let result = selectedPairing else { return }
        selectedPairing = nil
        perform {
            if let file = try result.get().first {
                try await model.importPairing(file.data)
                fileNotice = "Pairing imported. Use Connect under Your Apple TVs to verify it."
            }
        }
    }
    private func exportPairing(_ id: UUID) {
        perform {
            let data = try await model.exportPairing(id)
            pairingExport = PairingFileDocument(data: data)
            showPairingExporter = true
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        working = true; error = nil
        Task { @MainActor in
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
