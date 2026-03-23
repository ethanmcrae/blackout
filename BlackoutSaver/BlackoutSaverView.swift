import ScreenSaver

class BlackoutSaverView: ScreenSaverView {

    private var bgView: (NSView & AnimationModule)?
    /// Resolved once across all screen instances so every monitor matches
    private static var sharedConfig: AnimationConfig?

    // Use standard defaults with a prefix to avoid collisions
    private var prefs: UserDefaults { UserDefaults.standard }
    private static let keyPrefix = "blackoutSaver_"
    private func key(_ name: String) -> String { Self.keyPrefix + name }

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = TimeInterval.infinity
        setupBackgroundView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = TimeInterval.infinity
        setupBackgroundView()
    }

    // MARK: - Background View

    private func resolveConfig() -> AnimationConfig {
        if let cached = BlackoutSaverView.sharedConfig {
            return cached
        }

        let d = prefs
        let colorRaw = d.string(forKey: key("accentColor")) ?? "random"
        let color = AccentColor(rawValue: colorRaw) ?? .blue
        var rgb = color.rgb

        let lightMode = d.bool(forKey: key("lightMode"))
        if lightMode && rgb.0 > 0.9 && rgb.1 > 0.9 && rgb.2 > 0.9 {
            rgb = (0.0, 0.0, 0.0)
        }

        let moveRaw = d.string(forKey: key("movementType")) ?? "walkers"
        let moveType = (MovementType(rawValue: moveRaw) ?? .walkers).resolved

        let config = AnimationConfig(
            accentR: rgb.0, accentG: rgb.1, accentB: rgb.2,
            lightMode: lightMode, movementType: moveType
        )
        BlackoutSaverView.sharedConfig = config
        return config
    }

    private func setupBackgroundView() {
        bgView?.removeFromSuperview()

        let config = resolveConfig()
        let view = AnimationModuleType.isometric.createView(frame: bounds, config: config)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        bgView = view
    }

    // MARK: - Animation

    override func startAnimation() {
        bgView?.startAnimation()
    }

    override func stopAnimation() {
        bgView?.stopAnimation()
        BlackoutSaverView.sharedConfig = nil
        super.stopAnimation()
    }

    override func animateOneFrame() {
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
    }

    // MARK: - Configuration Sheet

    private lazy var configWindow: NSWindow = buildConfigPanel()

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        // Update controls to reflect current settings before showing
        if let content = configWindow.contentView {
            let d = prefs
            if let popup = content.viewWithTag(1) as? NSPopUpButton {
                let cur = d.string(forKey: key("accentColor")) ?? "random"
                if let idx = AccentColor.allCases.firstIndex(where: { $0.rawValue == cur }) {
                    popup.selectItem(at: idx)
                }
            }
            if let popup = content.viewWithTag(2) as? NSPopUpButton {
                let cur = d.string(forKey: key("movementType")) ?? "walkers"
                if let idx = MovementType.allCases.firstIndex(where: { $0.rawValue == cur }) {
                    popup.selectItem(at: idx)
                }
            }
            if let check = content.viewWithTag(3) as? NSButton {
                check.state = d.bool(forKey: key("lightMode")) ? .on : .off
            }
        }
        return configWindow
    }

    private func buildConfigPanel() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Blackout Settings"

        let content = NSView(frame: panel.contentView!.bounds)
        panel.contentView = content

        let d = prefs
        var y: CGFloat = 180

        // Color
        let colorLabel = NSTextField(labelWithString: "Color:")
        colorLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        content.addSubview(colorLabel)

        let colorPopup = NSPopUpButton(frame: NSRect(x: 110, y: y, width: 180, height: 26), pullsDown: false)
        for c in AccentColor.allCases {
            colorPopup.addItem(withTitle: c.displayName)
            colorPopup.lastItem?.representedObject = c.rawValue
        }
        let currentColor = d.string(forKey: key("accentColor")) ?? "random"
        if let idx = AccentColor.allCases.firstIndex(where: { $0.rawValue == currentColor }) {
            colorPopup.selectItem(at: idx)
        }
        colorPopup.tag = 1
        content.addSubview(colorPopup)

        y -= 36

        // Animation
        let moveLabel = NSTextField(labelWithString: "Animation:")
        moveLabel.frame = NSRect(x: 20, y: y, width: 80, height: 22)
        content.addSubview(moveLabel)

        let movePopup = NSPopUpButton(frame: NSRect(x: 110, y: y, width: 180, height: 26), pullsDown: false)
        for m in MovementType.allCases {
            movePopup.addItem(withTitle: m.displayName)
            movePopup.lastItem?.representedObject = m.rawValue
        }
        let currentMove = d.string(forKey: key("movementType")) ?? "walkers"
        if let idx = MovementType.allCases.firstIndex(where: { $0.rawValue == currentMove }) {
            movePopup.selectItem(at: idx)
        }
        movePopup.tag = 2
        content.addSubview(movePopup)

        y -= 36

        // Light Mode
        let lightCheck = NSButton(checkboxWithTitle: "Light Mode", target: nil, action: nil)
        lightCheck.frame = NSRect(x: 110, y: y, width: 180, height: 22)
        lightCheck.state = d.bool(forKey: key("lightMode")) ? .on : .off
        lightCheck.tag = 3
        content.addSubview(lightCheck)

        y -= 44

        // OK / Cancel buttons
        let okButton = NSButton(title: "OK", target: self, action: #selector(configOK(_:)))
        okButton.frame = NSRect(x: 210, y: y, width: 80, height: 30)
        okButton.keyEquivalent = "\r"
        content.addSubview(okButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(configCancel(_:)))
        cancelButton.frame = NSRect(x: 120, y: y, width: 80, height: 30)
        cancelButton.keyEquivalent = "\u{1b}"
        content.addSubview(cancelButton)

        return panel
    }

    @objc private func configOK(_ sender: NSButton) {
        guard let panel = sender.window,
              let content = panel.contentView else { return }

        let d = prefs

        if let popup = content.viewWithTag(1) as? NSPopUpButton,
           let raw = popup.selectedItem?.representedObject as? String {
            d.set(raw, forKey: key("accentColor"))
        }

        if let popup = content.viewWithTag(2) as? NSPopUpButton,
           let raw = popup.selectedItem?.representedObject as? String {
            d.set(raw, forKey: key("movementType"))
        }

        if let check = content.viewWithTag(3) as? NSButton {
            d.set(check.state == .on, forKey: key("lightMode"))
        }

        d.synchronize()

        // Build config directly from UI controls (don't re-read from prefs)
        var colorRaw = "random"
        if let popup = content.viewWithTag(1) as? NSPopUpButton,
           let raw = popup.selectedItem?.representedObject as? String {
            colorRaw = raw
        }
        let color = AccentColor(rawValue: colorRaw) ?? .blue
        var rgb = color.rgb

        var lightMode = false
        if let check = content.viewWithTag(3) as? NSButton {
            lightMode = check.state == .on
        }
        if lightMode && rgb.0 > 0.9 && rgb.1 > 0.9 && rgb.2 > 0.9 {
            rgb = (0.0, 0.0, 0.0)
        }

        var moveRaw = "walkers"
        if let popup = content.viewWithTag(2) as? NSPopUpButton,
           let raw = popup.selectedItem?.representedObject as? String {
            moveRaw = raw
        }
        let moveType = (MovementType(rawValue: moveRaw) ?? .walkers).resolved

        BlackoutSaverView.sharedConfig = AnimationConfig(
            accentR: rgb.0, accentG: rgb.1, accentB: rgb.2,
            lightMode: lightMode, movementType: moveType
        )

        // Stop old animation and rebuild with new config
        bgView?.stopAnimation()
        setupBackgroundView()
        bgView?.startAnimation()

        dismissSheet(panel)
    }

    @objc private func configCancel(_ sender: NSButton) {
        guard let panel = sender.window else { return }
        dismissSheet(panel)
    }

    private func dismissSheet(_ panel: NSWindow) {
        panel.sheetParent?.endSheet(panel)
    }
}
