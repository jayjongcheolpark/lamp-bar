import AppKit
import SceneKit

/// The five lamps standing on a dark plate at their places in the office, ported from the reference prototype (three.js).
/// Nothing else is modeled: no walls, no furniture. Units are meters: x east, y up, z south, origin at the office center.
final class LampStage {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private(set) var lamps: [LampID: Rig] = [:]
    private var levels: [LampID: CGFloat] = [:]
    private let fill = SCNLight()

    /// Camera orbit, in radians; dragging turns it within these limits.
    var azimuth: CGFloat = 0.03
    var elevation: CGFloat = 0.5
    static let azimuthRange: ClosedRange<CGFloat> = -0.9...0.9
    static let elevationRange: ClosedRange<CGFloat> = 0.25...1.25
    private static let target = SCNVector3(0, 0.55, 0.05)
    private static let distance: CGFloat = 5.0

    static let background = NSColor(hex: 0x050506)
    static let warm = NSColor(hex: 0xFFC27A)
    static let cool = NSColor(hex: 0xF0F4FF)
    /// Lamps are modeled at real size, then shown larger so they read on a small stage.
    private static let modelScale: CGFloat = 1.45
    /// Converts the prototype's three.js light intensity to SceneKit lumens.
    private static let lumens: CGFloat = 12
    /// Glass and fabric go dull grey when off, and take their own color when on.
    private static let offColor = NSColor(hex: 0x3B3A38)

    /// The parts of one lamp that change when it switches.
    struct Rig {
        let glowing: [SCNMaterial]
        let light: SCNLight
        let halo: SCNNode
        let pool: SCNNode
        /// Middle of the lamp, for picking it when a click misses its thin parts.
        let pickPoint: SCNVector3
    }

    init() {
        scene.background.contents = Self.background
        scene.lightingEnvironment.intensity = 0

        let camera = SCNCamera()
        // three.js measures the field of view vertically; say so, or SceneKit may use the wider axis.
        camera.projectionDirection = .vertical
        camera.fieldOfView = 30
        camera.zNear = 0.1
        camera.zFar = 50
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.3
        camera.bloomThreshold = 1
        camera.bloomBlurRadius = 5
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        placeCamera()

        // Soft room fill, like the prototype's hemisphere light; it rises with the number of lamps on.
        fill.type = .ambient
        fill.color = NSColor(hex: 0xB0B4BC)
        fill.intensity = Self.fillIntensity(total: 0)
        scene.rootNode.addChildNode(SCNNode(light: fill))
        // A weak key light from the upper left gives the lamps their shape and shadows.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 330
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowColor = NSColor.black.withAlphaComponent(0.6)
        key.shadowRadius = 6
        key.shadowSampleCount = 8
        let keyNode = SCNNode(light: key)
        keyNode.position = SCNVector3(-2, 5, 4)
        keyNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        buildPlate()
        for lamp in Lamp.all { lamps[lamp.id] = buildLamp(lamp) }
    }

    func placeCamera() {
        let t = Self.target, d = Self.distance
        cameraNode.position = SCNVector3(t.x + d * sin(azimuth) * cos(elevation), t.y + d * sin(elevation), t.z + d * cos(azimuth) * cos(elevation))
        cameraNode.look(at: t)
    }

