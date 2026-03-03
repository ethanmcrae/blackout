import Cocoa
import Carbon.HIToolbox

protocol SetupWindowControllerDelegate: AnyObject {
    func setupDidComplete(keyCode: UInt32, modifiers: UInt32)
    func setupDidComplete(password: String, keyCode: UInt32, modifiers: UInt32)
    func setupDidRequestPractice(keyCode: UInt32, modifiers: UInt32)
    func setupDidRequestPractice(password: String, keyCode: UInt32, modifiers: UInt32)
    func setupDidCancel()
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    weak var delegate: SetupWindowControllerDelegate?

    private var instructionLabel: NSTextField!
    private var hotkeyLabel: NSTextField!
    private var primaryButton: NSButton!
    private var secondaryButton: NSButton!
    private var escapeHintLabel: NSTextField!
    private var passwordField: NSSecureTextField!
    private var errorLabel: NSTextField!

    private var capturedKeyCode: UInt32 = 0
    private var capturedModifiers: UInt32 = 0
    private var capturedPassword: String = ""

    private var localMonitor: Any?
    private var errorDismissWork: DispatchWorkItem?

    /// When true, skip practice and go straight to confirm after capture.
    var skipPractice = false

    /// When true, the window gets a close button so the user can cancel without changing anything.
    var allowCancel = false {
        didSet {
            guard let window = window else { return }
            if allowCancel {
                window.styleMask.insert(.closable)
                window.title = "Change Unlock Method"
            }
        }
    }

    /// Whether triple-escape dismiss is currently enabled
    var tripleEscapeEnabled = true {
        didSet { updateEscapeHint() }
    }

    /// The selected unlock mode: "hotkey" or "password"
    private(set) var selectedMode: String = "hotkey"

    enum Phase {
        case modeSelect        // Choose between hotkey and password
        case capture           // Waiting for user to press a hotkey combo
        case confirm           // Show captured combo, let user confirm or retry
        case passwordEntry     // Enter a new password
        case passwordConfirm   // Re-type password to confirm
        case practice          // Overlay is active, user must dismiss
        case complete          // Success
    }
    private(set) var phase: Phase = .modeSelect

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Blackout Setup"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self
        setupUI()
        enterModeSelect()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        instructionLabel = NSTextField(wrappingLabelWithString: "")
        instructionLabel.alignment = .left
        instructionLabel.font = .systemFont(ofSize: 14)
        instructionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hotkeyLabel = NSTextField(labelWithString: "")
        hotkeyLabel.alignment = .center
        hotkeyLabel.font = .boldSystemFont(ofSize: 24)

        passwordField = NSSecureTextField()
        passwordField.alignment = .center
        passwordField.font = .systemFont(ofSize: 16)
        passwordField.placeholderString = "Enter password"
        passwordField.isHidden = true

        errorLabel = NSTextField(labelWithString: "")
        errorLabel.alignment = .left
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        primaryButton = NSButton(title: "", target: self, action: nil)
        primaryButton.bezelStyle = .rounded
        primaryButton.isHidden = true

