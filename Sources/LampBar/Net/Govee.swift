import Darwin
import Foundation

struct RGB: Hashable, Codable, Sendable {
    var r: Int
    var g: Int
    var b: Int

    /// Approximate color of a white color temperature, for drawing the glow.
    init(kelvin: Int) {
        let t = Double(kelvin) / 100
        let r = t <= 66 ? 255 : 329.7 * pow(t - 60, -0.1332)
        let g = t <= 66 ? 99.47 * log(t) - 161.12 : 288.12 * pow(t - 60, -0.0755)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.52 * log(t - 10) - 305.04)
        func clamp(_ v: Double) -> Int { Int(min(max(v, 0), 255)) }
        self.init(r: clamp(r), g: clamp(g), b: clamp(b))
    }

    init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }
}

struct GoveeDevice: Hashable, Codable, Sendable {
    var id: String
    var sku: String
    var host: String
}

struct GoveeStatus: Equatable, Sendable {
    var isOn: Bool
    var brightness: Int
    var color: RGB
    /// Nonzero when the lamp is in white mode.
    var kelvin: Int

    /// The color the lamp shows, for the glow and the tile.
    var displayColor: RGB { kelvin > 0 ? RGB(kelvin: kelvin) : color }
}

/// Govee LAN API: JSON over UDP. Scan goes to multicast 239.255.255.250:4001,
/// commands go to the device on 4003, and replies come back to port 4002.
/// Only `scan` and `devStatus` reply; other commands are confirmed by reading `devStatus` again.
actor GoveeClient {
    static let multicast = "239.255.255.250"
    var timeout: Double = 2

    func scan(window: Double = 3) -> [GoveeDevice] {
        let message = Self.message("scan", ["account_topic": "reserve"])
        var found: [String: GoveeDevice] = [:]
        exchange(send: { fd in
            // Send the scan out of every interface; the default route may not be the LAN.
            for interface in Network.interfaces() {
                var addr = in_addr()
                inet_pton(AF_INET, interface.address, &addr)
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
                try? Sockets.send(fd, message, to: Self.multicast, port: 4001)
            }
        }, window: window) { data, sender in
            guard let reply = Self.reply(data), reply.cmd == "scan",
                  let id = reply.data["device"] as? String else { return false }
            let host = reply.data["ip"] as? String ?? sender
            found[id] = GoveeDevice(id: id, sku: reply.data["sku"] as? String ?? "", host: host)
            return false
        }
        return Array(found.values)
    }

    func status(_ device: GoveeDevice) -> GoveeStatus? {
        let message = Self.message("devStatus", [:])
        var result: GoveeStatus?
        // UDP can drop a packet, so ask twice before giving up.
        for _ in 0..<2 where result == nil {
            exchange(send: { fd in
                try Sockets.send(fd, message, to: device.host, port: 4003)
            }, window: timeout / 2) { data, sender in
                guard sender == device.host, let reply = Self.reply(data), reply.cmd == "devStatus" else { return false }
                let color = reply.data["color"] as? [String: Any] ?? [:]
                result = GoveeStatus(
                    isOn: (reply.data["onOff"] as? Int ?? 0) == 1,
                    brightness: reply.data["brightness"] as? Int ?? 0,
                    color: RGB(r: color["r"] as? Int ?? 255, g: color["g"] as? Int ?? 255, b: color["b"] as? Int ?? 255),
                    kelvin: reply.data["colorTemInKelvin"] as? Int ?? 0
                )
                return true
            }
        }
        return result
    }

    func setPower(_ on: Bool, _ device: GoveeDevice) throws {
        try fire(Self.message("turn", ["value": on ? 1 : 0]), device)
    }

    private func fire(_ message: Data, _ device: GoveeDevice) throws {
        let fd = try Sockets.udp()
        defer { close(fd) }
        try Sockets.send(fd, message, to: device.host, port: 4003)
    }

    /// Binds the reply port 4002, sends, and hands every reply to `handle` until it returns true or the window ends.
    /// The actor runs one exchange at a time, so replies are not split between two listeners.
    private func exchange(send: (Int32) throws -> Void, window: Double, handle: (Data, String) -> Bool) {
        guard let listener = try? Sockets.udp(bindPort: 4002, reusePort: true) else { return }
        defer { close(listener) }
        guard (try? send(listener)) != nil else { return }
        Sockets.receive(listener, until: Date().addingTimeInterval(window), handle: handle)
    }

    static func message(_ cmd: String, _ data: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["msg": ["cmd": cmd, "data": data]])) ?? Data()
    }

    static func reply(_ data: Data) -> (cmd: String, data: [String: Any])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = root["msg"] as? [String: Any], let cmd = msg["cmd"] as? String else { return nil }
        return (cmd, msg["data"] as? [String: Any] ?? [:])
    }
}
