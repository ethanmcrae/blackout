import Cocoa
import Carbon.HIToolbox

// NSWindow subclass that accepts key events for triple-Escape detection and password input.
// This avoids needing Accessibility permissions (no global event monitor needed).
final class OverlayWindow: NSWindow {
    var onEscapePressed: (() -> Void)?
    var onKeyPressed: ((String) -> Void)?

    private lazy var flashView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.alphaValue = 0.0
        view.translatesAutoresizingMaskIntoConstraints = false
        if let contentView = self.contentView {
            contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentView.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }
        return view
    }()

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscapePressed?()
        } else if let chars = event.characters, !chars.isEmpty {
            onKeyPressed?(chars)
        }
    }

    func flashTint(color: NSColor) {
        flashView.layer?.backgroundColor = color.cgColor
        flashView.alphaValue = 1.0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.flashView.animator().alphaValue = 0.0
        }
    }
}

final class OverlayManager {
    private var overlayWindows: [OverlayWindow] = []
    private let sleepPrevention = SleepPrevention()
    private(set) var isActive = false

    /// When true, shows a small preview window instead of fullscreen overlays.
    /// Set to false for production use.
    var previewMode = false

    private static let fadeDuration: TimeInterval = 0.35
    private static let previewSize = NSSize(width: 300, height: 200)

    /// Called on each Escape keypress received by an overlay window.
    var onOverlayEscapePressed: (() -> Void)?

    /// Called when a non-Escape key is pressed on an overlay window.
    var onOverlayKeyPressed: ((String) -> Void)?

    /// Called when overlay state changes (for menu bar icon updates, etc.)
    var onStateChanged: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show() {
        guard !isActive else { return }
        isActive = true
        NSCursor.hide()
        createWindows()
        sleepPrevention.enable()
        onStateChanged?()

        // Fade in: start transparent, animate to opaque
        for window in overlayWindows {
            window.alphaValue = 0.0
            window.orderFrontRegardless()
        }
        // Make the first overlay window key so it receives Escape presses
        overlayWindows.first?.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in self.overlayWindows {
                window.animator().alphaValue = 1.0
            }
        }
    }

    func hide() {
        guard isActive else { return }
        isActive = false
        NSCursor.unhide()
        sleepPrevention.disable()
        onStateChanged?()

        let windows = overlayWindows
        overlayWindows = []

        // Fade out then remove
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in windows {
                window.animator().alphaValue = 0.0
            }
        }, completionHandler: {
            for window in windows {
                window.orderOut(nil)
            }
        })
    }

    func toggle() {
        if isActive { hide() } else { show() }
    }

    private func createWindows() {
        if previewMode {
            let window = makePreviewWindow()
            overlayWindows.append(window)
        } else {
            for screen in NSScreen.screens {
                let window = makeOverlayWindow(for: screen)
                overlayWindows.append(window)
            }
        }
    }

    private func makeOverlayWindow(for screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // Set frame explicitly — contentRect in init doesn't always map correctly
        // to external displays in global coordinates
        window.setFrame(screen.frame, display: true)
        window.backgroundColor = .black
        window.alphaValue = 0.0
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.onEscapePressed = { [weak self] in
            self?.onOverlayEscapePressed?()
        }
        window.onKeyPressed = { [weak self] chars in
            self?.onOverlayKeyPressed?(chars)
        }
        return window
    }

    func flashAllWindows(color: NSColor) {
        for window in overlayWindows {
            window.flashTint(color: color)
        }
    }

    private func makePreviewWindow() -> OverlayWindow {
        let frame = NSRect(
            x: 0, y: 0,
            width: Self.previewSize.width,
            height: Self.previewSize.height
        )
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Blackout Preview (test mode)"
        window.backgroundColor = .black
        window.alphaValue = 0.0
        window.level = .floating
        window.center()
        window.hasShadow = true

        // Add a label so it's obvious this is a preview
        let label = NSTextField(labelWithString: "BLACKOUT ACTIVE\n(Preview Mode)")
        label.alignment = .center
        label.font = .boldSystemFont(ofSize: 16)
        label.textColor = .darkGray
        label.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(label)
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }

        window.onEscapePressed = { [weak self] in
            self?.onOverlayEscapePressed?()
        }
        window.onKeyPressed = { [weak self] chars in
            self?.onOverlayKeyPressed?(chars)
        }
        return window
    }

    @objc private func screensChanged() {
        guard isActive else { return }
        // Remove old windows immediately (no fade — this is a display reconfiguration)
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        createWindows()
        for window in overlayWindows {
            window.alphaValue = 1.0
            window.orderFrontRegardless()
        }
        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    deinit {
        // Force-remove without animation on teardown
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        if isActive { NSCursor.unhide() }
        sleepPrevention.disable()
        NotificationCenter.default.removeObserver(self)
    }
}
