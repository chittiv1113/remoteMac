import CoreImage.CIFilterBuiltins
import SwiftUI

/// The menu bar popover: the address to open, the pairing PIN, and the controls
/// for taking it away again.
struct MenuView: View {
    @ObservedObject var helper: Helper

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("remoteMac")
                .font(.headline)

            statusRow

            if helper.isRunning {
                connectionSection
                Divider()
                pairingSection
                Divider()
                controlSection
            }

            Divider()
            accessibilitySection

            Divider()
            HStack {
                Spacer()
                Button("Quit") {
                    helper.setPaused(true)       // releases any held button/modifier
                    helper.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear { helper.refreshAccessibility() }
    }

    // MARK: - Sections

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout)
        }
    }

    private var statusColor: Color {
        guard helper.isRunning else { return .red }
        return helper.isPaused ? .orange : .green
    }

    private var statusText: String {
        guard helper.isRunning else {
            return "Not running — ports \(helper.httpPort)/\(helper.controlPort) may be in use"
        }
        return helper.isPaused ? "Paused — input blocked" : "Running"
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open this on your phone, or scan the code")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let qr = Self.makeQR(helper.httpURL) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 130, height: 130)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack {
                Text(helper.httpURL)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { helper.copy(helper.httpURL) }
            }
            if !helper.alternateURL.isEmpty, helper.alternateURL != helper.httpURL {
                Text("or \(helper.alternateURL)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Label(helper.activeControllers > 0 ? "Controller connected" : "Waiting for a phone",
                  systemImage: helper.activeControllers > 0
                      ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                .font(.callout)
                .foregroundStyle(helper.activeControllers > 0 ? .green : .secondary)

            // Counts and a content-free label only. Logging key codes or typed
            // text here would amount to a keylog, which this app does not do.
            Text("Commands: \(helper.commandCount)  ·  last: \(helper.lastCommand)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pairing")
                .font(.caption).bold()
            Text("A phone must enter this PIN once. It is regenerated every launch and never stored.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Text(helper.pin)
                    .font(.system(.title2, design: .monospaced))
                    .bold()
                    .textSelection(.enabled)
                Spacer()
                Button("New PIN") { helper.regeneratePIN() }
            }
            Text(helper.pairedDevices == 1
                 ? "1 paired device"
                 : "\(helper.pairedDevices) paired devices")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { helper.isPaused },
                                 set: { helper.setPaused($0) })) {
                Text("Pause remote control").font(.callout)
            }
            Text("Pausing drops held buttons and modifiers immediately.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Disconnect") { helper.disconnectControllers() }
                Spacer()
                Button("Revoke all devices", role: .destructive) { helper.revokeAllDevices() }
            }
            Text("Revoking forgets every paired phone; they must pair again with a new PIN.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: helper.accessibilityGranted
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(helper.accessibilityGranted ? .green : .orange)
                Text(helper.accessibilityGranted
                     ? "Accessibility granted"
                     : "Accessibility permission needed")
                    .font(.callout)
            }
            if !helper.accessibilityGranted {
                Text("Without it, commands arrive but the pointer and keyboard will not actually move.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Request / open settings") {
                    helper.promptAccessibility()
                    helper.openAccessibilitySettings()
                }
            }
        }
    }

    /// Render the connection URL as a QR code for the phone's camera.
    static func makeQR(_ string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
