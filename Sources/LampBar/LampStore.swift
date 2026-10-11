import Foundation
import SwiftUI

enum LampAvailability: Equatable {
    /// No poll has finished yet.
    case unknown
    /// Lamps 1, 3, 4 and 5 before the user maps them to a plug.
    case notMapped
    case available
    case unavailable(String)
}

struct LampState: Equatable {
    var isOn = false
    var availability = LampAvailability.unknown

    var isAvailable: Bool { availability == .available }
}

/// The app's single source of truth: lamp state read from the devices, the plug mapping, and the commands.
@MainActor
final class LampStore: ObservableObject {
    @Published private(set) var lamps: [LampID: LampState] = Dictionary(uniqueKeysWithValues: LampID.allCases.map { ($0, LampState()) })
    @Published private(set) var outlets: [KasaOutlet] = []
    @Published private(set) var mapping: [LampID: String]
    @Published private(set) var govee: GoveeStatus?
    @Published private(set) var goveeDevice: GoveeDevice?
    /// Set when the Govee bar does not answer on the LAN, which usually means LAN Control is off.
    @Published private(set) var goveeProblem: String?
    @Published private(set) var busy = 0
    @Published private(set) var lastSync: Date?
    @Published private(set) var hasLogin = Keychain.hasCredentials
    @Published private(set) var helperProblem: String?
    /// The lamp shown in the readout; clicking a lamp or a chip selects it.
    @Published var selected: LampID = .l1
    /// The scene last applied from the Scene tile; a manual change clears it.
    @Published private(set) var activeScene: LightScene?
    @Published private(set) var sleep = SleepTimer.off
    @Published private(set) var sleepDeadline: Date?
    @Published private(set) var sunsetEnabled: Bool
    @Published var isPanelOpen = false {
        didSet { if isPanelOpen && !oldValue { refreshSoon() } }
    }

