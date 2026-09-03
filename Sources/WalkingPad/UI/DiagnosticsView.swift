import AppKit
import SwiftUI
import WalkingPadKit

/// Raw protocol view — useful when the belt behaves unexpectedly.
struct DiagnosticsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                row("Belt model", app.padFamily.label)
                if let range = app.controller.beltSpeedRange {
                    row("Belt range", String(format: "%.2f–%.2f km/h, step %.2f",
                                             range.minKph, range.maxKph, range.incrementKph))
                }
            }
            .font(.system(.caption, design: .monospaced))
            if let status = app.status {
                VStack(alignment: .leading, spacing: 4) {
                    row("Last frame", status.hexDump)
                    row("Belt state byte", "\(status.beltState.raw) (\(status.beltState.label))")
                    row("Mode byte", "\(status.modeRaw)")
                    row("Speed raw", "\(status.speedRaw) → \(String(format: "%.1f", status.speedKph)) km/h")
                    row("App speed raw", "\(status.appSpeedRaw) → \(String(format: "%.2f", status.appSpeedKph)) km/h")
                    row("Distance raw", "\(status.distanceRaw) (10 m units)")
                    row("Controller button", "\(status.controllerButton)")
                    row("Updated", status.receivedAt.formatted(date: .omitted, time: .standard))
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            } else {
                Text("No status frame received yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Event log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Verbose", isOn: Binding(
                    get: { app.isBeltLogVerbose },
                    set: { app.setBeltLogVerbose($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Log every command and frame at a level `log show` captures without --debug, "
                      + "and echo a status frame every few seconds. On by default for the Z1 · Z1F.")
                // The whole exchange, ready to paste into a message: this is how a belt that
                // "connects but does nothing" gets diagnosed from another Mac.
                Button("Copy") { copyLog() }.controlSize(.small)
                Button("Clear") { app.controller.clearLog() }.controlSize(.small)
                // And for people who would rather not paste anything: one file on the Desktop.
                Button {
                    app.saveDiagnosticsReport()
                } label: {
                    if app.isSavingDiagnostics {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save report…")
                    }
                }
                .controlSize(.small)
                .disabled(app.isSavingDiagnostics)
                .help("Write a diagnostics report to your Desktop and show it in Finder — the event "
                      + "log, the belt's details and the app's system log — ready to send.")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(app.controller.log) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.at.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .foregroundStyle(color(for: entry.kind))
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: app.controller.log.count) {
                    if let last = app.controller.log.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func copyLog() {
        let header = "WalkingPad diagnostics — belt model: \(app.padFamily.label); state: "
            + app.controller.state.label
            + (app.status.map { "; last frame: \($0.hexDump)" } ?? "")
        let lines = app.controller.log.map { entry in
            "\(entry.at.formatted(date: .omitted, time: .standard))  \(entry.text)"
        }
        let text = ([header] + lines).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func color(for kind: PadLogEntry.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .warning: return .orange
        case .tx: return .blue
        case .rx: return .purple
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":").foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value)
        }
    }
}
