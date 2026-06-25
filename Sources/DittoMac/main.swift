import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// main.swift always runs on the main thread; MainActor.assumeIsolated makes that explicit to Swift 6
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
