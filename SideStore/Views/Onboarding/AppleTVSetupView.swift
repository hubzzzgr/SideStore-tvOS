import SwiftUI
import TVPairCore

struct AppleTVSetupView: View {
    @ObservedObject private var model = AppleTVManager.shared
    @ObservedObject private var discovery = AppleTVManager.shared.discovery
    @State private var host = ""
    @State private var error: String?

    var body: some View {
        List {
            Section("Apple TV") {
                Text("Keep your iPhone and Apple TV on the same local network. On the TV, open Settings → Remotes and Devices → Remote App and Devices. Setup requests developer trust automatically; enter the code shown on the TV here.")
                TextField("Apple TV IP address", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                SwiftUI.Button("Pair and enable developer access") { model.setup(host: host) }
                    .disabled(model.busy || host.isEmpty)
                SwiftUI.Button("Scan local network") { model.startDiscovery() }.disabled(model.busy)
                Text(discovery.networkStatus).font(.caption).foregroundStyle(.secondary)
                if let message = discovery.discoveryMessage { Text(message).font(.caption) }
            }
            if model.needsPIN {
                Section("Code displayed on Apple TV") {
                    SecureField("Six-digit code", text: $model.pin).keyboardType(.numberPad)
                    SwiftUI.Button("Confirm code") { model.submitPIN() }.disabled(model.pin.count != 6)
                }
            }
            Section("Connection") {
                Text(model.status)
                if model.busy { ProgressView(); SwiftUI.Button("Cancel setup", role: .cancel) { model.cancelSetup() } }
                if let info = model.information {
                    LabeledContent("TV", value: info.name ?? "Apple TV")
                    LabeledContent("tvOS", value: info.osVersion ?? "Unavailable")
                    Text(info.developerServiceDetail).font(.caption)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("Discovered Apple TVs") {
                ForEach(discovery.devices.filter { $0.deviceFamily == .appleTV || $0.service == .manualPairing }) { device in
                    SwiftUI.Button {
                        host = device.addresses.first(where: { !$0.contains(":") }) ?? device.addresses.first ?? ""
                    } label: {
                        VStack(alignment: .leading) {
                            Label(device.name, systemImage: "appletv")
                            Text(device.addresses.joined(separator: ", ")).font(.caption)
                        }
                    }.disabled(model.busy)
                }
            }
            Section("Saved pairings") {
                ForEach(model.saved) { device in
                    VStack(alignment: .leading) {
                        Label(device.name, systemImage: model.selectedID == device.id ? "checkmark.circle.fill" : "appletv")
                        HStack {
                            SwiftUI.Button("Connect") {
                                Task {
                                    do { try model.select(device.id); _ = try await model.ready(force: true); error = nil }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                            Spacer()
                            SwiftUI.Button("Forget", role: .destructive) {
                                Task { do { try await model.delete(device.id) } catch { self.error = error.localizedDescription } }
                            }
                        }.buttonStyle(.borderless).disabled(model.busy)
                    }
                }
                Text("Credentials are stored in this iPhone's Keychain. Forgetting them here does not revoke trust on the TV.").font(.caption)
            }
            Section("Apps on this TV") {
                SwiftUI.Button("Read installed apps") {
                    Task { do { try await model.inventory(); error = nil } catch { self.error = error.localizedDescription } }
                }.disabled(model.busy || model.selectedID == nil)
                ForEach(model.installedApps.keys.sorted(), id: \.self) { identifier in
                    VStack(alignment: .leading) {
                        Text(model.installedApps[identifier] ?? identifier)
                        Text(identifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Import tvOS IPAs in My Apps to sign, install, update and refresh them. Only packages cached by this fork can be re-signed.").font(.caption)
            }
        }
        .navigationTitle("Apple TV")
        .task {
            do { try await model.load() } catch { self.error = error.localizedDescription }
            model.startDiscovery()
        }
    }
}