    /// Shows a lamp on or off. `level` is 0...1; the Govee bar uses its brightness.
    /// Switching on flares briefly past full brightness, so the change is easy to see.
    func show(_ id: LampID, level: CGFloat, color: NSColor, animated: Bool) {
        guard let rig = lamps[id] else { return }
        let wasOff = (levels[id] ?? 0) == 0
        levels[id] = level
        let total = levels.values.reduce(0, +)
        guard animated, wasOff, level > 0 else {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.6 : 0
            apply(rig, level: level, color: color)
            fill.intensity = Self.fillIntensity(total: total)
            SCNTransaction.commit()
            return
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        apply(rig, level: min(level + 0.6, 1.4), color: color)
        fill.intensity = Self.fillIntensity(total: total)
        SCNTransaction.completionBlock = { [weak self] in
            guard let self, self.levels[id] == level else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.7
            self.apply(rig, level: level, color: color)
            SCNTransaction.commit()
        }
        SCNTransaction.commit()
    }

    /// `level` may go past 1 during the switch-on flare.
    private func apply(_ rig: Rig, level: CGFloat, color: NSColor) {
        let body = min(level, 1)
        for material in rig.glowing {
            let fabric = material.name == "fabric"
            let lit = fabric ? NSColor(hex: 0xEFE4CF) : NSColor(hex: 0xF6F2EA)
            material.diffuse.contents = Self.offColor.blended(withFraction: body, of: lit) ?? lit
            material.emission.contents = color
            material.emission.intensity = level * (fabric ? 2.2 : 3.2)
        }
        rig.light.color = color
        rig.light.intensity = level * 2.2 * Self.lumens
        rig.halo.geometry?.firstMaterial?.multiply.contents = color
        rig.halo.opacity = body * 0.95
        let haloScale = 0.6 + 0.6 * level
        rig.halo.scale = SCNVector3(haloScale, haloScale, haloScale)
        rig.pool.geometry?.firstMaterial?.multiply.contents = color
        rig.pool.opacity = body * 0.42
    }

    private static func fillIntensity(total: CGFloat) -> CGFloat { (0.12 + 0.05 * total) * 460 }

    /// The lamp that owns a node hit by a click, if any.
    static func lampID(of node: SCNNode) -> LampID? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, let id = LampID(rawValue: name) { return id }
            current = n.parent
        }
        return nil
    }

    // MARK: Plate

    /// The office footprint as a soft dark slab with rounded corners.
    private func buildPlate() {
        let w: CGFloat = 3.3, d: CGFloat = 2.2
        let outline = NSBezierPath(roundedRect: NSRect(x: -w / 2, y: -d / 2, width: w, height: d), xRadius: 0.35, yRadius: 0.35)
        outline.flatness = 0.005
        let slab = SCNShape(path: outline, extrusionDepth: 0.1)
        slab.chamferRadius = 0.02
        let top = material(NSColor(hex: 0x141517), roughness: 0.95)
        let body = material(NSColor(hex: 0x1A1B1D), roughness: 0.35, metalness: 0.2)
        // Shape faces: front, back, sides, front chamfer, back chamfer. The front face becomes the top.
        slab.materials = [top, body, body, body, body]
        let node = SCNNode(geometry: slab)
        node.eulerAngles.x = -.pi / 2
        node.position.y = -0.03
        scene.rootNode.addChildNode(node)
    }

    // MARK: Lamps

    private func buildLamp(_ lamp: Lamp) -> Rig {
        let group = SCNNode()
        group.name = lamp.id.rawValue
        group.position = SCNVector3(lamp.x, 0.021, lamp.z)
        group.scale = SCNVector3(Self.modelScale, Self.modelScale, Self.modelScale)
        scene.rootNode.addChildNode(group)

        let tone = lamp.tone == .cool ? Self.cool : Self.warm
        let glass = material(Self.offColor, roughness: 0.3)
        glass.transparency = 0.96
        glass.isDoubleSided = true
        var glowing = [glass]
        let graphite = material(NSColor(hex: 0x1C1D20), roughness: 0.35, metalness: 0.5)
        // Face the room's center, for the lamps that point somewhere.
        let towardCenter = atan2(-lamp.x, -lamp.z)
        let bulb: SCNVector3

        switch lamp.id {
        case .l1:
            // Donut lamp: a puffy glass ring lying on the shelf, tipped up a little toward the room (photos 1 and 1-donut-side).
            let tilt = SCNNode()
            tilt.position = SCNVector3(0, 0.075, 0)
            tilt.eulerAngles = SCNVector3(0.18, towardCenter + .pi, 0)
            group.addChildNode(tilt)
            let ring = add(SCNTorus(ringRadius: 0.14, pipeRadius: 0.075), glass, 0, 0, 0, in: tilt)
            ring.scale.y = 0.8
            bulb = SCNVector3(0, 0.1, 0)
        case .l2:
            // Govee light bar: a thin glowing bar on a round foot.
            add(SCNCylinder(radius: 0.105, height: 0.025), graphite, 0, 0.012, 0, in: group)
            add(SCNBox(width: 0.028, height: 1.25, length: 0.028, chamferRadius: 0.004), glass, 0, 0.66, 0, in: group)
            bulb = SCNVector3(0, 0.7, 0)
        case .l3:
            // Mushroom lamp: a glass dome on a glass stem.
            add(Self.dome(radius: 0.1), glass, 0, 0.15, 0, in: group)
            add(SCNCone(topRadius: 0.06, bottomRadius: 0.07, height: 0.15), glass, 0, 0.075, 0, in: group)
            bulb = SCNVector3(0, 0.15, 0)
        case .l4:
            // Task floor lamp (photo 4): heavy round foot, straight pole, then a zig-zag of two arms,
            // first back and up, then forward and up, ending in a black cone shade aimed down at the balcony window (west, -x).
            let metal = material(NSColor(hex: 0x1C1D20), roughness: 0.32, metalness: 0.55)
            let joint = material(NSColor(hex: 0x5B5E63), roughness: 0.3, metalness: 0.8)
            add(SCNCone(topRadius: 0.15, bottomRadius: 0.16, height: 0.035), metal, 0, 0.018, 0, in: group)
            let p0 = SIMD3<Float>(0, 0.03, 0), j1 = SIMD3<Float>(0, 0.72, 0), j2 = SIMD3<Float>(0.26, 1.08, 0), j3 = SIMD3<Float>(-0.12, 1.3, 0)
            segment(from: p0, to: j1, radius: 0.011, metal, in: group)
            segment(from: j1, to: j2, radius: 0.009, metal, in: group)
            segment(from: j2, to: j3, radius: 0.009, metal, in: group)
            add(SCNSphere(radius: 0.02), joint, CGFloat(j1.x), CGFloat(j1.y), CGFloat(j1.z), in: group)
            add(SCNSphere(radius: 0.018), joint, CGFloat(j2.x), CGFloat(j2.y), CGFloat(j2.z), in: group)
            let head = SCNNode()
            head.simdPosition = j3
            // The shade opens forward and down toward the window.
            head.eulerAngles.z = 2.2
            group.addChildNode(head)
            let shade = material(NSColor(hex: 0x1C1D20), roughness: 0.4, metalness: 0.35)
            shade.isDoubleSided = true
            add(Self.tube(top: 0.095, bottom: 0.035, height: 0.17), shade, 0, 0.085, 0, in: head)
            add(SCNCylinder(radius: 0.035, height: 0.05), metal, 0, -0.01, 0, in: head)
            add(SCNSphere(radius: 0.032), glass, 0, 0.12, 0, in: head)
            bulb = SCNVector3(-0.22, 1.22, 0)
        case .l5:
            // Brass table lamp with a fabric shade.
            let brass = material(NSColor(hex: 0xB69250), roughness: 0.28, metalness: 0.85)
            add(SCNCone(topRadius: 0.06, bottomRadius: 0.07, height: 0.02), brass, 0, 0.01, 0, in: group)
            add(SCNCone(topRadius: 0.018, bottomRadius: 0.03, height: 0.13), brass, 0, 0.085, 0, in: group)
            add(SCNSphere(radius: 0.04), brass, 0, 0.17, 0, in: group)
            add(SCNCone(topRadius: 0.012, bottomRadius: 0.016, height: 0.08), brass, 0, 0.23, 0, in: group)
            let fabric = material(Self.offColor, roughness: 0.3)
            fabric.name = "fabric"
            fabric.transparency = 0.96
            fabric.isDoubleSided = true
            glowing.append(fabric)
            add(Self.tube(top: 0.1, bottom: 0.145, height: 0.18), fabric, 0, 0.33, 0, in: group)
            bulb = SCNVector3(0, 0.31, 0)
        }
        for material in glowing { material.emission.intensity = 0 }

        let light = SCNLight()
        light.type = .omni
        light.color = tone
        light.intensity = 0
        light.attenuationStartDistance = 0
        light.attenuationEndDistance = 3.2
        light.attenuationFalloffExponent = 2
        let lightNode = SCNNode(light: light)
        lightNode.position = bulb
        group.addChildNode(lightNode)

        let size: CGFloat = lamp.isGovee ? 0.7 : 0.5
        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = Self.haloImage
        haloMaterial.multiply.contents = tone
        haloMaterial.blendMode = .add
        haloMaterial.writesToDepthBuffer = false
        let plane = SCNPlane(width: size, height: size)
        plane.materials = [haloMaterial]
        let halo = SCNNode(geometry: plane)
        halo.position = bulb
        halo.opacity = 0
        halo.castsShadow = false
        halo.constraints = [SCNBillboardConstraint()]
        // The halo glows but is not something to click.
        halo.categoryBitMask = 2
        group.addChildNode(halo)

        // A pool of light on the plate under the lamp; the task lamp throws it west, where its shade points.
        let poolMaterial = SCNMaterial()
        poolMaterial.lightingModel = .constant
        poolMaterial.diffuse.contents = Self.poolImage
        poolMaterial.multiply.contents = tone
        poolMaterial.blendMode = .add
        poolMaterial.writesToDepthBuffer = false
        let poolSize: CGFloat = lamp.isGovee ? 1.5 : lamp.id == .l4 ? 1.3 : 1.1
        let pool = SCNNode(geometry: SCNPlane(width: poolSize, height: poolSize))
        pool.geometry?.materials = [poolMaterial]
        pool.eulerAngles.x = -.pi / 2
        pool.position = SCNVector3(lamp.x + (lamp.id == .l4 ? -0.6 : 0), 0.024, lamp.z)
        pool.opacity = 0
        pool.castsShadow = false
        pool.categoryBitMask = 2
        scene.rootNode.addChildNode(pool)

        let worldBulbY = (bulb.y + 0.12) * Self.modelScale
        return Rig(
            glowing: glowing, light: light, halo: halo, pool: pool,
            pickPoint: SCNVector3(lamp.x, worldBulbY * 0.6, lamp.z)
        )
    }

    // MARK: Geometry helpers

    @discardableResult
    private func add(_ geometry: SCNGeometry, _ material: SCNMaterial, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat, in parent: SCNNode) -> SCNNode {
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(x, y, z)
        parent.addChildNode(node)
        return node
    }

    /// A rod between two points.
    private func segment(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat, _ material: SCNMaterial, in parent: SCNNode) {
        let node = add(SCNCylinder(radius: radius, height: CGFloat(simd_distance(a, b))), material, 0, 0, 0, in: parent)
        node.simdPosition = (a + b) / 2
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
    }

    private func material(_ color: NSColor, roughness: CGFloat, metalness: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        return m
    }

    /// Upper half of a sphere, open at the bottom.
    static func dome(radius r: CGFloat) -> SCNGeometry {
        lathe((0...12).map { i in
            let a = CGFloat(i) / 12 * .pi / 2
            return (r * sin(a), r * cos(a))
        })
    }

    /// An open tube or lampshade, centered on its height.
    static func tube(top: CGFloat, bottom: CGFloat, height: CGFloat) -> SCNGeometry {
        lathe([(top, height / 2), (bottom, -height / 2)])
    }

    /// A surface of revolution around the y axis from (radius, height) points, open at both ends.
    static func lathe(_ profile: [(CGFloat, CGFloat)], segments: Int = 48) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        for (i, (r, y)) in profile.enumerated() {
            let prev = profile[max(i - 1, 0)], next = profile[min(i + 1, profile.count - 1)]
            let dr = next.0 - prev.0, dy = next.1 - prev.1
            let length = max(hypot(dr, dy), 0.0001)
            // Outward normal of the profile line.
            let nr = -dy / length, ny = dr / length
            for s in 0...segments {
                let a = CGFloat(s) / CGFloat(segments) * 2 * .pi
                vertices.append(SCNVector3(r * cos(a), y, r * sin(a)))
                normals.append(SCNVector3(nr * cos(a), ny, nr * sin(a)))
            }
        }
        let ring = segments + 1
        for i in 0..<(profile.count - 1) {
            for s in 0..<segments {
                let a = Int32(i * ring + s), b = a + 1, c = a + Int32(ring), d = c + 1
                indices += [a, b, c, b, d, c]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// Radial falloffs, white in the middle to black at the edge; they are added onto the scene.
    static let haloImage = radial(stops: [(0.95, 0), (0.35, 0.22)])
    static let poolImage = radial(stops: [(0.9, 0), (0.3, 0.4)])

    private static func radial(stops: [(white: CGFloat, at: CGFloat)]) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            let gradient = NSGradient(colors: stops.map { NSColor(white: $0.white, alpha: 1) } + [.black],
                                      atLocations: stops.map(\.at) + [1], colorSpace: .sRGB)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            gradient?.draw(fromCenter: center, radius: 0, toCenter: center, radius: rect.width / 2, options: [])
            return true
        }
    }
}

extension SCNNode {
    convenience init(light: SCNLight) {
        self.init()
        self.light = light
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    convenience init(rgb: RGB) {
        self.init(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