    private let kasa = KasaClient()
    private let goveeClient = GoveeClient()
    private let defaults = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var goveeTask: Task<Void, Never>?
    /// Commands bump this, so a poll that started before a command cannot overwrite its result.
    private var generation = 0
    private var sleepTask: Task<Void, Never>?
    private var sunsetTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: "plugMapping") as? [String: String] ?? [:]
        mapping = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in LampID(rawValue: key).map { ($0, value) } })
        if let data = defaults.data(forKey: "goveeDevice") {
            goveeDevice = try? JSONDecoder().decode(GoveeDevice.self, from: data)
        }
        sunsetEnabled = UserDefaults.standard.bool(forKey: "sunsetEnabled")
        startPolling()
    }

    // MARK: Reading state

    var onCount: Int { lamps.values.filter(\.isOn).count }
    var anyOn: Bool { onCount > 0 }
    var isSyncing: Bool { busy > 0 }
    var needsMapping: Bool { Lamp.kasa.contains { mapping[$0.id] == nil } }

    func state(_ id: LampID) -> LampState { lamps[id] ?? LampState() }

    func outlet(for id: LampID) -> KasaOutlet? {
        guard let key = mapping[id] else { return nil }
        return outlets.first { $0.id == key }
    }

    func lamp(mappedTo outlet: KasaOutlet) -> LampID? {
        mapping.first { $0.value == outlet.id }?.key
    }

    var unavailableCount: Int {
        lamps.values.filter { if case .unavailable = $0.availability { return true } else { return false } }.count
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Poll lightly: often while the panel is open, rarely for the menu bar icon.
                let seconds: UInt64 = (self?.isPanelOpen ?? false) ? 10 : 60
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func refreshSoon(after delay: Double = 0) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        busy += 1
        defer { busy -= 1 }
        let startGeneration = generation
        async let kasaResult = discoverKasa()
        async let goveeResult = readGovee()
        let (found, (device, status)) = await (kasaResult, goveeResult)
        // A command started after this poll began; its own refresh brings the newer state.
        guard startGeneration == generation else { return }
        let hadLocation = location != nil
        apply(outlets: found)
        apply(goveeDevice: device, status: status)
        lastSync = Date()
        if !hadLocation && location != nil { scheduleSunset() }
    }

    private func discoverKasa() async -> [KasaOutlet] {
        let known = Array(Set(outlets.map(\.host)))
        let client = kasa
        var found = await Task.detached { client.discover(knownHosts: known) }.value
        if let login = Keychain.load(), KasaHelper.isInstalled {
            do {
                found += try await Task.detached { try KasaHelper().discover(login) }.value
                helperProblem = nil
            } catch {
                helperProblem = "\(error)"
            }
        }
        return found
    }

    private func readGovee() async -> (GoveeDevice?, GoveeStatus?) {
        if let device = goveeDevice, let status = await goveeClient.status(device) {
            return (device, status)
        }
        // Unknown or moved device: scan again (the bar may have a new address).
        for device in await goveeClient.scan() {
            if let status = await goveeClient.status(device) { return (device, status) }
        }
        return (goveeDevice, nil)
    }

    private func apply(outlets found: [KasaOutlet]) {
        // Keep plugs that missed this poll in the list so their mapping stays visible in Setup.
        var merged = Dictionary(uniqueKeysWithValues: outlets.map { ($0.id, $0) })
        for outlet in found { merged[outlet.id] = outlet }
        outlets = merged.values.sorted { ($0.deviceAlias, $0.alias) < ($1.deviceAlias, $1.alias) }
        let seen = Set(found.map(\.id))
        for lamp in Lamp.kasa {
            guard let key = mapping[lamp.id] else {
                lamps[lamp.id] = LampState(isOn: false, availability: .notMapped)
                continue
            }
            if seen.contains(key), let outlet = merged[key] {
                lamps[lamp.id] = LampState(isOn: outlet.isOn, availability: .available)
            } else {
                lamps[lamp.id] = LampState(isOn: false, availability: .unavailable("Plug did not answer"))
            }
        }
    }

    private func apply(goveeDevice device: GoveeDevice?, status: GoveeStatus?) {
        if let device, device != goveeDevice {
            goveeDevice = device
            defaults.set(try? JSONEncoder().encode(device), forKey: "goveeDevice")
        }
        govee = status
        if let status {
            lamps[.l2] = LampState(isOn: status.isOn, availability: .available)
            goveeProblem = nil
        } else {
            lamps[.l2] = LampState(isOn: false, availability: .unavailable("Light bar did not answer"))
            goveeProblem = device == nil
                ? "No Govee light bar answered on the local network."
                : "The Govee light bar at \(device!.host) did not answer."
        }
    }

    // MARK: Commands

    func toggle(_ id: LampID) {
        selected = id
        setLamps([id], on: !state(id).isOn)
    }

    /// The power button: if any lamp is on, switch all five off; otherwise switch all five on.
    func toggleOffice() {
        setLamps(Set(LampID.allCases), on: !anyOn)
    }

    /// The Scene tile: each click applies the next scene.
    func cycleScene() {
        let all = LightScene.allCases
        let next = activeScene.flatMap { all.firstIndex(of: $0) }.map { all[(all.index(after: $0)) % all.count] } ?? all[0]
        apply(next)
    }

    func apply(_ scene: LightScene) {
        let on = scene.lampsOn
        activeScene = scene
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.send(Set(LampID.allCases).subtracting(on), on: false) }
                group.addTask { await self.send(on, on: true) }
            }
        }
    }

    func setLamps(_ ids: Set<LampID>, on: Bool) {
        activeScene = nil
        Task { await send(ids, on: on) }
    }

    func send(_ ids: Set<LampID>, on: Bool) async {
        let targets = ids.filter { lamps[$0]?.availability != .notMapped }
        guard !targets.isEmpty else { return }
        generation += 1
        busy += 1
        defer { busy -= 1 }
        // Show the change at once; the refresh below confirms it from the devices.
        for id in targets { lamps[id]?.isOn = on }
        await withTaskGroup(of: (LampID, String?).self) { group in
            for id in targets {
                if id == .l2 {
                    guard let device = goveeDevice else { continue }
                    let client = goveeClient
                    group.addTask { (id, await Self.attempt { try await client.setPower(on, device) }) }
                } else if let outlet = outlet(for: id) {
                    let client = kasa
                    let login = outlet.viaHelper ? Keychain.load() : nil
                    group.addTask {
                        (id, await Self.attempt {
                            try await Task.detached {
                                if outlet.viaHelper {
                                    guard let login else { throw KasaHelper.HelperError.failed("no TP-Link login saved") }
                                    try KasaHelper().setPower(on, outlet: outlet, login)
                                } else {
                                    try client.setPower(on, outlet: outlet)
                                }
                            }.value
                        })
                    }
                }
            }
            for await (id, failure) in group {
                if let failure { lamps[id] = LampState(isOn: false, availability: .unavailable(failure)) }
            }
        }
        // The Govee bar applies a command a moment after it receives it.
        refreshSoon(after: targets.contains(.l2) ? 0.8 : 0.2)
    }

    nonisolated private static func attempt(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: Govee brightness and color

    func setGoveeBrightness(_ percent: Int) {
        guard let device = goveeDevice else { return }
        govee?.brightness = percent
        sendGovee(turnOn: !state(.l2).isOn) { try await $0.setBrightness(percent, device) }
    }

    func setGoveeColor(_ swatch: GoveeSwatch) {
        guard let device = goveeDevice else { return }
        govee?.color = swatch.rgb
        govee?.kelvin = swatch.kelvin ?? 0
        sendGovee(turnOn: !state(.l2).isOn) { client in
            if let kelvin = swatch.kelvin {
                try await client.setKelvin(kelvin, device)
            } else {
                try await client.setColor(swatch.rgb, device)
            }
        }
    }

    /// The Light bar color tile: each click sets the next color.
    func cycleGoveeColor() {
        let all = GoveeSwatch.all
        let current = govee.flatMap { status in all.firstIndex { $0.matches(status) } }
        setGoveeColor(all[current.map { ($0 + 1) % all.count } ?? 0])
    }

    var goveeSwatch: GoveeSwatch? {
        govee.flatMap { status in GoveeSwatch.all.first { $0.matches(status) } }
    }

    /// Changing brightness or color of a lamp that is off also switches it on, as in the prototype.
    private func sendGovee(turnOn: Bool, _ command: @escaping (GoveeClient) async throws -> Void) {
        guard let device = goveeDevice else { return }
        generation += 1
        activeScene = nil
        if turnOn { lamps[.l2]?.isOn = true }
        goveeTask?.cancel()
        let client = goveeClient
        goveeTask = Task {
            // Wait for the slider to settle before sending.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            busy += 1
            defer { busy -= 1 }
            if turnOn { try? await client.setPower(true, device) }
            try? await command(client)
            refreshSoon(after: 0.8)
        }
    }

    // MARK: Sleep timer and sunset

    /// The Sleep tile: each click picks the next duration; when it runs out, all five lamps switch off.
    func cycleSleep() {
        let all = SleepTimer.allCases
        sleep = all[(all.firstIndex(of: sleep)! + 1) % all.count]
        sleepTask?.cancel()
        guard let minutes = sleep.minutes else {
            sleepDeadline = nil
            return
        }
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepDeadline = deadline
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(deadline.timeIntervalSinceNow, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            sleep = .off
            sleepDeadline = nil
            apply(.allOff)
        }
    }

    /// Where the office is, from the location a Kasa plug reports (the Kasa app sets it). No location permission needed.
    var location: (latitude: Double, longitude: Double)? {
        outlets.lazy.compactMap { o in o.latitude.flatMap { lat in o.longitude.map { (lat, $0) } } }.first
    }

    /// Today's sunset, or tomorrow's once today's has passed.
    var nextSunset: Date? {
        guard let location else { return nil }
        let now = Date()
        for dayOffset in 0...1 {
            let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: now)!
            if let sunset = Sun.sunset(on: day, latitude: location.latitude, longitude: location.longitude), sunset > now {
                return sunset
            }
        }
        return nil
    }

    /// The At sunset tile: when on, the Evening scene starts at sunset every day while the app runs.
    func toggleSunset() {
        sunsetEnabled.toggle()
        defaults.set(sunsetEnabled, forKey: "sunsetEnabled")
        scheduleSunset()
    }

    private func scheduleSunset() {
        sunsetTask?.cancel()
        guard sunsetEnabled, let sunset = nextSunset else { return }
        sunsetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(sunset.timeIntervalSinceNow, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            apply(.evening)
            // Wait past this sunset before planning the next one.
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            scheduleSunset()
        }
    }

    // MARK: Setup

    func map(_ lamp: LampID, to outletID: String?) {
        if let outletID {
            // One plug drives one lamp.
            for (other, key) in mapping where key == outletID && other != lamp { mapping[other] = nil }
            mapping[lamp] = outletID
        } else {
            mapping[lamp] = nil
        }
        defaults.set(Dictionary(uniqueKeysWithValues: mapping.map { ($0.key.rawValue, $0.value) }), forKey: "plugMapping")
        apply(outlets: outlets)
        refreshSoon()
    }

    /// Switches a plug off and back on so the user can see which lamp it drives.
    func flash(_ outlet: KasaOutlet) {
        Task {
            busy += 1
            defer { busy -= 1 }
            let client = kasa
            let login = outlet.viaHelper ? Keychain.load() : nil
            let set: @Sendable (Bool) async -> Void = { on in
                _ = try? await Task.detached {
                    if outlet.viaHelper, let login { try KasaHelper().setPower(on, outlet: outlet, login) }
                    else { try client.setPower(on, outlet: outlet) }
                }.value
            }
            await set(!outlet.isOn)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await set(outlet.isOn)
            refreshSoon()
        }
    }

    func saveLogin(_ login: TPLinkCredentials) -> Bool {
        let saved = Keychain.save(login)
        hasLogin = Keychain.hasCredentials
        refreshSoon()
        return saved
    }

    func removeLogin() {
        Keychain.delete()
        hasLogin = false
        helperProblem = nil
    }

    func rescanGovee() {
        goveeDevice = nil
        defaults.removeObject(forKey: "goveeDevice")
        refreshSoon()
    }
}

