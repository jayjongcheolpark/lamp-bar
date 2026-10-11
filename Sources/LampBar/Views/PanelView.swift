import SwiftUI

/// The menu bar popover, built like Tesla's climate panel: the lamps in 3D on top,
/// one button per lamp below, and a status line. Lamps only switch on and off.
struct PanelView: View {
    @EnvironmentObject var store: LampStore
    var openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The stage runs a little past the card's padding, 4:3, tall enough for the tallest lamps at every angle.
            LampStageView()
                .frame(width: 512, height: 384)
                .padding(.horizontal, -6)
                .padding(.top, 6)
            HStack(spacing: 8) {
                ForEach(Lamp.all) { LampButton(lamp: $0) }
            }
            .padding(.top, 8)
            footer
                .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: 540)
        // A snapshot draws the 3D stage underneath the panel, so the panel leaves its background out.
        .background(AppDelegate.snapshotPath == nil ? Palette.card : .clear)
        .foregroundStyle(Palette.fg)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb")
                .font(.system(size: 17))
                .foregroundStyle(Palette.muted)
            Text("Office").font(.system(size: 19, weight: .medium))
            Text("\(store.onCount) of 5 on").font(.system(size: 19)).foregroundStyle(Palette.muted)
                .contentTransition(.numericText())
                .animation(.default, value: store.onCount)
            if store.needsMapping {
                Button(action: openSetup) {
                    Text("Choose plugs")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.warm)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Palette.tileHi))
                        .overlay(Capsule().stroke(Palette.selectedEdge))
                }
                .buttonStyle(.plain)
                .help("Choose which Kasa plug drives each lamp")
            }
            Spacer()
            PowerButton()
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            SyncStatus()
            Spacer()
            Text("Kasa + Govee · local network")
            Menu {
                Button("Setup…", action: openSetup)
                Button("Refresh now") { store.refreshSoon() }
                Divider()
                Button("Quit Lamp Bar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Setup and Quit")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.muted)
    }
}

struct PowerButton: View {
    @EnvironmentObject var store: LampStore

    var body: some View {
        let on = store.anyOn
        Button { store.toggleOffice() } label: {
            Image(systemName: "power")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(on ? Palette.warm : Color(hex: 0x9A978F))
                .frame(width: 52, height: 52)
                .background(Circle().fill(RadialGradient(colors: [Color(hex: 0x2A2B2E), Color(hex: 0x121314)],
                                                         center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 30)))
                .overlay(Circle().stroke(on ? Color(hex: 0x5C4A33) : Color(hex: 0x3A3B3E), lineWidth: 1.5))
                .shadow(color: on ? Color(hex: 0xFFBE6E).opacity(0.22) : .black.opacity(0.6), radius: on ? 12 : 8, y: on ? 0 : 6)
                .animation(.easeInOut(duration: 0.3), value: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Switch all office lamps off" : "Switch all office lamps on")
        .accessibilityLabel(on ? "Switch all office lamps off" : "Switch all office lamps on")
    }
}

/// One lamp: its drawing, name and ON or OFF. Clicking it switches the lamp.
struct LampButton: View {
    @EnvironmentObject var store: LampStore
    let lamp: Lamp

    var body: some View {
        let state = store.state(lamp.id)
        let on = state.isOn
        Button { store.toggle(lamp.id) } label: {
            VStack(spacing: 5) {
                LampArt(lamp: lamp.id, on: on, light: Color(hex: 0xFFD9A0))
                    .frame(width: 50, height: 50)
                Text(lamp.name)
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 28, alignment: .top)
                Text(status(state))
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(statusColor(state))
            }
            .foregroundStyle(on ? Palette.fg : Palette.muted)
            .padding(.vertical, 11).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            // Every lamp uses the same warm ON style, whatever its light color.
            .background(RoundedRectangle(cornerRadius: 18).fill(on ? Color(hex: 0x1D1A15) : Palette.tile))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(on ? Color(hex: 0x4A3E2C) : Palette.line))
            .shadow(color: on ? Color(hex: 0xFFB464).opacity(0.12) : .clear, radius: 13)
            .opacity(state.isAvailable || state.availability == .unknown ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.4), value: on)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .help(help(state))
        .accessibilityLabel("\(lamp.name), \(status(state).lowercased())")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func status(_ state: LampState) -> String {
        switch state.availability {
        case .unknown: return "…"
        case .notMapped: return "NO PLUG"
        case .unavailable: return "OFFLINE"
        case .available: return state.isOn ? "ON" : "OFF"
        }
    }

    private func statusColor(_ state: LampState) -> Color {
        switch state.availability {
        case .unavailable: return Palette.alert
        case .available where state.isOn: return Palette.warm
        default: return Color(hex: 0x5F5C58)
        }
    }

    private func help(_ state: LampState) -> String {
        switch state.availability {
        case .notMapped: return "\(lamp.name): choose its plug in Setup"
        case let .unavailable(reason): return "\(lamp.name) is not answering (\(reason)). Click to try again."
        default: return "\(lamp.name) · \(lamp.source). Click to switch \(state.isOn ? "off" : "on")."
        }
    }
}

struct SyncStatus: View {
    @EnvironmentObject var store: LampStore
    @State private var spin = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(store.isSyncing ? Color(hex: 0xB8B3AB) : statusColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(store.isSyncing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spin)
            Text(text)
        }
        .onChange(of: store.isSyncing) { _, syncing in spin = syncing }
        .help(store.goveeProblem.map { "\($0) Turn on LAN Control for the bar in the Govee Home app: open the bar, tap the gear icon, switch on LAN Control." } ?? "")
    }

    private var statusColor: Color {
        store.unavailableCount > 0 ? Palette.alert : Color(hex: 0x3A3B3E)
    }

    private var text: String {
        if store.isSyncing { return "Syncing…" }
        guard store.lastSync != nil else { return "Connecting…" }
        if store.goveeProblem != nil { return "Light bar not answering · turn on LAN Control" }
        let missing = store.unavailableCount
        return missing > 0 ? "\(missing) not answering" : "In sync"
    }
}
