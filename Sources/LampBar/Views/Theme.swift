import SwiftUI

/// Colors from the reference prototype. The panel has one dark look by design, like a car's control screen.
enum Palette {
    static let card = Color(hex: 0x050506)
    static let tile = Color(hex: 0x141517)
    static let tileHi = Color(hex: 0x1C1D20)
    static let line = Color(hex: 0x222428)
    static let selectedEdge = Color(hex: 0x3D3A35)
    static let fg = Color(hex: 0xF2F0EC)
    static let muted = Color(hex: 0x8D8A85)
    static let warm = Color(hex: 0xFFC98A)
    static let alert = Color(hex: 0xFF8A7A)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}
