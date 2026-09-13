import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor
func statusRing(remaining: Int?) -> NSImage {
    let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let track = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 13, height: 13))
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.lineWidth = 1.7; track.stroke()
        if let remaining, remaining > 0 {
            let arc = NSBezierPath()
            arc.lineWidth = 1.7; arc.lineCapStyle = .round
            arc.appendArc(withCenter: center, radius: 6.5, startAngle: 90,
                          endAngle: 90 - CGFloat(remaining) * 3.6, clockwise: true)
            NSColor.labelColor.setStroke(); arc.stroke()
        } else if remaining == nil {
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 7.3, y: 7.3, width: 2.4, height: 2.4)).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

@MainActor
final class QuotaFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let panel = QuotaFloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private let scrollView = NSScrollView()
    private var hostingView: NSHostingView<QuotaPanel>!
    private var updateQueued = false
    private var model: QuotaModel!
    private var subscriptions = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?
    private var demoBackdrop: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--render-preview"), args.indices.contains(index + 1) {
            renderPreview(to: URL(fileURLWithPath: args[index + 1]))
            NSApp.terminate(nil)
            return
        }
        let verifyingLayout = args.contains("--verify-layout")
        let demo = args.contains("--demo") || verifyingLayout
        if !demo {
            let same = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.codexquota.menubar")
            if same.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                NSApp.terminate(nil); return
            }
        }
        model = QuotaModel(demo: demo, welcome: demo)
        if demo && args.contains("--demo-regular") { model.startupChosen = true }
        if demo && args.contains("--demo-weekly-only"), let sample = model.bucket {
            model.bucket = QuotaBucket(limitId: sample.limitId, planType: sample.planType, primary: nil, secondary: sample.secondary)
        }
        let menu = NSMenu()
        let rootItem = NSMenuItem()
        let appMenu = NSMenu()
        let showItem = NSMenuItem(title: "显示额度", action: #selector(revealPopover), keyEquivalent: ",")
        showItem.target = self
        appMenu.addItem(showItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Codex Usage Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        rootItem.submenu = appMenu
        menu.addItem(rootItem)
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self; button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        panel.title = "Codex Usage Monitor"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 18
        scrollView.layer?.masksToBounds = true
        hostingView = NSHostingView(rootView: QuotaPanel(model: model))
        // Window size is controlled below, not by SwiftUI's changing ideal size.
        hostingView.sizingOptions = []
        scrollView.documentView = hostingView
        panel.contentView = QuotaGlassContainer(content: scrollView)
        model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, !self.updateQueued else { return }
            self.updateQueued = true
            DispatchQueue.main.async {
                self.updateQueued = false
                self.updateStatus()
                if self.panel.isVisible { self.layoutPanel() }
            }
        }.store(in: &subscriptions)
        updateStatus()
        model.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refreshAutomatically() }
        }
        if !model.monitoringAllowed || !model.startupChosen || demo || args.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPopover() }
        }
        if verifyingLayout {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.verifyLayout() }
        }
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        button.title = " " + model.menuTitle
        button.image = statusRing(remaining: model.displayRemaining)
        button.toolTip = model.accessibleSummary
        button.setAccessibilityLabel(model.accessibleSummary)
    }
    private func showPopover() {
        guard let button = statusItem?.button else { return }
        model.now = Date()
        model.syncLoginStatus()
        layoutPanel()
        if model.demo, ProcessInfo.processInfo.arguments.contains("--demo-backdrop"), demoBackdrop == nil {
            // A separate, temporary test window behind the real panel verifies
            // system backdrop diffusion without changing the user's wallpaper.
            let dark = ProcessInfo.processInfo.arguments.contains("--dark-backdrop")
            let backing = NSWindow(contentRect: panel.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
            backing.isReleasedWhenClosed = false
            backing.level = .floating
            backing.contentView = NSHostingView(rootView:
                LinearGradient(colors: dark ? [Color(white: 0.12), Color(white: 0.32), Color(white: 0.18)] : [Color(white: 0.96), Color(white: 0.68), Color(white: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
            backing.orderFront(nil)
            demoBackdrop = backing
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(button)
        // Opening the panel must not visually preselect an action. Tab begins
        // normal keyboard navigation when the user asks for it.
        panel.makeFirstResponder(nil)
    }
    private func layoutPanel() {
        guard let button = statusItem?.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let width = min(334, screen.visibleFrame.width - 16)
        let root = QuotaPanel(model: model, width: width)
        let measurement = NSHostingView(rootView: root)
        let contentSize = NSSize(width: width, height: ceil(measurement.fittingSize.height))
        let frame = quotaPanelFrame(contentSize: contentSize, anchor: anchor, visibleFrame: screen.visibleFrame)
        let changed = hostingView.frame.size != contentSize
        hostingView.rootView = root
        hostingView.setFrameSize(contentSize)
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        if changed || !panel.isVisible {
            let top = hostingView.isFlipped ? 0 : max(0, contentSize.height - frame.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
    func windowDidResignKey(_ notification: Notification) { panel.orderOut(nil) }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if panel.isVisible { layoutPanel() }
    }
    @objc private func togglePopover() { if panel.isVisible { panel.orderOut(nil) } else { showPopover() } }
    @objc private func revealPopover() { if !panel.isVisible { showPopover() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealPopover()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        demoBackdrop?.close()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    private func verifyLayout() {
        // Synthetic in-process regression check. Only our window geometry and
        // our rendered view are inspected; no screen capture or account query.
        guard let screen = statusItem.button?.window?.screen else { fatalError("No status bar screen") }
        let sample = model.bucket
        var top: CGFloat?
        for phase in 0..<6 {
            if phase == 5 { model.withdrawMonitoring() }
            model.bucket = phase == 0 ? nil : sample
            model.startupChosen = phase == 2
            model.selected = phase == 3 ? .fiveHour : .weekly
            model.loginError = phase == 4 ? "请在系统设置中允许此登录项。" : nil
            layoutPanel()
            precondition(screen.visibleFrame.contains(panel.frame), "Panel outside screen")
            if let top { precondition(abs(top - panel.frame.maxY) < 1, "Panel grew upward") }
            top = panel.frame.maxY
            precondition(hostingView.frame.height > 100, "Empty content")
            if let glass = panel.contentView as? QuotaGlassContainer,
               let tiff = glass.material.maskImage?.tiffRepresentation,
               let mask = NSBitmapImageRep(data: tiff) {
                for (x, y) in [(0, 0), (mask.pixelsWide-1, 0), (0, mask.pixelsHigh-1), (mask.pixelsWide-1, mask.pixelsHigh-1)] {
                    precondition(mask.colorAt(x: x, y: y)!.alphaComponent == 0, "Native material corner is not fully transparent")
                }
                precondition(mask.colorAt(x: mask.pixelsWide/2, y: mask.pixelsHigh/2)!.alphaComponent > 0.99, "Material center unexpectedly masked")
            } else { fatalError("Native backdrop mask missing") }
            print("PASS layout phase \(phase): panel=\(Int(panel.frame.width))x\(Int(panel.frame.height)), contentHeight=\(Int(hostingView.frame.height))")
        }
        print("PASS: native window stayed below the menu bar across dynamic content changes")
        NSApp.terminate(nil)
    }

    private func renderPreview(to directory: URL) {
        // Render our own native view using synthetic values; never capture the user's screen.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, period, welcome) in [("weekly", QuotaPeriod.weekly, false), ("five-hour", .fiveHour, false), ("first-launch", .weekly, true), ("privacy", .weekly, true)] {
            let sample = QuotaModel(demo: true, samplePeriod: period, welcome: welcome)
            if name == "privacy" { sample.withdrawMonitoring() }
            let view = NSHostingView(rootView: QuotaPanel(model: sample))
            view.appearance = NSAppearance(named: .aqua)
            view.setFrameSize(view.fittingSize)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: .aqua)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let panel = NSImage(size: view.bounds.size)
            panel.addRepresentation(bitmap)
            let size = NSSize(width: 390, height: view.bounds.height + 86)
            let picture = NSImage(size: size)
            picture.lockFocus()
            NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: size.height - 32, width: size.width, height: 32)).fill()
            let remaining = sample.displayRemaining
            statusRing(remaining: remaining).draw(in: NSRect(x: 290, y: size.height - 24, width: 17, height: 17))
            (sample.menuTitle as NSString).draw(at: NSPoint(x: 313, y: size.height - 23), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black])
            panel.draw(at: NSPoint(x: 28, y: 26), from: .zero, operation: .sourceOver, fraction: 1)
            picture.unlockFocus()
            if let tiff = picture.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
    }
}

@main
enum CodexQuotaApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
