import AppKit
import Foundation
import WalkingPadKit

/// One text file with everything needed to debug a belt from another Mac: what the app is, what
/// it was told to look for, what it saw, and what it said. Written to the Desktop and revealed in
/// Finder, so the only instruction anyone needs is "send me that file".
enum DiagnosticsReport {
    /// How far back the system log is read. Covers earlier connection attempts and previous
    /// launches, which the in-app event log does not.
    private static let systemLogWindow = "2h"

    /// Everything the app knows right now, as text.
    @MainActor
    static func body(app: AppModel) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let controller = app.controller

        var lines: [String] = []
        lines.append("WalkingPad diagnostics report")
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("App: WalkingPad \(version) (build \(build))")
        lines.append("macOS: \(os)")
        lines.append("")
        lines.append("Belt model setting: \(app.settings.padFamily.label) [\(app.settings.padFamily.rawValue)]")
        lines.append("Verbose Bluetooth log: \(app.isBeltLogVerbose ? "on" : "off")")
        lines.append("Speed ceiling: \(String(format: "%.1f km/h", app.effectiveMaxSpeed))"
                     + (app.settings.isRunningMode ? " (run mode)" : ""))
        lines.append("Connection state: \(controller.state.label)")
        if let rssi = controller.rssi { lines.append("Signal: \(rssi) dBm") }
        if let range = controller.beltSpeedRange {
            lines.append(String(format: "Belt reported range: %.2f–%.2f km/h, step %.2f",
                                range.minKph, range.maxKph, range.incrementKph))
        }
        if let status = controller.status {
            lines.append("Last status frame: \(status.hexDump)")
            lines.append(String(format: "  speed %.1f km/h, state %@, mode %d, %ds, %d x 10 m, %d steps",
                                status.speedKph, status.beltState.label, status.modeRaw,
                                status.elapsed, status.distanceRaw, status.steps))
            lines.append("  received \(status.receivedAt.formatted(date: .omitted, time: .standard))")
        } else {
            lines.append("Last status frame: none received")
        }
        lines.append("")
        lines.append("=== Event log (this launch) ===")
        if controller.log.isEmpty {
            lines.append("(empty)")
        } else {
            for entry in controller.log {
                lines.append("\(entry.at.formatted(date: .omitted, time: .standard))  \(tag(entry.kind)) \(entry.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func tag(_ kind: PadLogEntry.Kind) -> String {
        switch kind {
        case .info: return "    "
        case .warning: return "WARN"
        case .tx: return "TX  "
        case .rx: return "RX  "
        }
    }

    /// The app's own lines from unified logging. Slow (a few seconds), so never on the main thread.
    static func systemLogExcerpt() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--predicate", "subsystem == \"io.nativ.walkingpad\"",
            "--last", systemLogWindow, "--info", "--debug", "--style", "compact",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "(could not read the system log: \(error.localizedDescription))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? "(no entries)" : text
    }

    /// Where the report goes: the Desktop, with a name that sorts by time.
    static func destination(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "WalkingPad-diagnostics-\(formatter.string(from: now)).txt"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return desktop.appendingPathComponent(name)
    }

    /// Build the report, write it to the Desktop, show it in Finder, and say so.
    ///
    /// The system-log read runs off the main thread; everything the user sees happens on it.
    @MainActor
    static func saveAndReveal(app: AppModel, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let head = body(app: app)
        let url = destination()
        DispatchQueue.global(qos: .userInitiated).async {
            let system = systemLogExcerpt()
            let report = head + "\n\n=== System log, last \(systemLogWindow) (log show, subsystem io.nativ.walkingpad) ===\n" + system + "\n"
            let result: Result<URL, Error>
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                if case .success(let saved) = result {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                }
                completion(result)
            }
        }
    }

    /// The plain-words alert that follows a save.
    @MainActor
    static func announce(_ result: Result<URL, Error>) {
        let alert = NSAlert()
        switch result {
        case .success(let url):
            alert.alertStyle = .informational
            alert.messageText = "Diagnostics report saved"
            alert.informativeText = "It is on your Desktop as “\(url.lastPathComponent)” and selected in Finder. "
                + "Send that file to whoever is helping you — it contains everything the app knows about the belt."
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Could not save the report"
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
