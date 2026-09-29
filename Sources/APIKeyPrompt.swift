import Cocoa

extension Notification.Name {
    /// Posted (on main) after the stored API key is saved or removed.
    static let worktimelapsAPIKeyChanged = Notification.Name("WorkTimeLaps.apiKeyChanged")
}

/// NSSecureTextField subclass that handles cmd-C / cmd-V / cmd-X / cmd-A
/// itself. Inside an NSAlert's modal event loop the Edit menu's actions
/// don't always reach the accessory view, so paste would silently fail.
final class PasteableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a":
                if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The "Anthropic API Key" dialog, shared by the menu and Settings.
@MainActor
enum APIKeyPrompt {

    /// Shows the dialog. Returns true when the stored key changed.
    @discardableResult
    static func run() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = """
        WorkTimeLaps sends each screenshot to Claude Haiku to label what you're working on and to \
        catch visible secrets, and asks Claude to write your diary from the day's text log. \
        Screenshots of blocked apps are never sent.

        The key is stored in your keychain and only ever sent to api.anthropic.com.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let existing = APIKeyStore.load()
        if existing != nil {
            alert.addButton(withTitle: "Remove Key")
        }

        let field = PasteableSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty Save keeps the existing key rather than deleting it.
            guard !trimmed.isEmpty, trimmed != existing else { return false }
            APIKeyStore.save(trimmed)
        case .alertThirdButtonReturn:
            APIKeyStore.clear()
        default:
            return false
        }
        return true
    }
}
