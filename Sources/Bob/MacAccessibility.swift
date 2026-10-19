import AppKit
import ApplicationServices
import CryptoKit
import BobCore

/// Accessibility IPC stays off the UI actor. References belong to one window and snapshot.
actor MacAccessibility {
    private struct Target {
        let element: AXUIElement
        let description: ComputerElement
        let valueHash: Data
    }
    private var window: AXUIElement?
    private var app: AXUIElement?
    private var snapshotID = ""
    private var targets: [Int: Target] = [:]
    private var windowFrame = CGRect.zero
    private var windowTitle = ""

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
    private func hash(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
    func mainWindowFrame(appPID: Int32) -> CGRect? {
        let app = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let value = attribute(app, kAXMainWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return frame(value as! AXUIElement)
    }
    private func label(_ element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            let value = string(element, key)
            if !value.isEmpty { return String(value.prefix(200)) }
        }
        return ""
    }
    private func secure(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute), subrole = string(element, kAXSubroleAttribute)
        let name = label(element).lowercased()
        return role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole || ["password", "passcode", "verification code", "authentication code", "one-time code", "security code", "card number", "credit card"].contains(where: { name.contains($0) })
    }
    func capture(appPID: Int32, frame expected: CGRect, title: String, id: String) throws -> [ComputerElement] {
        targets = [:]; window = nil; snapshotID = ""
        let application = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        // Chromium and other providers can defer their full tree until a client requests it.
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(application, name as CFString, &settable) == .success, settable.boolValue {
                _ = AXUIElementSetAttributeValue(application, name as CFString, kCFBooleanTrue)
            }
        }
        var rawWindows: CFTypeRef?
        let windowStatus = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows)
        var windows = rawWindows as? [AXUIElement] ?? []
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let value = attribute(application, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let candidate = value as! AXUIElement
                if !windows.contains(where: { CFEqual($0, candidate) }) { windows.append(candidate) }
            }
        }
        // Some accessibility providers expose windows only through AXChildren.
        let children = attribute(application, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children.prefix(32) where string(child, kAXRoleAttribute) == kAXWindowRole {
            if !windows.contains(where: { CFEqual($0, child) }) { windows.append(child) }
        }
        let matches = windows.filter { candidate in
            guard string(candidate, kAXRoleAttribute) == kAXWindowRole, let bounds = frame(candidate), near(bounds, expected) else { return false }
            return title.isEmpty || string(candidate, kAXTitleAttribute) == title
        }
        guard matches.count == 1, let selected = matches.first else {
            throw BobError.message("This app does not expose a uniquely matching accessible window (AX status \(windowStatus.rawValue)). Bring the target window fully on screen or select another window. No input was sent.")
        }
        app = application; window = selected; windowFrame = expected; windowTitle = string(selected, kAXTitleAttribute); snapshotID = id
        let deadline = Date().addingTimeInterval(2)
        var elements: [ComputerElement] = [], visited: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 16, elements.count < 220, Date() < deadline, !Task.isCancelled else { return }
            guard !visited.contains(where: { CFEqual($0, element) }) else { return }
            visited.append(element)
            let role = string(element, kAXRoleAttribute), protected = secure(element)
            if let bounds = frame(element), bounds.intersects(expected), bounds.width > 0, bounds.height > 0 {
                let raw = protected ? "" : string(element, kAXValueAttribute)
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) && settable.boolValue
                let item = ComputerElement(reference: elements.count + 1, role: role, label: label(element), value: String(raw.prefix(1500)), frame: bounds, editable: editable, secure: protected)
                elements.append(item); targets[item.reference] = Target(element: element, description: item, valueHash: hash(raw))
            }
            guard !protected else { return }
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children.prefix(300) { walk(child, depth: depth + 1) }
        }
        walk(selected, depth: 0)
        try Task.checkCancellation()
        return elements
    }
    func validate(id: String, reference: Int? = nil, typing: Bool = false) throws {
        try Task.checkCancellation()
        guard id == snapshotID, let window, let current = frame(window), near(current, windowFrame), string(window, kAXTitleAttribute) == windowTitle else {
            throw BobError.message("The app window changed. Capture fresh app state.")
        }
        if let reference {
            guard let target = targets[reference], let bounds = frame(target.element), near(bounds, target.description.frame), label(target.element) == target.description.label,
                  !secure(target.element) else { throw BobError.message("The control changed or is protected. Capture fresh app state.") }
            if typing {
                guard target.description.editable, hash(string(target.element, kAXValueAttribute)) == target.valueHash else {
                    throw BobError.message("The text field changed after capture. Read it again before replacing its content.")
                }
            }
        }
    }
    func press(id: String, reference: Int) throws -> Bool {
        try validate(id: id, reference: reference)
        guard let target = targets[reference] else { return false }
        return AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
    }
    func replaceText(id: String, reference: Int, text: String) throws {
        try validate(id: id, reference: reference, typing: true)
        guard let target = targets[reference], AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw BobError.message("This app does not support accessibility text replacement. Enter the text manually.")
        }
    }
    func raise(id: String) throws {
        try validate(id: id)
        guard let window, AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { throw BobError.message("Could not raise the selected app window.") }
    }
    func validateKeyboard(id: String) throws {
        try validate(id: id)
        guard let app, let window, let focusedWindow = attribute(app, kAXFocusedWindowAttribute), CFEqual(focusedWindow, window),
              let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw BobError.message("The selected window does not have keyboard focus. Capture fresh app state.")
        }
        guard !secure(focused as! AXUIElement) else { throw BobError.message("Keyboard input into a protected control requires manual interaction.") }
    }
    func invalidate() { snapshotID = ""; targets = [:]; window = nil; app = nil }
}
