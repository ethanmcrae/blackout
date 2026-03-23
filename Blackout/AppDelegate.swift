import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlayManager = OverlayManager()
    private let hotkeyManager = HotkeyManager()
    private var setupWindowController: SetupWindowController?

    // Menu items that need updating
    private var activateMenuItem: NSMenuItem!
    private var tripleEscapeMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    // Password mode state
    private var unlockMode: String = "hotkey" // "hotkey" or "password"
    private var passwordMatcher: PasswordMatcher?

    // Triple-escape setting
    private static let unlockModeKey = "unlockMode"
    private static let tripleEscapeKey = "tripleEscapeEnabled"
    private var tripleEscapeEnabled = true

    // Color setting
    private static let accentColorKey = "accentColor"
    private static let lightModeKey = "lightMode"
    private static let movementTypeKey = "movementType"
    private static let showFPSKey = "showFPS"
    private var colorMenuItems: [NSMenuItem] = []
    private var movementMenuItems: [NSMenuItem] = []
    private var lightModeMenuItem: NSMenuItem!
    private var showFPSMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadUnlockMode()
        loadTripleEscapeSetting()
        setupMenuBar()
        bindHotkeyActions()
        bindOverlayCallbacks()

        let hasAnyConfig = hotkeyManager.isConfigured || unlockMode == "password"
        if hasAnyConfig {
            // Already set up — ready to go
        } else {
            showSetupWindow(isFirstTime: true)
        }
    }

    // MARK: - Unlock Mode Persistence

    private func loadUnlockMode() {
        let saved = UserDefaults.standard.string(forKey: Self.unlockModeKey) ?? "hotkey"
        unlockMode = saved
        if unlockMode == "password" {
            if let pw = KeychainHelper.load() {
                passwordMatcher = PasswordMatcher(password: pw)
                // Hotkey stays enabled — used for activation only in password mode
            } else {
                // Password lost — persist the fallback and force re-setup
                setUnlockMode("hotkey")
            }
        }
    }

    private func setUnlockMode(_ mode: String) {
        unlockMode = mode
        UserDefaults.standard.set(mode, forKey: Self.unlockModeKey)
    }

    private func loadTripleEscapeSetting() {
        if UserDefaults.standard.object(forKey: Self.tripleEscapeKey) != nil {
            tripleEscapeEnabled = UserDefaults.standard.bool(forKey: Self.tripleEscapeKey)
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateMenuBarIcon()

        let menu = NSMenu()

        activateMenuItem = NSMenuItem(title: "Activate Blackout", action: #selector(toggleOverlay), keyEquivalent: "")
        activateMenuItem.target = self
        updateActivateMenuTitle()
        menu.addItem(activateMenuItem)

        menu.addItem(NSMenuItem(title: "Change Unlock Method...", action: #selector(changeUnlockMethod), keyEquivalent: ""))
        menu.items.last?.target = self

        tripleEscapeMenuItem = NSMenuItem(title: "Triple-Escape Dismiss", action: #selector(toggleTripleEscape), keyEquivalent: "")
        tripleEscapeMenuItem.target = self
        tripleEscapeMenuItem.state = tripleEscapeEnabled ? .on : .off
        menu.addItem(tripleEscapeMenuItem)

        // Appearance submenu (contains Color, Animation, Light Mode)
        let appearanceMenu = NSMenu(title: "Appearance")

        // Color sub-submenu
        let colorMenu = NSMenu(title: "Color")
        for color in AccentColor.allCases {
            let item = NSMenuItem(title: color.displayName, action: #selector(selectColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            colorMenu.addItem(item)
            colorMenuItems.append(item)
        }
        let colorSubmenuItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorSubmenuItem.submenu = colorMenu
        appearanceMenu.addItem(colorSubmenuItem)
        updateColorMenuCheckmarks()

        // Animation sub-submenu
        let movementMenu = NSMenu(title: "Animation")
        for moveType in MovementType.allCases {
            let item = NSMenuItem(title: moveType.displayName, action: #selector(selectMovement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = moveType.rawValue
            movementMenu.addItem(item)
            movementMenuItems.append(item)
        }
        let movementSubmenuItem = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        movementSubmenuItem.submenu = movementMenu
        appearanceMenu.addItem(movementSubmenuItem)
        updateMovementMenuCheckmarks()

        appearanceMenu.addItem(.separator())

        // Light Mode toggle
        lightModeMenuItem = NSMenuItem(title: "Light Mode", action: #selector(toggleLightMode), keyEquivalent: "")
        lightModeMenuItem.target = self
        lightModeMenuItem.state = UserDefaults.standard.bool(forKey: Self.lightModeKey) ? .on : .off
        appearanceMenu.addItem(lightModeMenuItem)

        // Show FPS toggle
        showFPSMenuItem = NSMenuItem(title: "Show FPS", action: #selector(toggleShowFPS), keyEquivalent: "")
        showFPSMenuItem.target = self
        showFPSMenuItem.state = UserDefaults.standard.bool(forKey: Self.showFPSKey) ? .on : .off
        appearanceMenu.addItem(showFPSMenuItem)

        let appearanceSubmenuItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceSubmenuItem.submenu = appearanceMenu
        menu.addItem(appearanceSubmenuItem)

        menu.addItem(.separator())

        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        updateLaunchAtLoginState()
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.last?.target = self

        statusItem.menu = menu
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        if overlayManager.isActive {
            button.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "Blackout Active")
            if button.image == nil { button.title = "◉" }
        } else {
            button.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Blackout")
            if button.image == nil { button.title = "●" }
        }
    }

    private func updateActivateMenuTitle() {
        let hotkeyStr = hotkeyManager.hotkeyDisplayString()
        if unlockMode == "password" {
            if overlayManager.isActive {
                activateMenuItem.title = "Deactivate Blackout (Password)"
            } else {
                activateMenuItem.title = "Activate Blackout (\(hotkeyStr))"
            }
        } else {
            if overlayManager.isActive {
                activateMenuItem.title = "Deactivate Blackout (\(hotkeyStr))"
            } else {
                activateMenuItem.title = "Activate Blackout (\(hotkeyStr))"
            }
        }
    }

    // MARK: - Hotkey Bindings

    private func bindHotkeyActions() {
        hotkeyManager.onHotkeyPressed = { [weak self] in
            guard let self = self else { return }
            // If in practice mode, treat as practice success (hotkey mode only)
            if let setup = self.setupWindowController, setup.phase == .practice {
                if self.unlockMode == "password" {
                    // Password practice: hotkey doesn't dismiss — must type password
                    return
                }
                self.overlayManager.hide()
                setup.practiceSucceeded()
                return
            }
            if self.unlockMode == "password" {
                // Password mode: hotkey only activates, never deactivates
                if !self.overlayManager.isActive {
                    self.overlayManager.show()
                    self.updateActivateMenuTitle()
                }
            } else {
                self.overlayManager.toggle()
                self.updateActivateMenuTitle()
            }
        }

        hotkeyManager.onEscapeTriplePress = { [weak self] in
            guard let self = self, self.tripleEscapeEnabled else { return }
            if self.overlayManager.isActive {
                self.overlayManager.hide()
                self.updateActivateMenuTitle()
                if let setup = self.setupWindowController, setup.phase == .practice {
                    setup.practiceSucceeded()
                }
            }
        }
    }

    private func bindOverlayCallbacks() {
        overlayManager.onOverlayEscapePressed = { [weak self] in
            self?.hotkeyManager.recordEscapePress()
        }

        overlayManager.onOverlayKeyPressed = { [weak self] chars in
            self?.handlePasswordKey(chars)
        }

        overlayManager.onOverlayBackspacePressed = { [weak self] in
            self?.handleBackspace()
        }

        overlayManager.onOverlayArrowKeyPressed = { [weak self] keyCode in
            guard let self = self, self.overlayManager.isActive else { return }
            let delta: CGFloat = keyCode == 126 ? 0.05 : -0.05
            self.overlayManager.adjustOpacity(delta: delta)
        }

        overlayManager.onStateChanged = { [weak self] in
            self?.updateMenuBarIcon()
        }
    }

    // MARK: - Password Key Handling

    private func handlePasswordKey(_ chars: String) {
        guard overlayManager.isActive, unlockMode == "password", let matcher = passwordMatcher else { return }

        for char in chars {
            let result = matcher.processKey(char)
            switch result {
            case .correct(let position):
                if position >= 1 {
                    overlayManager.showProgressOnPrimary(count: position + 1)
                }
            case .incorrect(let previousProgress):
                if previousProgress >= 2 {
                    overlayManager.showErrorOnPrimary(count: previousProgress)
                } else {
                    overlayManager.clearFeedbackOnPrimary()
                }
            case .complete:
                overlayManager.clearFeedbackOnPrimary()
                if let setup = setupWindowController, setup.phase == .practice {
                    overlayManager.hide()
                    setup.practiceSucceeded()
                } else {
                    overlayManager.hide()
                    updateActivateMenuTitle()
                }
                return
            }
        }
    }

    private func handleBackspace() {
        guard overlayManager.isActive, unlockMode == "password", let matcher = passwordMatcher else { return }
        let newIndex = matcher.processBackspace()
        if newIndex > 0 {
            overlayManager.showProgressOnPrimary(count: newIndex)
        } else {
            overlayManager.clearFeedbackOnPrimary()
        }
    }

    // MARK: - Actions

    @objc private func toggleOverlay() {
        if unlockMode == "password" && overlayManager.isActive {
            // Password mode: menu click can't deactivate — must type password
            return
        }
        overlayManager.toggle()
        updateActivateMenuTitle()
    }

    @objc private func changeUnlockMethod() {
        showSetupWindow(isFirstTime: false)
    }

    @objc private func selectColor(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: Self.accentColorKey)
        updateColorMenuCheckmarks()
    }

    @objc private func toggleLightMode() {
        let current = UserDefaults.standard.bool(forKey: Self.lightModeKey)
        UserDefaults.standard.set(!current, forKey: Self.lightModeKey)
        lightModeMenuItem.state = !current ? .on : .off
        updateColorMenuTitles()
    }

    @objc private func toggleShowFPS() {
        let current = UserDefaults.standard.bool(forKey: Self.showFPSKey)
        UserDefaults.standard.set(!current, forKey: Self.showFPSKey)
        showFPSMenuItem.state = !current ? .on : .off
        overlayManager.setShowFPS(!current)
    }


    @objc private func selectMovement(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        UserDefaults.standard.set(rawValue, forKey: Self.movementTypeKey)
        updateMovementMenuCheckmarks()
    }

    private func updateMovementMenuCheckmarks() {
        let current = UserDefaults.standard.string(forKey: Self.movementTypeKey) ?? "walkers"
        for item in movementMenuItems {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
    }

    private func updateColorMenuCheckmarks() {
        let current = UserDefaults.standard.string(forKey: Self.accentColorKey) ?? "random"
        for item in colorMenuItems {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
        updateColorMenuTitles()
    }

    private func updateColorMenuTitles() {
        let lightMode = UserDefaults.standard.bool(forKey: Self.lightModeKey)
        for item in colorMenuItems {
            if (item.representedObject as? String) == "white" {
                item.title = lightMode ? "Black" : "White"
            }
        }
    }

    @objc private func toggleTripleEscape() {
        tripleEscapeEnabled.toggle()
        UserDefaults.standard.set(tripleEscapeEnabled, forKey: Self.tripleEscapeKey)
        tripleEscapeMenuItem.state = tripleEscapeEnabled ? .on : .off
        setupWindowController?.tripleEscapeEnabled = tripleEscapeEnabled
    }

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                // Silently fail — user can toggle again
            }
            updateLaunchAtLoginState()
        }
    }

    private func updateLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginMenuItem.isEnabled = false
            launchAtLoginMenuItem.title = "Launch at Login (macOS 13+ required)"
        }
    }

    @objc private func quitApp() {
        overlayManager.hide()
        NSApp.terminate(nil)
    }

    // MARK: - Setup Window

    private func showSetupWindow(isFirstTime: Bool) {
        let setup = SetupWindowController()
        setup.delegate = self
        setup.skipPractice = !isFirstTime
        setup.allowCancel = !isFirstTime
        setup.tripleEscapeEnabled = tripleEscapeEnabled
        setup.showWindow(nil)
        setup.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindowController = setup
    }
}

// MARK: - SetupWindowControllerDelegate

extension AppDelegate: SetupWindowControllerDelegate {
    func setupDidRequestPractice(keyCode: UInt32, modifiers: UInt32) {
        setUnlockMode("hotkey")
        passwordMatcher = nil
        hotkeyManager.configure(keyCode: keyCode, modifiers: modifiers)
        updateActivateMenuTitle()
        overlayManager.show()
    }

    func setupDidRequestPractice(password: String, keyCode: UInt32, modifiers: UInt32) {
        setUnlockMode("password")
        passwordMatcher = PasswordMatcher(password: password)
        hotkeyManager.configure(keyCode: keyCode, modifiers: modifiers)
        updateActivateMenuTitle()
        overlayManager.show()
    }

    func setupDidComplete(keyCode: UInt32, modifiers: UInt32) {
        setUnlockMode("hotkey")
        passwordMatcher = nil
        KeychainHelper.delete()
        hotkeyManager.configure(keyCode: keyCode, modifiers: modifiers)
        updateActivateMenuTitle()
        setupWindowController = nil
    }

    func setupDidComplete(password: String, keyCode: UInt32, modifiers: UInt32) {
        setUnlockMode("password")
        _ = KeychainHelper.save(password: password)
        passwordMatcher = PasswordMatcher(password: password)
        hotkeyManager.configure(keyCode: keyCode, modifiers: modifiers)
        updateActivateMenuTitle()
        setupWindowController = nil
    }

    func setupDidCancel() {
        setupWindowController = nil
    }
}
