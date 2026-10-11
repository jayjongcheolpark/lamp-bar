import SwiftUI

/// The menu bar popover, built like Tesla's climate panel: the lamps on top, one big readout with a slider,
/// lamp chips, four mode tiles and a status line.
struct PanelView: View {
    @EnvironmentObject var store: LampStore
    var openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The stage runs a little past the card's padding, with the prototype's 16:9.5 shape.
            LampStageView()
                .frame(width: 512, height: 304)
                .padding(.horizontal, -6)
                .padding(.top, 6)
            Readout(openSetup: openSetup)
                .padding(.top, 2)
            BrightnessRow()
                .padding(.top, 14)
            LampChips()
                .padding(.top, 14)
            ModeTiles()
                .padding(.top, 10)
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

/// The big number: On or Off for a Kasa lamp, brightness for the Govee bar, with the selected lamp's name.
struct Readout: View {
    @EnvironmentObject var store: LampStore
    var openSetup: () -> Void

    var body: some View {
        let lamp = Lamp.with(store.selected)
        let state = store.state(lamp.id)
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            big(lamp, state)
                .font(.system(size: 68, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: state.isOn)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Text(lamp.name).font(.system(size: 17, weight: .medium))
                source(lamp, state)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private func big(_ lamp: Lamp, _ state: LampState) -> some View {
        switch state.availability {
        case .available where state.isOn && lamp.isGovee:
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text("\(store.govee?.brightness ?? 0)")
                Text("%").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.muted)
            }
        case .available: Text(state.isOn ? "On" : "Off")
        case .unknown: Text("…").foregroundStyle(Palette.muted)
        case .notMapped, .unavailable: Text("—").foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder
    private func source(_ lamp: Lamp, _ state: LampState) -> some View {
        switch state.availability {
        case .notMapped:
            Button("No plug chosen · open Setup", action: openSetup).buttonStyle(.link)
        case .unavailable where lamp.isGovee:
            Text("The light bar is not answering on the local network")
        case .unavailable:
            Text("The plug is not answering")
        default:
            Text(lamp.source)
        }
    }
}

/// The -/slider/+ row. Only the Govee bar dims, so the row is active only when it is selected.
struct BrightnessRow: View {
    @EnvironmentObject var store: LampStore
    @State private var dragValue: Double?

    var body: some View {
        let selectedGovee = store.selected == .l2
        if selectedGovee, let problem = store.goveeProblem {
            GoveeLANHelp(problem: problem)
        } else {
            let enabled = selectedGovee && store.govee != nil
            let value = dragValue ?? Double(store.govee?.brightness ?? 80)
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    StepButton(symbol: "minus", label: "Dimmer", enabled: enabled) { step(-10) }
                    track(value: value, enabled: enabled)
                    StepButton(symbol: "plus", label: "Brighter", enabled: enabled) { step(10) }
                }
                HStack {
                    Text("5%")
                    Spacer()
                    Text(selectedGovee ? "Brightness" : "Brightness · Light bar only")
                    Spacer()
                    Text("100%")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 60)
            }
        }
    }

    private func track(value: Double, enabled: Bool) -> some View {
        GeometryReader { geo in
            let fraction = (value - 5) / 95
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x0F1011))
                Rectangle()
                    .fill(LinearGradient(colors: [Color(hex: 0x2C2925), Color(hex: 0x7A6A55)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(hex: 0xF3EFE8))
                    .frame(width: 26, height: 38)
                    .shadow(color: .black.opacity(0.6), radius: 5, y: 2)
                    .offset(x: 6 + (geo.size.width - 38) * fraction)
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: 0x1D1E21)))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else { return }
                    dragValue = snap(5 + 95 * min(max(g.location.x / geo.size.width, 0), 1))
                }
                .onEnded { _ in
                    guard enabled, let v = dragValue else { return }
                    store.setGoveeBrightness(Int(v))
                    // Keep showing the dragged value until the bar reports it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dragValue = nil }
                })
        }
        .frame(height: 50)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.2), value: value)
        .accessibilityElement()
        .accessibilityLabel("Light bar brightness")
        .accessibilityValue("\(Int(value)) percent")
        .accessibilityAdjustableAction { direction in
            step(direction == .increment ? 5 : -5)
        }
    }

    private func snap(_ v: Double) -> Double { (v / 5).rounded() * 5 }

    private func step(_ delta: Int) {
        guard store.selected == .l2, store.govee != nil else { return }
        let current = store.govee?.brightness ?? 80
        store.setGoveeBrightness(min(max(Int(snap(Double(current + delta))), 5), 100))
    }
}

