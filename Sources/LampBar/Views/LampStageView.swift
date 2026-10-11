import SceneKit
import SwiftUI

/// The 3D lamp stage: click a lamp to switch it and select it; drag to turn the view.
/// Lamp names are not drawn on the stage; they live in the readout and the chips.
struct LampStageView: NSViewRepresentable {
    @EnvironmentObject var store: LampStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> StageSCNView {
        let stage = context.coordinator.stage
        let view = StageSCNView(frame: .zero, options: nil)
        view.stage = stage
        view.scene = stage.scene
        view.pointOfView = stage.cameraNode
        view.backgroundColor = LampStage.background
        view.antialiasingMode = .multisampling4X
        // The view turns only through our own turntable drag, never SceneKit's free camera control.
        view.allowsCameraControl = false
        // Draw only when something changes, so the popover costs nothing while it sits still.
        view.rendersContinuously = false
        view.setAccessibilityLabel("Office lamps. Click a lamp to switch it; drag to turn the view.")
        view.onClick = { id in store.toggle(id) }
        context.coordinator.apply(store, animated: false)
        return view
    }

    func updateNSView(_ view: StageSCNView, context: Context) {
        view.onClick = { id in store.toggle(id) }
        context.coordinator.apply(store, animated: true)
    }

    final class Coordinator {
        let stage = LampStage()
        private var shown: [LampID: (CGFloat, NSColor)] = [:]

        @MainActor
        func apply(_ store: LampStore, animated: Bool) {
            for lamp in Lamp.all {
                let on = store.state(lamp.id).isOn
                var level: CGFloat = on ? 1 : 0
                var color = lamp.tone == .cool ? LampStage.cool : LampStage.warm
                if lamp.isGovee, let govee = store.govee {
                    color = NSColor(rgb: govee.displayColor)
                    if on { level = 0.2 + 0.8 * CGFloat(govee.brightness) / 100 }
                }
                if let previous = shown[lamp.id], previous.0 == level, previous.1 == color { continue }
                shown[lamp.id] = (level, color)
                stage.show(lamp.id, level: level, color: color, animated: animated)
            }
        }
    }
}

final class StageSCNView: SCNView {
    var stage: LampStage!
    var onClick: (LampID) -> Void = { _ in }
    private var dragStart: (point: NSPoint, azimuth: CGFloat, elevation: CGFloat)?
    private var dragged = false

    override func layout() {
        super.layout()
        if bounds.height > 0 { stage.fit(aspect: bounds.width / bounds.height) }
    }

    // Scrolling, pinching and rotating on the trackpad do not move the view.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = (convert(event.locationInWindow, from: nil), stage.azimuth, stage.elevation)
        dragged = false
        // On-demand drawing can miss the last camera move of a drag, so draw every frame until the pointer is up.
        keepDrawing(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - start.point.x
        // AppKit y grows upward. Dragging down looks more from above, so the plate tips toward the pointer.
        let dy = start.point.y - p.y
        if !dragged && abs(dx) + abs(dy) > 5 {
            dragged = true
            NSCursor.closedHand.push()
        }
        guard dragged else { return }
        // Angles follow the pointer's distance from where the drag started: no speed, no drift.
        stage.azimuth = (start.azimuth - dx * 0.006).clamped(to: LampStage.azimuthRange)
        stage.elevation = (start.elevation + dy * 0.005).clamped(to: LampStage.elevationRange)
        stage.placeCamera()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            if dragged { NSCursor.pop() }
            dragStart = nil
            dragged = false
            keepDrawing(false)
        }
        guard !dragged else { return }
        let lamp = pick(convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            // Double-click on empty space: back to the default view. A second click on a lamp does nothing more.
            if lamp == nil {
                keepDrawing(true)
                stage.resetView(animated: true)
                keepDrawing(false)
            }
            return
        }
        if let lamp { onClick(lamp) }
    }

    private var drawUntil = Date.distantPast

    /// Draws every frame while the camera moves, and a moment longer so the final frame lands; otherwise draws only on changes.
    private func keepDrawing(_ on: Bool) {
        if on {
            drawUntil = .distantFuture
            rendersContinuously = true
            return
        }
        let until = Date().addingTimeInterval(0.6)
        drawUntil = until
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.drawUntil == until else { return }
            self.rendersContinuously = false
        }
    }

    /// The lamp under the click, or else the nearest lamp on screen, so the small lamps are easy to hit.
    private func pick(_ point: NSPoint) -> LampID? {
        let hits = hitTest(point, options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.all.rawValue])
        if let id = hits.lazy.compactMap({ LampStage.lampID(of: $0.node) }).first { return id }
        var best: (LampID, CGFloat)?
        for (id, rig) in stage.lamps {
            let p = projectPoint(rig.pickPoint)
            let distance = hypot(CGFloat(p.x) - point.x, (CGFloat(p.y) - point.y) * 0.6)
            if distance < bounds.width * 0.09, distance < (best?.1 ?? .infinity) { best = (id, distance) }
        }
        return best?.0
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
