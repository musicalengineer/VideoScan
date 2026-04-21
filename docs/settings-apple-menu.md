# Settings Window via Apple Menu (Cmd+,)

**Status:** Shipped
**Last updated:** 2026-04-21
**Author:** Rick + Claude
**TL;DR:** Moved Settings from a tab in the main window to a standalone resizable window accessible via Cmd+, in the Apple menu. Uses a regular `Window` scene, not SwiftUI's built-in `Settings` scene.

## Problem

Settings was a third tab ("Settings") alongside People and Media. This wasted prime tab real estate and buried settings behind a click. The standard macOS convention is Cmd+, in the app menu.

## Solution

### What didn't work

1. **SwiftUI `Settings` scene** — Apple enforces a fixed, non-resizable window. Our settings panel has enough content that users want to see it all at once. Rick tried it and said "nope, not resizable."

2. **`.windowResizability(.contentSize)` on `Settings` scene** — Still enforces fixed size. This modifier only controls what *minimum* the window will accept, but `Settings` scenes are hardcoded non-resizable in AppKit.

### What worked

Use a regular `Window` scene with manual menu wiring:

```swift
// In VideoScanApp.swift
Window("Settings", id: "settings") {
    SettingsTabView(model: model, dashboard: dashboard)
        .frame(minWidth: 600, minHeight: 400)
}
.windowResizability(.contentMinSize)
.defaultPosition(.center)

// Replace the default Settings menu item
CommandGroup(replacing: .appSettings) {
    SettingsMenuItem()
}

// Custom menu item with Cmd+, shortcut
struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") { openWindow(id: "settings") }
            .keyboardShortcut(",", modifiers: .command)
    }
}
```

Key insight: `CommandGroup(replacing: .appSettings)` removes Apple's default "Settings..." item and replaces it with ours that opens our `Window` scene. The keyboard shortcut is explicit because `Window` scenes don't auto-wire Cmd+, like `Settings` scenes do.

### Tab bar change

Removed the Settings tab from the main window's custom tab bar. Only two tabs remain: People and Media.

## Files Modified

- `VideoScanApp.swift` — Added `Window` scene, `CommandGroup`, `SettingsMenuItem`
- `ContentView.swift` — Removed Settings tab from tab bar and switch statement
- `SettingsView.swift` (new) — Contains the extracted SettingsTabView
