import Foundation

/// Command-line actions, for checking the lamps from Terminal without opening the panel.
///
///     LampBar --probe                      list the plugs and the light bar on the network (changes nothing)
///     LampBar --status                     show the five lamps as the app sees them
///     LampBar --map <1-5> <plug id|none>   choose the plug for a lamp (the plug ids come from --probe)
///     LampBar --switch <1-5|all> <on|off>  switch lamps
enum CommandLineTool {
    static let flags: Set<String> = ["--probe", "--status", "--map", "--switch"]

    static func handles(_ args: [String]) -> Bool { args.dropFirst().first.map(flags.contains) ?? false }

    @MainActor
    static func run(_ args: [String]) async {
        let rest = Array(args.dropFirst(2))
        switch args[1] {
        case "--probe":
            await probe()
            return
        case "--status":
            break
        case "--map":
            guard rest.count == 2, let lamp = lamp(rest[0]), !lamp.isGovee else { return usage("--map <1, 3, 4 or 5> <plug id|none>") }
            let store = LampStore()
            await store.refresh()
            store.map(lamp.id, to: rest[1] == "none" ? nil : rest[1])
        case "--switch":
            guard rest.count == 2, rest[1] == "on" || rest[1] == "off" else { return usage("--switch <1-5|all> <on|off>") }
            let ids: Set<LampID> = rest[0] == "all" ? Set(LampID.allCases) : Set([lamp(rest[0])?.id].compactMap { $0 })
            guard !ids.isEmpty else { return usage("--switch <1-5|all> <on|off>") }
            let store = LampStore()
            await store.refresh()
            await store.send(ids, on: rest[1] == "on")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        default:
            return
        }
        let store = LampStore()
        await store.refresh()
        printStatus(store)
    }

    @MainActor
    private static func printStatus(_ store: LampStore) {
        for lamp in Lamp.all {
            let state = store.state(lamp.id)
            var line = "  \(lamp.number) \(lamp.name.padding(toLength: 17, withPad: " ", startingAt: 0))"
            switch state.availability {
            case .available: line += state.isOn ? "on" : "off"
            case .notMapped: line += "no plug chosen"
            case let .unavailable(reason): line += "unavailable (\(reason))"
            case .unknown: line += "unknown"
            }
            if let outlet = store.outlet(for: lamp.id) { line += "   plug: \(outlet.label) [\(outlet.id)]" }
            if lamp.isGovee, let govee = store.govee {
                line += "   brightness \(govee.brightness)%, color \(govee.kelvin > 0 ? "\(govee.kelvin) K" : "\(govee.color.r),\(govee.color.g),\(govee.color.b)")"
            }
            print(line)
        }
        if let problem = store.goveeProblem { print("  Govee: \(problem) Turn on LAN Control in the Govee Home app.") }
    }

    private static func probe() async {
        print("Kasa outlets (legacy protocol, UDP 9999):")
        for outlet in KasaClient().discover() {
            print("  \(outlet.id)  \(outlet.host)  \(outlet.model)  \"\(outlet.alias)\"  \(outlet.isOn ? "on" : "off")")
        }
        print("Govee devices (LAN API):")
        let govee = GoveeClient()
        for device in await govee.scan() {
            let status = await govee.status(device)
            print("  \(device.id)  \(device.sku)  \(device.host)  \(status.map { "\($0)" } ?? "no devStatus reply")")
        }
    }

    private static func lamp(_ text: String) -> Lamp? {
        Int(text).flatMap { n in Lamp.all.first { $0.number == n } }
    }

    private static func usage(_ text: String) {
        FileHandle.standardError.write("usage: LampBar \(text)\n".data(using: .utf8)!)
    }
}
