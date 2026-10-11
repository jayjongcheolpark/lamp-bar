import Foundation

/// `LampBar --probe`: prints what the app can see on the local network, without changing anything.
enum Probe {
    static func run() async {
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
}