enum SleepTimer: CaseIterable {
    case off, halfHour, hour, twoHours

    var minutes: Int? {
        switch self {
        case .off: return nil
        case .halfHour: return 30
        case .hour: return 60
        case .twoHours: return 120
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .halfHour: return "30 min"
        case .hour: return "1 h"
        case .twoHours: return "2 h"
        }
    }
}

/// The light bar colors offered in the panel, as in the prototype.
struct GoveeSwatch: Identifiable, Hashable {
    let name: String
    let rgb: RGB
    /// White swatches use the bar's white LEDs instead of mixing RGB.
    let kelvin: Int?

    var id: String { name }

    static let all: [GoveeSwatch] = [
        GoveeSwatch(name: "Warm", rgb: RGB(r: 255, g: 184, b: 102), kelvin: 2700),
        GoveeSwatch(name: "Daylight", rgb: RGB(r: 242, g: 245, b: 255), kelvin: 6500),
        GoveeSwatch(name: "Amber", rgb: RGB(r: 255, g: 122, b: 69), kelvin: nil),
        GoveeSwatch(name: "Violet", rgb: RGB(r: 143, g: 123, b: 255), kelvin: nil),
        GoveeSwatch(name: "Teal", rgb: RGB(r: 63, g: 208, b: 201), kelvin: nil),
    ]

    func matches(_ status: GoveeStatus) -> Bool {
        if let kelvin { return abs(status.kelvin - kelvin) < 300 }
        return status.kelvin == 0 && status.color == rgb
    }
}
