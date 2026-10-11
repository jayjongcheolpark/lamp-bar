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
    var elevation: CGFloat = 0.58
    static let azimuthRange: ClosedRange<CGFloat> = -0.9...0.9
    static let elevationRange: ClosedRange<CGFloat> = 0.25...1.25
    private static let target = SCNVector3(0, 0.28, 0.05)
    private static let distance: CGFloat = 4.6

    static let background = NSColor(hex: 0x050506)
    static let warm = NSColor(hex: 0xFFC27A)
    static let cool = NSColor(hex: 0xF0F4FF)
    /// Lamps are modeled at real size, then shown larger so they read on a small stage.
    private static let modelScale: CGFloat = 1.45
    /// Converts the prototype's three.js light intensity to SceneKit lumens.
    private static let lumens: CGFloat = 16
    /// Glass and fabric go dull grey when off, and take their own color when on.
    private static let offColor = NSColor(hex: 0x3B3A38)

    /// The parts of one lamp that change when it switches or is selected.
    struct Rig {
        let glowing: [SCNMaterial]
        let light: SCNLight
        let halo: SCNNode
        let pool: SCNNode
        let ring: SCNNode
        /// Middle of the lamp, for picking it when a click misses its thin parts.
        let pickPoint: SCNVector3
    }

    init() {
        scene.background.contents = Self.background
        scene.lightingEnvironment.intensity = 0

        let camera = SCNCamera()
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

    func select(_ id: LampID, animated: Bool) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.3 : 0
        for (lampID, rig) in lamps { rig.ring.opacity = lampID == id ? 0.75 : 0 }
        SCNTransaction.commit()
    }

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
            // Task floor lamp: a black stand with an arm and head that lean out toward the room (photo 4).
            add(SCNCone(topRadius: 0.13, bottomRadius: 0.14, height: 0.025), graphite, 0, 0.012, 0, in: group)
            add(SCNCylinder(radius: 0.01, height: 0.82), graphite, 0, 0.42, 0, in: group)
            let arm = SCNNode()
            arm.position = SCNVector3(0, 0.82, 0)
            arm.eulerAngles.y = towardCenter + 0.4 + .pi
            group.addChildNode(arm)
            add(SCNCylinder(radius: 0.008, height: 0.5), graphite, 0, 0.18, 0.17, in: arm).eulerAngles.x = 0.82
            let head = SCNNode()
            head.position = SCNVector3(0, 0.36, 0.34)
            head.eulerAngles.x = 0.9
            arm.addChildNode(head)
            let shade = material(NSColor(hex: 0x1C1D20), roughness: 0.4, metalness: 0.4)
            shade.isDoubleSided = true
            add(Self.tube(top: 0.03, bottom: 0.085, height: 0.15), shade, 0, 0, 0, in: head)
            let bulbNode = add(SCNSphere(radius: 0.03), glass, 0, -0.04, 0, in: head)
            bulb = group.convertPosition(bulbNode.convertPosition(SCNVector3Zero, to: nil), from: nil)
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

        // A pool of light on the plate under the lamp; the task lamp throws it forward, where its head points.
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
        pool.position = SCNVector3(lamp.x + (lamp.id == .l4 ? -0.15 : 0), 0.024, lamp.z + (lamp.id == .l4 ? 0.45 : 0))
        pool.opacity = 0
        pool.castsShadow = false
        pool.categoryBitMask = 2
        scene.rootNode.addChildNode(pool)

        // Selection ring on the plate around the lamp's foot.
        let ringMaterial = SCNMaterial()
        ringMaterial.lightingModel = .constant
        ringMaterial.diffuse.contents = NSColor(hex: 0xF3EFE8)
        ringMaterial.isDoubleSided = true
        let ring = SCNNode(geometry: Self.flatRing(inner: 0.2, outer: 0.225))
        ring.geometry?.materials = [ringMaterial]
        ring.position = SCNVector3(lamp.x, 0.025, lamp.z)
        ring.opacity = 0
        ring.castsShadow = false
        ring.categoryBitMask = 2
        scene.rootNode.addChildNode(ring)

        let worldBulbY = (bulb.y + 0.12) * Self.modelScale
        return Rig(
            glowing: glowing, light: light, halo: halo, pool: pool, ring: ring,
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

    /// A flat ring in the xz plane.
    static func flatRing(inner: CGFloat, outer: CGFloat, segments: Int = 64) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for s in 0...segments {
            let a = CGFloat(s) / CGFloat(segments) * 2 * .pi
            vertices.append(SCNVector3(inner * cos(a), 0, inner * sin(a)))
            vertices.append(SCNVector3(outer * cos(a), 0, outer * sin(a)))
        }
        for s in 0..<segments {
            let i = Int32(s * 2)
            indices += [i, i + 1, i + 2, i + 1, i + 3, i + 2]
        }
        let normals = Array(repeating: SCNVector3(0, 1, 0), count: vertices.count)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
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
