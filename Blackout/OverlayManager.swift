import Cocoa
import Carbon.HIToolbox

// NSWindow subclass that accepts key events for triple-Escape detection and password input.
// This avoids needing Accessibility permissions (no global event monitor needed).
final class OverlayWindow: NSWindow {
    var onEscapePressed: (() -> Void)?
    var onKeyPressed: ((String) -> Void)?
    var onBackspacePressed: (() -> Void)?
    var onArrowKeyPressed: ((UInt16) -> Void)?

    /// Set to true during hide/fade-out to prevent resignKey from re-asserting focus.
    var suppressFocusReassert = false

    private var feedbackLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 40, weight: .medium)
        label.textColor = NSColor(white: 0.15, alpha: 1.0)
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var feedbackFadeWork: DispatchWorkItem?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 126 || event.keyCode == 125 {
            onArrowKeyPressed?(event.keyCode)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            onEscapePressed?()
        } else if event.keyCode == UInt16(kVK_Delete) {
            onBackspacePressed?()
        } else if let chars = event.characters, !chars.isEmpty {
            onKeyPressed?(chars)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Feedback Label

    func installFeedbackLabel() {
        guard let contentView = self.contentView, feedbackLabel.superview == nil else { return }
        contentView.addSubview(feedbackLabel)
        NSLayoutConstraint.activate([
            feedbackLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            feedbackLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func showProgress(count: Int) {
        feedbackFadeWork?.cancel()
        installFeedbackLabel()
        feedbackLabel.stringValue = String(repeating: "*", count: count)
        feedbackLabel.textColor = NSColor(white: 0.15, alpha: 1.0)
        feedbackLabel.alphaValue = 1.0
        feedbackLabel.isHidden = false

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.feedbackLabel.animator().alphaValue = 0.0
            } completionHandler: {
                self.feedbackLabel.isHidden = true
            }
        }
        feedbackFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func showError(count: Int) {
        feedbackFadeWork?.cancel()
        installFeedbackLabel()
        feedbackLabel.stringValue = count > 0 ? String(repeating: "*", count: count) : ""
        feedbackLabel.textColor = NSColor(red: 0.6, green: 0.0, blue: 0.0, alpha: 1.0)
        feedbackLabel.alphaValue = 1.0
        feedbackLabel.isHidden = count == 0

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.8
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.feedbackLabel.animator().alphaValue = 0.0
            } completionHandler: {
                self.feedbackLabel.isHidden = true
            }
        }
        feedbackFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func clearFeedback() {
        feedbackFadeWork?.cancel()
        feedbackLabel.isHidden = true
        feedbackLabel.stringValue = ""
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

    private var focusGuardTimer: Timer?
    private var localKeyMonitor: Any?

    /// Called on each Escape keypress received by an overlay window.
    var onOverlayEscapePressed: (() -> Void)?

    /// Called when a non-Escape key is pressed on an overlay window.
    var onOverlayKeyPressed: ((String) -> Void)?

    /// Called when backspace is pressed on an overlay window.
    var onOverlayBackspacePressed: (() -> Void)?

    /// Called when an arrow key is pressed on an overlay window.
    var onOverlayArrowKeyPressed: ((UInt16) -> Void)?

    /// Called when overlay state changes (for menu bar icon updates, etc.)
    var onStateChanged: (() -> Void)?

    private var currentOpacity: CGFloat = 1.0
    private var opacityAdjustmentTimer: Timer?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
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

        NSApp.activate(ignoringOtherApps: true)

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

        // Reset opacity state for this activation
        currentOpacity = 1.0
        for window in overlayWindows {
            window.isOpaque = true
            window.backgroundColor = .black
        }
        opacityAdjustmentTimer?.invalidate()
        opacityAdjustmentTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.opacityAdjustmentTimer = nil
        }

        startFocusGuard()
        startLocalKeyMonitor()
    }

    func hide() {
        guard isActive else { return }
        isActive = false
        NSCursor.unhide()
        sleepPrevention.disable()
        onStateChanged?()
        opacityAdjustmentTimer?.invalidate()
        opacityAdjustmentTimer = nil
        currentOpacity = 1.0
        stopFocusGuard()
        stopLocalKeyMonitor()

        let windows = overlayWindows
        overlayWindows = []

        // Suppress focus re-assertion during fade-out
        for window in windows {
            window.suppressFocusReassert = true
        }

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

    // MARK: - Focus Guard

    private func startFocusGuard() {
        focusGuardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reassertFocusIfNeeded()
        }
    }

    private func stopFocusGuard() {
        focusGuardTimer?.invalidate()
        focusGuardTimer = nil
    }

    // MARK: - Local Key Monitor

    private func startLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isActive else { return event }
            if event.keyCode == 126 || event.keyCode == 125 {
                self.onOverlayArrowKeyPressed?(event.keyCode)
                return nil
            }
            if event.keyCode == UInt16(kVK_Escape) {
                self.onOverlayEscapePressed?()
                return nil
            } else if event.keyCode == UInt16(kVK_Delete) {
                self.onOverlayBackspacePressed?()
                return nil
            } else if let chars = event.characters, !chars.isEmpty {
                self.onOverlayKeyPressed?(chars)
                return nil
            }
            return event
        }
    }

    private func stopLocalKeyMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func reassertFocusIfNeeded() {
        guard isActive, let first = overlayWindows.first, !first.isKeyWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        first.makeKeyAndOrderFront(nil)
    }

    @objc private func appDidResignActive() {
        guard isActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.overlayWindows.first?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func appDidBecomeActive() {
        guard isActive else { return }
        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Feedback (Primary Display)

    func showProgressOnPrimary(count: Int) {
        overlayWindows.first?.showProgress(count: count)
    }

    func showErrorOnPrimary(count: Int) {
        overlayWindows.first?.showError(count: count)
    }

    func clearFeedbackOnPrimary() {
        overlayWindows.first?.clearFeedback()
    }

    // MARK: - Opacity Adjustment

    func adjustOpacity(delta: CGFloat) {
        guard isActive, opacityAdjustmentTimer != nil else { return }
        currentOpacity = min(max(currentOpacity + delta, 0.05), 1.0)
        for window in overlayWindows {
            window.isOpaque = currentOpacity >= 1.0
            window.backgroundColor = NSColor.black.withAlphaComponent(currentOpacity)
        }
    }

    // MARK: - Window Creation

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
        window.onBackspacePressed = { [weak self] in
            self?.onOverlayBackspacePressed?()
        }
        window.onArrowKeyPressed = { [weak self] keyCode in
            self?.onOverlayArrowKeyPressed?(keyCode)
        }
        return window
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
        window.onBackspacePressed = { [weak self] in
            self?.onOverlayBackspacePressed?()
        }
        window.onArrowKeyPressed = { [weak self] keyCode in
            self?.onOverlayArrowKeyPressed?(keyCode)
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
        NSApp.activate(ignoringOtherApps: true)
        for window in overlayWindows {
            window.alphaValue = 1.0
            window.isOpaque = currentOpacity >= 1.0
            window.backgroundColor = NSColor.black.withAlphaComponent(currentOpacity)
            window.orderFrontRegardless()
        }
        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    deinit {
        opacityAdjustmentTimer?.invalidate()
        stopFocusGuard()
        stopLocalKeyMonitor()
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
