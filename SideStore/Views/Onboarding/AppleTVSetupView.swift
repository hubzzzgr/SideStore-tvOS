import SwiftUI
import TVPairCore

struct AppleTVSetupView: View {
    @ObservedObject private var model = AppleTVManager.shared
    @ObservedObject private var discovery = AppleTVManager.shared.discovery
    @ObservedObject private var theme = ThemeManager.shared
    @State private var host = ""
    @State private var error: String?
    @State private var working = false
    @State private var ready = false
    @State private var pendingForget: SavedDevice?
    @FocusState private var codeFocused: Bool

    private var accent: Color { Color(uiColor: theme.primaryColor) }
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
            if ready { installedApps }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .tint(accent)
        .navigationTitle("Apple TV")
        .navigationBarTitleDisplayMode(.large)
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
                    .font(.title3.bold()).foregroundStyle(accent)
                Text("Pair once to install and refresh tvOS apps from your iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary)
                step("1", title: "Use the same Wi-Fi", detail: "Keep your iPhone and Apple TV on the same local network.")
                step("2", title: "Open pairing on your TV", detail: "Settings → Remotes and Devices → Remote App and Devices")
                step("3", title: "Choose your TV below", detail: "Enter the code shown on your TV. SideTVstore sets up developer access automatically.")
            }.padding(.vertical, 8)
        }
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold()).foregroundStyle(accent)
                .frame(width: 26, height: 26).background(accent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            SwiftUI.Button("Confirm Code") { codeFocused = false; model.submitPIN() }
                .buttonStyle(.borderedProminent).disabled(model.pin.count != 6)
        } header: { Text("Enter your code") }
    }

    private var connectionStatus: some View {
        Section {
            HStack(spacing: 12) {
                if busy { ProgressView() }
                else { Image(systemName: ready ? "checkmark.circle.fill" : "appletv").foregroundStyle(ready ? Color.green : accent) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(ready ? "Ready to Install" : busy ? "Connecting to Apple TV…" : "Connection").font(.headline)
                    Text(ready ? "Import a tvOS IPA in My Apps to get started." : model.status)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red) }
            if busy { SwiftUI.Button("Cancel", role: .cancel) { model.cancelSetup() } }
            if let info = model.information {
                DisclosureGroup("Connection Details") {
                    LabeledContent("Apple TV", value: info.name ?? "Apple TV")
                    LabeledContent("tvOS", value: info.osVersion ?? "Unavailable")
                    Text(info.developerServiceDetail).font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            if !ready { Text("Pairing is followed by developer access and installation checks. Keep your TV awake until setup finishes.") }
        }
    }

    private var savedTVs: some View {
        Section {
            ForEach(model.saved) { device in
                HStack(spacing: 12) {
                    Image(systemName: "appletv.fill").foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).font(.headline)
                        Text(model.selectedID == device.id ? "Selected Apple TV" : "Saved pairing").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SwiftUI.Button("Connect") { perform { try model.select(device.id); _ = try await model.ready(force: true) } }
                        .buttonStyle(.bordered).disabled(busy)
                    Menu {
                        SwiftUI.Button("Forget Pairing", role: .destructive) { pendingForget = device }
                    } label: { Image(systemName: "ellipsis.circle").padding(.vertical, 8) }
                    .disabled(busy).accessibilityLabel("Options for \(device.name)")
                }.padding(.vertical, 4)
            }
        } header: { Text("Your Apple TVs") }
        footer: { Text("Pairing credentials are kept securely in this iPhone’s Keychain. Saved TVs reconnect automatically when available.") }
    }

    private var nearbyTVs: some View {
        Section {
            if nearby.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Looking for Apple TVs…", systemImage: "wifi").font(.headline)
                    Text("Allow Local Network access for SideTVstore and leave the pairing screen open on your TV.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            ForEach(nearby) { device in
                SwiftUI.Button {
                    guard let address = device.addresses.first(where: { !$0.contains(":") }) ?? device.addresses.first else { return }
                    error = nil; model.setup(host: address)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "appletv.fill").foregroundStyle(accent)
                        Text(device.name).foregroundStyle(.primary)
                        Spacer()
                        Text("Pair").font(.subheadline.bold()).foregroundStyle(accent)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.disabled(busy || device.addresses.isEmpty)
            }
            SwiftUI.Button("Scan Again", systemImage: "arrow.clockwise") { model.startDiscovery() }.disabled(busy)
        } header: { Text("Nearby Apple TVs") }
    }

    private var manualAddress: some View {
        Section {
            DisclosureGroup("Can’t Find Your TV?") {
                Text("Check the Wi-Fi and Local Network permission first. You can also enter the IP address shown in your Apple TV’s Network settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("Apple TV IP address", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                SwiftUI.Button("Pair Using IP Address") {
                    error = nil; model.setup(host: host.trimmingCharacters(in: .whitespacesAndNewlines))
                }.disabled(busy || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(discovery.networkStatus).font(.caption).foregroundStyle(.secondary)
                if let message = discovery.discoveryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var installedApps: some View {
        Section {
            SwiftUI.Button("Load Installed Apps", systemImage: "square.stack") { perform { try await model.inventory() } }.disabled(busy)
            ForEach(model.installedApps.keys.sorted(), id: \.self) { identifier in
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.installedApps[identifier] ?? identifier)
                    Text(identifier).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("On Your Apple TV") }
        footer: { Text("Use My Apps to manage packages you’ve imported into SideTVstore.") }
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
