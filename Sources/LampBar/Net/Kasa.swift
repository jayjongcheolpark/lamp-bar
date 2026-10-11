import Darwin
import Foundation

/// One switchable Kasa outlet: a single plug, or one socket of a power strip.
struct KasaOutlet: Identifiable, Hashable, Codable, Sendable {
    /// Stable key used for the lamp mapping: the device id, plus the child id for a strip socket.
    var id: String { childID.map { "\(deviceID)/\($0)" } ?? deviceID }
    var deviceID: String
    var childID: String?
    var host: String
    var alias: String
    var deviceAlias: String
    var model: String
    var isOn: Bool
    /// Where the plug is, as set in the Kasa app; used for the sunset time.
    var latitude: Double?
    var longitude: Double?
    /// True for plugs that need a TP-Link login; the app controls them through `KasaHelper`.
    var viaHelper = false

    var label: String { childID == nil ? alias : "\(alias) · \(deviceAlias)" }
}

/// Kasa "legacy" local protocol: JSON obfuscated with an autokey XOR cipher,
/// on UDP 9999 for discovery and TCP 9999 (4-byte length prefix) for commands.
/// Plugs with newer firmware that need a TP-Link login use `KasaHelper` instead.
enum KasaXOR {
    static func encrypt(_ text: String) -> Data {
        var key: UInt8 = 171
        return Data(text.utf8.map { byte in
            key ^= byte
            return key
        })
    }

    static func decrypt(_ data: Data) -> String {
        var key: UInt8 = 171
        let plain = data.map { byte -> UInt8 in
            defer { key = byte }
            return key ^ byte
        }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Parses a `get_sysinfo` reply into its outlets. A power strip yields one outlet per socket.
    static func outlets(fromSysinfo json: String, host: String) -> [KasaOutlet] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let info = (root["system"] as? [String: Any])?["get_sysinfo"] as? [String: Any],
              let deviceID = info["deviceId"] as? String
        else { return [] }
        let alias = info["alias"] as? String ?? "Kasa plug"
        let model = info["model"] as? String ?? ""
        let (latitude, longitude) = location(info)
        if let children = info["children"] as? [[String: Any]], !children.isEmpty {
            return children.compactMap { child in
                guard let rawID = child["id"] as? String else { return nil }
                // Some firmware reports "00", some reports the full "<deviceId>00".
                let childID = rawID.hasPrefix(deviceID) ? String(rawID.dropFirst(deviceID.count)) : rawID
                return KasaOutlet(
                    deviceID: deviceID, childID: childID, host: host,
                    alias: child["alias"] as? String ?? "Socket \(childID)",
                    deviceAlias: alias, model: model,
                    isOn: (child["state"] as? Int ?? 0) == 1,
                    latitude: latitude, longitude: longitude
                )
            }
        }
        return [KasaOutlet(
            deviceID: deviceID, childID: nil, host: host, alias: alias, deviceAlias: alias, model: model,
            isOn: (info["relay_state"] as? Int ?? 0) == 1,
            latitude: latitude, longitude: longitude
        )]
    }

    /// Plugs report their location as `latitude_i`/`longitude_i` (degrees x 10 000) or, on older firmware, as degrees.
    /// A plug that was never given a location reports an out-of-range value.
    static func location(_ info: [String: Any]) -> (Double?, Double?) {
        func degrees(_ key: String) -> Double? {
            if let scaled = info["\(key)_i"] as? Int { return Double(scaled) / 10_000 }
            return info[key] as? Double
        }
        guard let lat = degrees("latitude"), let lon = degrees("longitude"),
              abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return (nil, nil) }
        return (lat, lon)
    }

    static func setRelayCommand(on: Bool, deviceID: String, childID: String?) -> String {
        let state = on ? 1 : 0
        if let childID {
            return #"{"context":{"child_ids":["\#(deviceID)\#(childID)"]},"system":{"set_relay_state":{"state":\#(state)}}}"#
        }
        return #"{"system":{"set_relay_state":{"state":\#(state)}}}"#
    }

    static let sysinfoQuery = #"{"system":{"get_sysinfo":{}}}"#
}

enum KasaError: Error, CustomStringConvertible {
    case badReply(String)

    var description: String {
        switch self {
        case let .badReply(text): return "unexpected reply: \(text.prefix(120))"
        }
    }
}

/// Talks to legacy-protocol Kasa plugs. Every call blocks, so callers use it from a background task.
struct KasaClient: Sendable {
    var timeout: Double = 3

    /// Broadcasts `get_sysinfo` (and also asks each known host directly) and collects every reply.
    /// The reply carries the relay state, so one call both discovers plugs and reads their state.
    func discover(knownHosts: [String] = [], window: Double = 1.5) -> [KasaOutlet] {
        guard let fd = try? Sockets.udp() else { return [] }
        defer { close(fd) }
        let query = KasaXOR.encrypt(KasaXOR.sysinfoQuery)
        let targets = Set(Network.broadcastAddresses() + ["255.255.255.255"] + knownHosts)
        var byKey: [String: KasaOutlet] = [:]
        // UDP can drop a packet, so send the probe twice.
        for _ in 0..<2 {
            for host in targets { try? Sockets.send(fd, query, to: host, port: 9999) }
            Sockets.receive(fd, until: Date().addingTimeInterval(window / 2)) { data, host in
                for outlet in KasaXOR.outlets(fromSysinfo: KasaXOR.decrypt(data), host: host) {
                    byKey[outlet.id] = outlet
                }
                return false
            }
        }
        return byKey.values.sorted { ($0.deviceAlias, $0.alias) < ($1.deviceAlias, $1.alias) }
    }

    /// Sends one JSON request over TCP 9999 and returns the decrypted reply.
    func request(_ json: String, host: String) throws -> String {
        let fd = try Sockets.tcpConnect(host, 9999, timeout: timeout)
        defer { close(fd) }
        let payload = KasaXOR.encrypt(json)
        var length = UInt32(payload.count).bigEndian
        try Sockets.writeAll(fd, Data(bytes: &length, count: 4) + payload)
        let header = try Sockets.readExactly(fd, 4)
        let size = header.reduce(0) { $0 << 8 | Int($1) }
        return KasaXOR.decrypt(try Sockets.readExactly(fd, size))
    }

    func setPower(_ on: Bool, outlet: KasaOutlet) throws {
        let reply = try request(KasaXOR.setRelayCommand(on: on, deviceID: outlet.deviceID, childID: outlet.childID), host: outlet.host)
        guard reply.contains(#""err_code":0"#) else { throw KasaError.badReply(reply) }
    }

    /// Reads the state of one device directly over TCP.
    func outlets(host: String) throws -> [KasaOutlet] {
        let reply = try request(KasaXOR.sysinfoQuery, host: host)
        let outlets = KasaXOR.outlets(fromSysinfo: reply, host: host)
        guard !outlets.isEmpty else { throw KasaError.badReply(reply) }
        return outlets
    }
}

enum Network {
    struct Interface {
        var address: String
        var broadcast: String
    }

    /// Active, non-loopback IPv4 interfaces that support broadcast.
    static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let broad = ifa.ifa_dstaddr
            else { continue }
            func host(_ p: UnsafeMutablePointer<sockaddr>) -> String {
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Sockets.hostString($0.pointee) }
            }
            result.append(Interface(address: host(addr), broadcast: host(broad)))
        }
        return result
    }

    static func broadcastAddresses() -> [String] { interfaces().map(\.broadcast) }
}
