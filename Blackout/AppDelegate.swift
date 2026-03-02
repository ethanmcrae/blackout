import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlayManager = OverlayManager()
    private let hotkeyManager = HotkeyManager()
    private var setupWindowController: SetupWindowController?

    // Menu items that need updating
    private var activateMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    // Password mode state
    private var unlockMode: String = "hotkey" // "hotkey" or "password"
    private var passwordMatcher: PasswordMatcher?

    private static let unlockModeKey = "unlockMode"

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadUnlockMode()
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
            guard let self = self else { return }
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
                if position >= 2 {
                    let green = NSColor(red: 0, green: 0.15, blue: 0.1, alpha: 0.08)
                    overlayManager.flashAllWindows(color: green)
                }
            case .incorrect:
                let red = NSColor(red: 0.15, green: 0, blue: 0, alpha: 0.08)
                overlayManager.flashAllWindows(color: red)
            case .complete:
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
