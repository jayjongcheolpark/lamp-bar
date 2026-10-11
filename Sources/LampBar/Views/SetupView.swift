import SwiftUI

/// One-time setup: which plug drives each Kasa lamp, the Govee bar, and the optional TP-Link login.
struct SetupView: View {
    @EnvironmentObject var store: LampStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                plugs
                Divider()
                govee
                Divider()
                login
            }
            .padding(22)
        }
        .frame(width: 560, height: 640)
    }

    // MARK: Plugs

    private var plugs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kasa plugs").font(.title3.weight(.semibold))
            Text("Choose the plug that each lamp is plugged into. Use Flash to switch a plug off and on again and see which lamp it drives.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(Lamp.kasa) { lamp in
                    GridRow {
                        Text("\(lamp.number)  \(lamp.name)")
                        Picker("", selection: binding(for: lamp.id)) {
                            Text("Not set").tag(String?.none)
                            ForEach(store.outlets) { outlet in
                                Text(outletTitle(outlet)).tag(Optional(outlet.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 290)
                        .accessibilityLabel("Plug for \(lamp.name)")
                    }
                }
            }
            if store.outlets.isEmpty {
                Text("Looking for Kasa plugs on the local network…").foregroundStyle(.secondary)
            } else {
                Text("Plugs found").font(.headline).padding(.top, 6)
                ForEach(store.outlets) { outlet in
                    HStack {
                        Circle().fill(outlet.isOn ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(outlet.label)
                            Text("\(outlet.model) · \(outlet.host)\(outlet.viaHelper ? " · TP-Link login" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let lamp = store.lamp(mappedTo: outlet) {
                            Text("Lamp \(Lamp.with(lamp).number)").foregroundStyle(.secondary)
                        }
                        Button("Flash") { store.flash(outlet) }
                            .help("Switch this plug off and on again")
                    }
                }
            }
            Button("Search again") { store.refreshSoon() }
        }
    }

    private func outletTitle(_ outlet: KasaOutlet) -> String {
        outlet.childID == nil ? "\(outlet.alias) (\(outlet.model))" : "\(outlet.alias) · \(outlet.deviceAlias)"
    }

    private func binding(for lamp: LampID) -> Binding<String?> {
        Binding(get: { store.mapping[lamp] }, set: { store.map(lamp, to: $0) })
    }

    // MARK: Govee

    private var govee: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Govee light bar").font(.title3.weight(.semibold))
            if let device = store.goveeDevice, store.goveeProblem == nil {
                Text("Lamp 2 is the \(device.sku) at \(device.host), controlled over Govee's LAN API.")
            } else {
                Text(store.goveeProblem ?? "Looking for the light bar…").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("To let this Mac control the bar:")
                    Text("1. Open the Govee Home app on your phone.")
                    Text("2. Open the light bar and tap the gear icon.")
                    Text("3. Switch on LAN Control.")
                    Text("4. Make sure the bar and this Mac are on the same Wi-Fi network.")
                }
                .font(.callout)
            }
            Button("Search again") { store.rescanGovee() }
        }
    }

    // MARK: TP-Link login

    @State private var username = ""
    @State private var password = ""
    @State private var loginMessage: String?

    private var login: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TP-Link login (only for newer Kasa firmware)").font(.title3.weight(.semibold))
            Text("Kasa plugs on the older local protocol need no login. Plugs with newer firmware accept local commands only with the TP-Link account login. Lamp Bar stores the login in the macOS Keychain and sends it only to the plugs.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !KasaHelper.isInstalled {
                Text("These plugs also need the Kasa login helper. Run scripts/install-kasa-helper.sh from the Lamp Bar source folder.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.hasLogin {
                HStack {
                    Label("Login saved in the Keychain", systemImage: "key.fill")
                    Spacer()
                    Button("Remove login") { store.removeLogin() }
                }
                if let problem = store.helperProblem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            } else {
                TextField("TP-Link account email", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                HStack {
                    Button("Save to Keychain") {
                        let saved = store.saveLogin(TPLinkCredentials(username: username, password: password))
                        loginMessage = saved ? nil : "The Keychain did not accept the login."
                        if saved { password = "" }
                    }
                    .disabled(username.isEmpty || password.isEmpty)
                    if let loginMessage { Text(loginMessage).foregroundStyle(.red) }
                }
            }
        }
    }
}
