import AppKit
import GhosttyShim

extension NSEvent {
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var event = ghostty_input_key_s()
        event.action = action
        event.keycode = UInt32(keyCode)
        event.text = nil
        event.composing = false
        event.mods = modifierFlags.ghosttyMods

        // Match Ghostty's macOS heuristic: control and command don't contribute
        // to text translation; everything else may have been consumed.
        event.consumed_mods = (translationMods ?? modifierFlags)
            .subtracting([.control, .command])
            .ghosttyMods

        event.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                event.unshifted_codepoint = codepoint.value
            }
        }

        return event
    }

    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // Let Ghostty encode control characters itself so combinations like
            // Ctrl+Enter and Ctrl+C follow its key encoder rules.
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            // AppKit uses the private-use area for function/special keys.
            // Do not send those as text; the keycode/unshifted fields identify them.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}

extension NSEvent.ModifierFlags {
    var ghosttyScrollMods: ghostty_input_scroll_mods_t {
        ghostty_input_scroll_mods_t(ghosttyMods.rawValue)
    }

    var ghosttyMods: ghostty_input_mods_e {
        var mods = UInt32(GHOSTTY_MODS_NONE.rawValue)

        if contains(.shift) { mods |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if contains(.control) { mods |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if contains(.option) { mods |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if contains(.command) { mods |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if contains(.capsLock) { mods |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }

        let rawFlags = rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= UInt32(GHOSTTY_MODS_SHIFT_RIGHT.rawValue) }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= UInt32(GHOSTTY_MODS_CTRL_RIGHT.rawValue) }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= UInt32(GHOSTTY_MODS_ALT_RIGHT.rawValue) }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= UInt32(GHOSTTY_MODS_SUPER_RIGHT.rawValue) }

        return ghostty_input_mods_e(mods)
    }
}
