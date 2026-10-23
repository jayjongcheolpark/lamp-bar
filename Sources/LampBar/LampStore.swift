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
    @Published var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            if isPanelOpen { startPolling() } else { pollTask?.cancel() }
        }
    }

    private let kasa = KasaClient()
    private let goveeClient = GoveeClient()
    /// One settings domain for the app bundle and the command line, so both see the same plug mapping.
    static let settings = UserDefaults(suiteName: "dev.lampbar.settings")!
    private let defaults = LampStore.settings
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Commands bump this, so a poll that started before a command cannot overwrite its result.
    private var generation = 0
    /// Polls can overlap (the panel closes and opens again during a poll), so the newest poll's result wins.
    private var refreshCount = 0
    private var appliedRefresh = 0

    init() {
        let stored = Self.settings.dictionary(forKey: "plugMapping") as? [String: String] ?? [:]
        mapping = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in LampID(rawValue: key).map { ($0, value) } })
        if let data = defaults.data(forKey: "goveeDevice") {
            goveeDevice = try? JSONDecoder().decode(GoveeDevice.self, from: data)
        }
        // Read the lamps once for the menu bar icon. After that, Lamp Bar polls only while the panel is open.
        refreshSoon()
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

    /// Refreshes now, then every 10 seconds until the panel closes.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
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
        refreshCount += 1
        let id = refreshCount
        async let kasaResult = discoverKasa()
        async let goveeResult = readGovee()
        let (found, (device, status)) = await (kasaResult, goveeResult)
        // A command started after this poll began; its own refresh brings the newer state.
        guard startGeneration == generation, id > appliedRefresh else { return }
        appliedRefresh = id
        apply(outlets: found)
        apply(goveeDevice: device, status: status)
        lastSync = Date()
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
        setLamps([id], on: !state(id).isOn)
    }

    /// The power button: if any lamp is on, switch all five off; otherwise switch all five on.
    func toggleOffice() {
        setLamps(Set(LampID.allCases), on: !anyOn)
    }

    func setLamps(_ ids: Set<LampID>, on: Bool) {
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
