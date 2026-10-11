import CoreGraphics

enum LampID: String, CaseIterable, Codable, Identifiable {
    case l1, l2, l3, l4, l5
    var id: String { rawValue }
}

enum LampTone {
    case warm
    case cool
    /// Lamp 2: the glow takes the Govee bar's current color.
    case govee
}

/// One of the five office lamps, placed where the captain marked it on the floor plan.
/// Positions are in meters from the office center: x east, z south, as in the reference prototype.
struct Lamp: Identifiable {
    let id: LampID
    let number: Int
    let name: String
    /// What drives the lamp and where it stands, shown under the name.
    let source: String
    let x: CGFloat
    let z: CGFloat
    let tone: LampTone

    var isGovee: Bool { tone == .govee }

    static let all: [Lamp] = [
        Lamp(id: .l1, number: 1, name: "Donut lamp", source: "Kasa plug · desk shelf", x: 1.0, z: -0.7, tone: .warm),
        Lamp(id: .l2, number: 2, name: "Light bar", source: "Govee light bar", x: 1.2, z: 0.45, tone: .govee),
        Lamp(id: .l3, number: 3, name: "Mushroom lamp", source: "Kasa plug · shelf", x: 0.15, z: 0.75, tone: .warm),
        Lamp(id: .l4, number: 4, name: "Task floor lamp", source: "Kasa plug · work corner", x: -0.6, z: 0.7, tone: .cool),
        Lamp(id: .l5, number: 5, name: "Brass table lamp", source: "Kasa plug · balcony door", x: -1.3, z: -0.65, tone: .warm),
    ]

    static let kasa = all.filter { !$0.isGovee }

    static func with(_ id: LampID) -> Lamp { all.first { $0.id == id }! }
}