        secondaryButton = NSButton(title: "", target: self, action: nil)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.isHidden = true

        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [buttonSpacer, secondaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        escapeHintLabel = NSTextField(wrappingLabelWithString: "")
        escapeHintLabel.alignment = .left
        escapeHintLabel.font = .systemFont(ofSize: 11)
        escapeHintLabel.textColor = .secondaryLabelColor
        escapeHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        escapeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        updateEscapeHint()

        let contentStack = NSStackView(views: [
            instructionLabel,
            hotkeyLabel,
            passwordField,
            errorLabel,
            buttonRow,
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.setCustomSpacing(4, after: passwordField)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(contentStack)
        contentView.addSubview(escapeHintLabel)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            instructionLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            hotkeyLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            passwordField.widthAnchor.constraint(equalToConstant: 220),

            escapeHintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            escapeHintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            escapeHintLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func updateEscapeHint() {
        guard let escapeHintLabel = escapeHintLabel else { return }
        if tripleEscapeEnabled {
            escapeHintLabel.stringValue = "Tip: Triple-press Escape is always available as an emergency dismiss."
        } else {
            escapeHintLabel.stringValue = "Tip: Triple-press Escape can be enabled as an emergency dismiss from the menu bar."
        }
    }

    // MARK: - Error Display

    private func showError(_ message: String) {
        errorDismissWork?.cancel()
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            self?.errorLabel.isHidden = true
        }
        errorDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Window Delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if phase == .practice { return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
        delegate?.setupDidCancel()
    }

    // MARK: - Phase: Mode Select

    private func enterModeSelect() {
        phase = .modeSelect
        instructionLabel.stringValue = "How would you like to dismiss the black screen?\n\nA hotkey is a keyboard shortcut (e.g. Cmd+Shift+B).\nA password is typed character-by-character while the screen is black."
        hotkeyLabel.stringValue = ""
        hotkeyLabel.isHidden = true
        passwordField.isHidden = true
        errorLabel.isHidden = true

        primaryButton.title = "Use a Hotkey"
        primaryButton.action = #selector(chooseModeHotkey)
        primaryButton.target = self
        primaryButton.isHidden = false

        secondaryButton.title = "Use a Password (Recommended)"
        secondaryButton.action = #selector(chooseModePassword)
        secondaryButton.target = self
        secondaryButton.isHidden = false
    }

    @objc private func chooseModeHotkey() {
        selectedMode = "hotkey"
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        hotkeyLabel.isHidden = false
        instructionLabel.stringValue = "Choose a hotkey to toggle Blackout on and off.\nThe same combo activates and dismisses the black screen.\n\nPress your desired key combination now (e.g. Cmd+Shift+B)."
        hotkeyLabel.stringValue = "Listening..."
        startCapture()
    }

    @objc private func chooseModePassword() {
        selectedMode = "password"
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        enterPasswordEntry()
    }

    // MARK: - Phase: Capture (Hotkey)

    private func startCapture() {
        phase = .capture
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCaptureKey(event)
            return nil
        }
    }

    private func stopCapture() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleCaptureKey(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !mods.intersection([.command, .control, .option, .shift]).isEmpty else {
            hotkeyLabel.stringValue = "Add a modifier key (Cmd, Ctrl, etc.)"
            return
        }
        guard event.keyCode != UInt16(kVK_Command) &&
              event.keyCode != UInt16(kVK_Shift) &&
              event.keyCode != UInt16(kVK_Option) &&
              event.keyCode != UInt16(kVK_Control) &&
              event.keyCode != UInt16(kVK_RightCommand) &&
              event.keyCode != UInt16(kVK_RightShift) &&
              event.keyCode != UInt16(kVK_RightOption) &&
              event.keyCode != UInt16(kVK_RightControl) else {
            return
        }

        capturedKeyCode = UInt32(event.keyCode)
        capturedModifiers = UInt32(mods.rawValue)
        stopCapture()
        enterConfirmPhase()
    }

    // MARK: - Phase: Confirm (Hotkey)

    private func enterConfirmPhase() {
        phase = .confirm
        let displayStr = hotkeyDisplayString(keyCode: capturedKeyCode, modifiers: capturedModifiers)
        hotkeyLabel.stringValue = displayStr

        if selectedMode == "password" {
            if skipPractice {
                instructionLabel.stringValue = "Use \(displayStr) to activate Blackout?\nYou'll type your password to dismiss the black screen."
                primaryButton.title = "Use This"
                primaryButton.action = #selector(confirmWithoutPractice)
            } else {
                instructionLabel.stringValue = "Use \(displayStr) to activate Blackout?\nYou'll type your password to dismiss the black screen.\n\nLet's do a quick practice — the screen will go black, then type your password to dismiss it."
                primaryButton.title = "Confirm"
                primaryButton.action = #selector(confirmAndPractice)
            }
        } else {
            if skipPractice {
                instructionLabel.stringValue = "Use \(displayStr) to toggle Blackout on and off?"
                primaryButton.title = "Use This"
                primaryButton.action = #selector(confirmWithoutPractice)
            } else {
                instructionLabel.stringValue = "Use \(displayStr) to toggle Blackout on and off?\n\nWe'll do a quick practice — the screen will go black, then you press \(displayStr) again to dismiss it."
                primaryButton.title = "Confirm"
                primaryButton.action = #selector(confirmAndPractice)
            }
        }
        primaryButton.target = self
        primaryButton.isHidden = false

        secondaryButton.title = "Try Again"
        secondaryButton.action = #selector(retryCaptureFromConfirm)
        secondaryButton.target = self
        secondaryButton.isHidden = false
    }

    @objc private func confirmAndPractice() {
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        enterPracticePhase()
    }

    @objc private func confirmWithoutPractice() {
        phase = .complete
        if selectedMode == "password" {
            delegate?.setupDidComplete(password: capturedPassword, keyCode: capturedKeyCode, modifiers: capturedModifiers)
        } else {
            delegate?.setupDidComplete(keyCode: capturedKeyCode, modifiers: capturedModifiers)
        }
        close()
    }

    @objc private func retryCaptureFromConfirm() {
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        hotkeyLabel.stringValue = "Listening..."
        if selectedMode == "password" {
            instructionLabel.stringValue = "Choose a hotkey to activate the black screen.\nThis shortcut turns on the overlay — type your password to turn it off.\n\nPress your desired key combination (e.g. Cmd+Shift+B)."
        } else {
            instructionLabel.stringValue = "Choose a hotkey to toggle Blackout on and off.\nThe same combo activates and dismisses the black screen.\n\nPress your desired key combination now (e.g. Cmd+Shift+B)."
        }
        startCapture()
    }

    // MARK: - Phase: Password Entry

    private func enterPasswordEntry() {
        phase = .passwordEntry
        hotkeyLabel.isHidden = true
        errorLabel.isHidden = true
        passwordField.isHidden = false
        passwordField.stringValue = ""
        passwordField.placeholderString = "Enter password"
        instructionLabel.stringValue = "Choose a password to dismiss the black screen.\nYou'll type it character-by-character while the screen is dark.\n\nMinimum 4 characters."

        primaryButton.title = "Next"
        primaryButton.action = #selector(passwordEntryNext)
        primaryButton.target = self
        primaryButton.isHidden = false

        secondaryButton.title = "Back"
        secondaryButton.action = #selector(passwordEntryBack)
        secondaryButton.target = self
        secondaryButton.isHidden = false

        passwordField.target = self
        passwordField.action = #selector(passwordEntryNext)

        window?.makeFirstResponder(passwordField)
    }

    @objc private func passwordEntryNext() {
        let pw = passwordField.stringValue
        guard pw.count >= 4 else {
            showError("Too short!")
            return
        }
        capturedPassword = pw
        enterPasswordConfirm()
    }

    @objc private func passwordEntryBack() {
        passwordField.isHidden = true
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        errorLabel.isHidden = true
        hotkeyLabel.isHidden = false
        enterModeSelect()
    }

    // MARK: - Phase: Password Confirm

    private func enterPasswordConfirm() {
        phase = .passwordConfirm
        errorLabel.isHidden = true
        passwordField.stringValue = ""
        passwordField.placeholderString = "Re-type password"
        instructionLabel.stringValue = "Re-type your password to confirm."

        primaryButton.title = "Confirm"
        primaryButton.action = #selector(passwordConfirmDone)
        primaryButton.target = self
        primaryButton.isHidden = false

        secondaryButton.title = "Back"
        secondaryButton.action = #selector(passwordConfirmBack)
        secondaryButton.target = self
        secondaryButton.isHidden = false

        passwordField.target = self
        passwordField.action = #selector(passwordConfirmDone)

        window?.makeFirstResponder(passwordField)
    }

    @objc private func passwordConfirmDone() {
        guard passwordField.stringValue == capturedPassword else {
            showError("Passwords don't match!")
            passwordField.stringValue = ""
            return
        }
        // Password confirmed — now capture the activation hotkey
        passwordField.isHidden = true
        errorLabel.isHidden = true
        hotkeyLabel.isHidden = false
        instructionLabel.stringValue = "Now choose a hotkey to activate the black screen.\nThis shortcut turns on the overlay — type your password to turn it off.\n\nPress your desired key combination (e.g. Cmd+Shift+B)."
        hotkeyLabel.stringValue = "Listening..."
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        startCapture()
    }

    @objc private func passwordConfirmBack() {
        errorLabel.isHidden = true
        enterPasswordEntry()
    }

    // MARK: - Phase: Practice

    private func enterPracticePhase() {
        phase = .practice
        passwordField.isHidden = true
        errorLabel.isHidden = true
        hotkeyLabel.isHidden = false

        if selectedMode == "password" {
            instructionLabel.stringValue = "The screen will go black. Type your password to dismiss it.\nThis is how you'll unlock every time."
            hotkeyLabel.stringValue = "Ready?"
        } else {
            let displayStr = hotkeyDisplayString(keyCode: capturedKeyCode, modifiers: capturedModifiers)
            instructionLabel.stringValue = "The screen will go black. Press \(displayStr) to dismiss it.\nThis is the same combo you'll use every time."
            hotkeyLabel.stringValue = "Ready?"
        }
        primaryButton.title = "Go!"
        primaryButton.action = #selector(startPractice)
        primaryButton.target = self
        primaryButton.isHidden = false
        secondaryButton.isHidden = true
    }

    @objc private func startPractice() {
        primaryButton.isHidden = true
        if selectedMode == "password" {
            delegate?.setupDidRequestPractice(password: capturedPassword, keyCode: capturedKeyCode, modifiers: capturedModifiers)
        } else {
            delegate?.setupDidRequestPractice(keyCode: capturedKeyCode, modifiers: capturedModifiers)
        }
    }

    func practiceSucceeded() {
        phase = .complete

        let tripleEscapeNote = "\n\nTriple-press Escape is on by default as an emergency dismiss. You can toggle it from the menu bar."
        if selectedMode == "password" {
            instructionLabel.stringValue = "You're all set! Blackout is ready to use.\n\nType your password to dismiss the black overlay anytime." + tripleEscapeNote
        } else {
            instructionLabel.stringValue = "You're all set! Blackout is ready to use.\n\nUse your hotkey to toggle the black overlay anytime." + tripleEscapeNote
        }
        hotkeyLabel.stringValue = "Setup Complete"
        hotkeyLabel.isHidden = false
        primaryButton.title = "Done"
        primaryButton.action = #selector(finishSetup)
        primaryButton.target = self
        primaryButton.isHidden = false
        secondaryButton.isHidden = true

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func finishSetup() {
        if selectedMode == "password" {
            delegate?.setupDidComplete(password: capturedPassword, keyCode: capturedKeyCode, modifiers: capturedModifiers)
        } else {
            delegate?.setupDidComplete(keyCode: capturedKeyCode, modifiers: capturedModifiers)
        }
        close()
    }

    // MARK: - Display helper

    private func hotkeyDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if mods.contains(.control) { parts.append("^") }
        if mods.contains(.option) { parts.append("\u{2325}") }
        if mods.contains(.shift) { parts.append("\u{21E7}") }
        if mods.contains(.command) { parts.append("\u{2318}") }

        let mapping: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
        ]
        parts.append(mapping[keyCode] ?? "Key\(keyCode)")
        return parts.joined()
    }
}