struct StepButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(hex: 0xD8D4CD))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color(hex: 0x151618)))
                .overlay(Circle().stroke(Palette.line))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

struct GoveeLANHelp: View {
    let problem: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(problem).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.alert)
            Text("Turn on LAN Control for the bar: in the Govee Home app, open the light bar, tap the gear icon, and switch on LAN Control. Keep the bar on the same Wi-Fi network as this Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.tile))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
    }
}

/// One chip per lamp: clicking a chip selects the lamp for the readout; the dot shows if it is on.
struct LampChips: View {
    @EnvironmentObject var store: LampStore

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Lamp.all) { lamp in
                let on = store.state(lamp.id).isOn
                let selected = store.selected == lamp.id
                Button { store.selected = lamp.id } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(on ? Palette.warm : Color(hex: 0x3A3B3E))
                            .frame(width: 6, height: 6)
                            .shadow(color: on ? Palette.warm : .clear, radius: 4)
                        Text(lamp.name).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Palette.fg : Palette.muted)
                    .padding(.horizontal, 7).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Palette.tileHi : Palette.tile))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.selectedEdge : Palette.line))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(lamp.name), \(on ? "on" : "off")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Scene, Light bar color, Sleep and At sunset. Each click moves to the next value.
struct ModeTiles: View {
    @EnvironmentObject var store: LampStore

    var body: some View {
        HStack(spacing: 8) {
            ModeTile(icon: "sun.max", key: "Scene", active: store.activeScene != nil, help: "Next scene: Evening, Focus, Night, All off") {
                Text(store.activeScene?.title ?? "Custom")
            } action: { store.cycleScene() }

            ModeTile(icon: "paintpalette", key: "Light bar color", active: store.state(.l2).isOn, help: "Next light bar color",
                     enabled: store.goveeDevice != nil && store.goveeProblem == nil) {
                HStack(spacing: 6) {
                    let color = store.govee.map { Color(rgb: $0.displayColor) } ?? Color(hex: 0xFFB866)
                    Circle().fill(color).frame(width: 12, height: 12).shadow(color: color, radius: 4)
                    Text(store.goveeSwatch?.name ?? "Custom")
                }
            } action: { store.cycleGoveeColor() }

            ModeTile(icon: "moon", key: "Sleep", active: store.sleep != .off, help: "Switch all lamps off after 30 min, 1 h or 2 h") {
                if let deadline = store.sleepDeadline {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.remaining(until: deadline, now: context.date))
                    }
                } else {
                    Text("Off")
                }
            } action: { store.cycleSleep() }

            ModeTile(icon: "sunset", key: "At sunset", active: store.sunsetEnabled,
                     help: "Start the Evening scene at sunset every day", enabled: store.location != nil) {
                if store.location == nil {
                    Text("No location").foregroundStyle(Palette.muted)
                } else if store.sunsetEnabled, let sunset = store.nextSunset {
                    Text(sunset, format: .dateTime.hour().minute())
                } else {
                    Text("Off")
                }
            } action: { store.toggleSunset() }
        }
    }

    static func remaining(until deadline: Date, now: Date) -> String {
        let minutes = max(Int((deadline.timeIntervalSince(now) / 60).rounded(.up)), 0)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

struct ModeTile<Value: View>: View {
    let icon: String
    let key: String
    let active: Bool
    let help: String
    var enabled = true
    @ViewBuilder let value: () -> Value
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(Color(hex: 0xC9C4BC))
                    .padding(.bottom, 6)
                Text(key).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                value().font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Palette.tile))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line))
            .overlay(alignment: .topTrailing) {
                Circle().fill(active ? Palette.warm : Color(hex: 0x3A3B3E)).frame(width: 6, height: 6).padding(14)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
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
    }

    private var statusColor: Color {
        store.unavailableCount > 0 ? Palette.alert : Color(hex: 0x3A3B3E)
    }

    private var text: String {
        if store.isSyncing { return "Syncing…" }
        guard store.lastSync != nil else { return "Connecting…" }
        let missing = store.unavailableCount
        return missing > 0 ? "\(missing) not answering" : "In sync"
    }
}
