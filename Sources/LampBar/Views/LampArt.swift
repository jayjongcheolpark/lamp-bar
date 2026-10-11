import SwiftUI

/// Side views of the five lamps, after the captain's photos (the prototype's 48 x 48 drawings).
/// The lit part glows when the lamp is on.
struct LampArt: View {
    let lamp: LampID
    let on: Bool
    /// The color of the light when on.
    let light: Color

    private static let litOff = Color(hex: 0x34373B)
    private static let base = Color(hex: 0x5A5E64)
    private static let baseFill = Color(hex: 0x3A3D41)
    private static let brass = Color(hex: 0x8A7650)

    var body: some View {
        Canvas { context, size in
            let s = size.width / 48
            context.scaleBy(x: s, y: s)
            let stroke = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            var lit = Path()
            switch lamp {
            case .l1: // donut glass table lamp
                lit.addEllipse(in: CGRect(x: 9, y: 25, width: 30, height: 16))
                glow(&context, lit, s)
                context.fill(Path(ellipseIn: CGRect(x: 19, y: 29, width: 10, height: 4)), with: .color(Palette.tile.opacity(0.55)))
                context.stroke(line([(11, 41), (37, 41)]), with: .color(Self.base), style: stroke)
            case .l2: // vertical light bar
                lit.addRoundedRect(in: CGRect(x: 22.5, y: 5, width: 3, height: 34), cornerSize: CGSize(width: 1.5, height: 1.5))
                glow(&context, lit, s)
                context.fill(Path(ellipseIn: CGRect(x: 17, y: 39.5, width: 14, height: 5)), with: .color(Self.baseFill))
            case .l3: // mushroom glass lamp
                lit.move(to: CGPoint(x: 14, y: 26))
                lit.addArc(center: CGPoint(x: 24, y: 26), radius: 10, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                lit.closeSubpath()
                lit.addRoundedRect(in: CGRect(x: 19, y: 26, width: 10, height: 12), cornerSize: CGSize(width: 3, height: 3))
                glow(&context, lit, s)
                context.stroke(line([(15, 41), (33, 41)]), with: .color(Self.base), style: stroke)
            case .l4: // task floor lamp: foot, pole, zig-zag arm, shade aimed down toward the window
                var arm = line([(17, 43), (29, 43)])
                arm.addLines([CGPoint(x: 23, y: 43), CGPoint(x: 23, y: 27), CGPoint(x: 30, y: 19), CGPoint(x: 19, y: 11)])
                context.stroke(arm, with: .color(Self.base), style: stroke)
                lit.addLines([CGPoint(x: 19, y: 11), CGPoint(x: 10, y: 16), CGPoint(x: 15, y: 23)])
                lit.closeSubpath()
                glow(&context, lit, s)
            case .l5: // brass table lamp with a fabric shade
                lit.addLines([CGPoint(x: 15, y: 8), CGPoint(x: 33, y: 8), CGPoint(x: 37, y: 23), CGPoint(x: 11, y: 23)])
                lit.closeSubpath()
                glow(&context, lit, s)
                var brass = line([(24, 23), (24, 27)])
                brass.move(to: CGPoint(x: 21, y: 28))
                brass.addCurve(to: CGPoint(x: 27, y: 28), control1: CGPoint(x: 21, y: 33), control2: CGPoint(x: 27, y: 33))
                brass.addLines([CGPoint(x: 22, y: 33), CGPoint(x: 26, y: 33), CGPoint(x: 27, y: 39), CGPoint(x: 21, y: 39)])
                brass.closeSubpath()
                context.stroke(brass, with: .color(Self.brass), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.stroke(line([(17, 41), (31, 41)]), with: .color(Self.base), style: stroke)
            }
        }
        .accessibilityHidden(true)
    }

    private func glow(_ context: inout GraphicsContext, _ path: Path, _ s: CGFloat) {
        guard on else {
            context.fill(path, with: .color(Self.litOff))
            return
        }
        var lit = context
        lit.addFilter(.shadow(color: light.opacity(0.95), radius: 7 / s))
        lit.fill(path, with: .color(light))
    }

    private func line(_ points: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        p.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        return p
    }
}
