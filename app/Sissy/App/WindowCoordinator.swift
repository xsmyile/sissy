import AppKit
import Foundation
import SwiftUI

/// Owns app-window presentation for the menubar app. The status menu forwards
/// window commands here; the application delegate only bootstraps this object.
/// Settings is not one of these windows — it is a SwiftUI `Settings` scene
/// opened by `SettingsLink`.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var aboutWindow: NSWindow?

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
        NSApp.activate()
        window.orderFrontRegardless()
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
        if closing === aboutWindow {
            aboutWindow = nil
        }
    }
}
