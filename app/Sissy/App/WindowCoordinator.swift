import AppKit
import Foundation
import SwiftUI

/// Owns app-window presentation for the menubar app. The status menu forwards
/// window commands here; the application delegate only bootstraps this object.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let model: SissyModel
    private var pairingWindow: NSWindow?
    private var aboutWindow: NSWindow?

    init(model: SissyModel) {
        self.model = model
        super.init()
    }

    // MARK: Activation policy

    func activate(withPolicy policy: NSApplication.ActivationPolicy) {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
            frontApp != .current
        {
            NSRunningApplication.current.activate(from: frontApp)
        } else {
            NSApp.activate()
        }
        NSApp.setActivationPolicy(policy)
    }

    func deactivate(withPolicy policy: NSApplication.ActivationPolicy) {
        let nextApp = NSWorkspace.shared.runningApplications.first { app in
            app != .current
                && app.activationPolicy == .regular
                && !app.isTerminated
        }
        if let nextApp {
            NSApp.yieldActivation(to: nextApp)
        } else {
            NSApp.deactivate()
        }
        NSApp.setActivationPolicy(policy)
    }

    func applicationShouldTerminateAfterLastWindowClosed() -> Bool {
        deactivate(withPolicy: .accessory)
        return false
    }

    // MARK: Window openers

    func openPairingWindow() {
        activate(withPolicy: .regular)
        if let existing = pairingWindow {
            present(existing)
            return
        }
        let root = PairingView()
            .environmentObject(model)
        let window = makeManagedWindow(
            title: "Pair Device",
            size: NSSize(width: 620, height: 640),
            minSize: NSSize(width: 540, height: 520),
            resizable: true,
            root: root
        )
        present(window)
        pairingWindow = window
    }

    func openAboutWindow() {
        activate(withPolicy: .regular)
        if let existing = aboutWindow {
            present(existing)
            return
        }
        let window = makeAboutWindow()
        present(window)
        aboutWindow = window
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    private func makeManagedWindow<Root: View>(
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        resizable: Bool = true,
        root: Root
    ) -> NSWindow {
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]

        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            styleMask.insert(.resizable)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.contentViewController = host
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = minSize ?? size
        window.setContentSize(size)
        window.center()
        window.delegate = self
        return window
    }

    private func makeAboutWindow() -> NSWindow {
        let size = NSSize(width: 280, height: 400)
        let host = NSHostingController(rootView: AboutView())
        host.sizingOptions = [.preferredContentSize]

        let effectView = NSVisualEffectView()
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .followsWindowActiveState

        let container = NSViewController()
        container.view = effectView
        container.addChild(host)

        host.view.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: effectView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = container
        window.title = "About Sissy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = size
        window.setContentSize(size)
        window.center()
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === pairingWindow {
            pairingWindow = nil
        } else if closing === aboutWindow {
            aboutWindow = nil
        }
    }
}
