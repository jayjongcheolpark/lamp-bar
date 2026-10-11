import AppKit
import SceneKit
import SwiftUI

struct LampBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LampStore()

    var body: some Scene {
        MenuBarExtra {
            PanelContent()
                .environmentObject(store)
        } label: {
            Image(systemName: store.anyOn ? "lightbulb.fill" : "lightbulb")
                .accessibilityLabel(store.anyOn ? "Lamp Bar, \(store.onCount) lamps on" : "Lamp Bar, all lamps off")
        }
        .menuBarExtraStyle(.window)

        Window("Lamp Bar Setup", id: "setup") {
            SetupView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        // Opened from the panel only, never at launch.
        .defaultLaunchBehavior(.suppressed)

        // `--window`: the panel in a normal window, for screenshots and testing.
        Window("Lamp Bar", id: "panel") {
            PanelContent()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(AppDelegate.showPanelWindow ? .presented : .suppressed)
    }
}

/// The panel, wired to open Setup and to tell the store while it is visible.
struct PanelContent: View {
    @EnvironmentObject var store: LampStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PanelView {
            openWindow(id: "setup")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onAppear { store.isPanelOpen = true }
        .onDisappear { store.isPanelOpen = false }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `--snapshot <file.png>`: show the panel window, save a picture of it after the first poll, and quit.
    static let snapshotPath: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    static let showPanelWindow = CommandLine.arguments.contains("--window") || snapshotPath != nil
    /// `--drag dx,dy` (points, y down) with `--snapshot`: drag on the 3D stage first, with real mouse events.
    /// `--reset` then double-clicks empty space on the stage.
    static let snapshotDrag: CGSize? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--drag"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, unless the panel is shown as a window.
        NSApp.setActivationPolicy(Self.showPanelWindow ? .regular : .accessory)
        if let path = Self.snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let stage = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(Self.stageView) }).first else { return }
                if let drag = Self.snapshotDrag { Self.drag(stage, by: drag) }
                if CommandLine.arguments.contains("--reset") { Self.doubleClickEmptySpace(stage) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                Self.snapshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    private static func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.title == "Lamp Bar" })?.contentView,
              let panel = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let out = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: panel)
        // The SceneKit view renders with Metal, which display caching does not capture:
        // draw its own snapshot first, then the rest of the panel (drawn without its background) over it.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        LampStage.background.setFill()
        view.bounds.fill()
        for scn in sceneViews(in: view) {
            var frame = scn.convert(scn.bounds, to: view)
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            scn.snapshot().draw(in: frame)
        }
        panel.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func stageView(in view: NSView) -> StageSCNView? {
        (view as? StageSCNView) ?? view.subviews.lazy.compactMap(stageView).first
    }

    private static func mouse(_ type: NSEvent.EventType, _ view: NSView, at point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private static func drag(_ view: StageSCNView, by delta: CGSize) {
        let start = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.mouseDown(with: mouse(.leftMouseDown, view, at: start))
        for step in 1...20 {
            let f = CGFloat(step) / 20
            // SwiftUI-style y (down) to AppKit y (up).
            let p = NSPoint(x: start.x + delta.width * f, y: start.y - delta.height * f)
            view.mouseDragged(with: mouse(.leftMouseDragged, view, at: p))
        }
        view.mouseUp(with: mouse(.leftMouseUp, view, at: NSPoint(x: start.x + delta.width, y: start.y - delta.height)))
    }

    private static func doubleClickEmptySpace(_ view: StageSCNView) {
        let corner = NSPoint(x: 8, y: 8)
        for clicks in 1...2 {
            view.mouseDown(with: mouse(.leftMouseDown, view, at: corner, clicks: clicks))
            view.mouseUp(with: mouse(.leftMouseUp, view, at: corner, clicks: clicks))
        }
    }

    private static func sceneViews(in view: NSView) -> [SCNView] {
        (view as? SCNView).map { [$0] } ?? view.subviews.flatMap(sceneViews)
    }
}
