import AppKit

/// Lets wooloo write a PNG of its own main window on request, so a remote session (ssh from the PC) can look at the
/// real UI. It renders only this app's window through AppKit, never the desktop or another app, so it needs no
/// Screen Recording permission.
///
/// Trigger: create `~/.local/share/wooloo-companion/shot-request`. Its text may name an output path ending in `.png`;
/// otherwise the PNG goes to `~/.local/share/wooloo-companion/shot.png`. The request file is deleted once handled.
@MainActor
enum SelfShot {
    private static var timer: Timer?
    /// A one-line description of the live store, logged with every screenshot.
    static var stateProvider: (() -> String)?

    private static var companionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/wooloo-companion")
    }

    /// Polls once a second, and does nothing while wooloo is not the active app.
    static func start() {
        guard timer == nil else { return }
        let poll = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in SelfShot.tick() }
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    private static func tick() {
        guard NSApp.isActive else { return }
        let request = companionDirectory.appendingPathComponent("shot-request")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let text = (try? String(contentsOf: request, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: request)
        let output = outputURL(from: text)
        write(to: output)
    }

    /// An absolute or `~` path ending in `.png` from the request file, else the default file.
    private static func outputURL(from text: String) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), expanded.hasSuffix(".png") {
            return URL(fileURLWithPath: expanded)
        }
        return companionDirectory.appendingPathComponent("shot.png")
    }

    /// The window the person is looking at: the main window, else the key window, else any visible one.
    private static func targetWindow() -> NSWindow? {
        if let main = NSApp.mainWindow, main.isVisible { return main }
        if let key = NSApp.keyWindow, key.isVisible { return key }
        for window in NSApp.windows where window.isVisible && window.contentView != nil && !(window is NSPanel) {
            return window
        }
        return nil
    }

    static func snapshotPNG() -> Data? {
        guard let window = targetWindow() else { return nil }
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func write(to url: URL) {
        guard let data = snapshotPNG() else {
            PeerSyncLog.write("selfshot: no window to capture")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            PeerSyncLog.write("selfshot: wrote \(data.count) bytes to \(url.lastPathComponent)")
            if let state = stateProvider?() { PeerSyncLog.write("selfshot-state: \(state)") }
        } catch {
            PeerSyncLog.write("selfshot: write failed: \(error.localizedDescription)")
        }
    }

    /// View > Save Window Screenshot: the same PNG, on the Desktop.
    static func saveToDesktop() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        write(to: desktop.appendingPathComponent("wooloo window \(stamp).png"))
    }
}
