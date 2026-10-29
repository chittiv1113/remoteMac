import AppKit
import Foundation

/// Enumerates installed applications.
///
/// Two consumers, and the second is the one that matters:
///   - `json()` feeds the phone's app picker in the deck editor.
///   - `allowedPaths()` is the allowlist `DeckValidator` checks launch targets
///     against. Because the set is built by scanning the standard application
///     directories, a target like `/Users/me/evil.app` or `/bin/sh` is simply
///     not in it, and the deck write is rejected.
///
/// Both results are cached: enumerating is cheap, but rendering an icon per app
/// is not, and the picker wants icons.
enum AppList {
    private struct App { let name: String; let path: String }

    private static let lock = NSLock()
    private static var cachedApps: [App]?
    private static var cachedJSON: String?

    private static let searchDirectories = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    /// Icon edge length in **pixels**, not points.
    ///
    /// That distinction is the whole reason this is written the way it is.
    /// Drawing into `NSImage(size:)` renders at the current display's scale, so
    /// on a Retina Mac a "36 point" icon becomes a 72×72 bitmap and PNG-encodes
    /// to roughly 24 KB — past `DeckValidator.maxIconDataURIBytes`, which made
    /// the Mac reject any deck containing a picked app. Rendering into a
    /// bitmap of explicit pixel dimensions gives the same result on every
    /// display, at about 6 KB.
    private static let iconPixels = 48

    /// Build the enumeration and the picker payload ahead of time, so the first
    /// `apps.get` does not pay for a few hundred icon renders.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = json() }
    }

    /// Launch-target allowlist. Safe to call from any thread.
    static func allowedPaths() -> Set<String> {
        Set(apps().map(\.path))
    }

    /// `[{name, path, icon}]` for the app picker.
    static func json() -> String {
        lock.lock()
        let cached = cachedJSON
        lock.unlock()
        if let cached { return cached }

        let payload = apps().map { app in
            ["name": app.name, "path": app.path, "icon": iconDataURI(path: app.path) ?? ""]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
        let result = String(data: data, encoding: .utf8) ?? "[]"

        lock.lock(); cachedJSON = result; lock.unlock()
        return result
    }

    private static func apps() -> [App] {
        lock.lock()
        let cached = cachedApps
        lock.unlock()
        if let cached { return cached }

        var found: [App] = []
        var seen = Set<String>()
        for directory in searchDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
            else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let name = (entry as NSString).deletingPathExtension
                // First match wins, so /Applications shadows the system copy of
                // an app the user has replaced.
                guard seen.insert(name).inserted else { continue }
                found.append(App(name: name, path: (directory as NSString).appendingPathComponent(entry)))
            }
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        lock.lock(); cachedApps = found; lock.unlock()
        return found
    }

    /// Render an app's icon to a base64 PNG data URI at a fixed pixel size.
    private static func iconDataURI(path: String) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let side = iconPixels

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // Without this the rep reports its size in points, and drawing scales.
        bitmap.size = NSSize(width: side, height: side)

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
