import SwiftUI
import WalkingPadKit

struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ConnectionBar()
                HeroSpeedView()
                SpeedControlView()
                PaceAlgorithmsView()
                ProgramView()
                MetricsGrid()
                CardSection(title: "Session speed", systemImage: "chart.xyaxis.line") {
                    SpeedChartView(
                        samples: app.tracker.samples,
                        unit: app.settings.unit,
                        ceiling: app.effectiveMaxSpeed
                    )
                }
                ModePickerView()
                AllTimeSummaryView()
                StoredSessionView()
                DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                    DiagnosticsView()
                }
                .font(.subheadline.weight(.semibold))
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .task { app.reapplyDockIconPolicy() }
    }
}

/// Connection state and belt identity.
struct ConnectionBar: View {
    @EnvironmentObject private var app: AppModel

    private var tint: Color {
        if app.isConnected { return .green }
        if app.controller.state.isBusy { return .orange }
        switch app.controller.state {
        case .bluetoothUnavailable: return .red
        case .notFound: return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.controller.state.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let rssi = app.controller.rssi, app.isConnected {
                    Text("Signal \(rssi) dBm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let hint = app.controller.state.hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if app.controller.state.isBusy {
                ProgressView().controlSize(.small)
            }
            Button(buttonTitle) { app.toggleConnection() }
                .controlSize(.small)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var buttonTitle: String {
        if app.isConnected || app.controller.state.isBusy { return "Disconnect" }
        if case .notFound = app.controller.state { return "Try again" }
        return "Connect"
    }
}

/// Big current-speed readout with belt state.
struct HeroSpeedView: View {
    @EnvironmentObject private var app: AppModel

    private var stateTint: Color {
        guard let state = app.status?.beltState else { return .secondary }
        switch state {
        case .running: return .green
        case .starting: return .orange
        case .stopped, .standby: return .secondary
        case .other: return .blue
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", app.settings.unit.speed(fromKph: app.beltSpeedKph)))
                    .font(.system(size: 72, weight: .thin, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: app.beltSpeedKph)
                Text(app.settings.unit.speedSuffix)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                StatusChip(
                    text: app.status?.beltState.label ?? "—",
                    systemImage: app.isMoving ? "figure.walk.motion" : "figure.stand",
                    tint: stateTint
                )
                if let mode = app.status?.mode {
                    StatusChip(text: mode.label, systemImage: "dial.medium", tint: .blue)
                }
                if let button = app.status?.controllerButton, button != 0 {
                    StatusChip(text: "Remote \(button)", systemImage: "av.remote", tint: .purple)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Everything the belt reports, plus what we derive from it.
struct MetricsGrid: View {
    @EnvironmentObject private var app: AppModel

    private var unit: DistanceUnit { app.settings.unit }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            MetricTile(
                label: "Time",
                value: Metrics.formatDuration(app.status?.elapsed ?? 0),
                systemImage: "clock",
                tint: .blue
            )
            MetricTile(
                label: "Distance",
                value: String(format: "%.2f", unit.distance(fromKm: app.status?.distanceKm ?? 0)),
                unit: unit.distanceSuffix,
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                tint: .teal
            )
            MetricTile(
                label: "Steps",
                value: "\(app.status?.steps ?? 0)",
                systemImage: "shoeprints.fill",
                tint: .indigo
            )
            // The calorie figure depends on body data most people never find in Settings, so the
            // number itself is the way in: click it to go straight there.
            SettingsLink {
                MetricTile(
                    label: "Calories",
                    value: String(format: "%.0f", app.sessionKcal),
                    unit: "kcal",
                    systemImage: "flame.fill",
                    tint: .orange,
                    footnote: app.isBodyDataConfigured
                        ? app.kcalFootnote
                        : "set your weight →"
                )
            }
            .buttonStyle(.plain)
            .help("Set your weight and height so this estimate is right")
            MetricTile(
                label: "Pace",
                value: Metrics.formatPace(app.paceMinPerUnit),
                unit: unit.paceSuffix,
                systemImage: "stopwatch",
                tint: .pink
            )
            MetricTile(
                label: "Cadence",
                value: String(format: "%.0f", app.tracker.cadence),
                unit: "spm",
                systemImage: "metronome",
                tint: .mint
            )
            MetricTile(
                label: "Avg speed",
                value: String(format: "%.1f", unit.speed(fromKph: app.averageSpeedKph)),
                unit: unit.speedSuffix,
                systemImage: "chart.line.flattrend.xyaxis",
                tint: .cyan
            )
            MetricTile(
                label: "Peak",
                value: String(format: "%.1f", unit.speed(fromKph: app.tracker.peakSpeedKph)),
                unit: unit.speedSuffix,
                systemImage: "arrow.up.right",
                tint: .red
            )
        }
    }
}

/// Lifetime totals, with a way through to the full history.
struct AllTimeSummaryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let totals = app.lifetimeTotalsIncludingCurrent
        let unit = app.settings.unit
        return CardSection(
            title: "All time",
            systemImage: "sum",
            trailing: AnyView(
                Button("History…") { openWindow(id: "history") }
                    .controlSize(.small)
            )
        ) {
            if totals.sessionCount == 0 && !app.isRecordingWalk {
                Text("Walks are saved automatically. Your totals and history will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 22) {
                    figure("Distance",
                           String(format: "%.1f %@",
                                  unit.distance(fromKm: totals.distanceKm), unit.distanceSuffix))
                    figure("Walk time", Metrics.formatDuration(totals.durationSeconds))
                    figure("Avg speed",
                           String(format: "%.1f %@",
                                  unit.speed(fromKph: totals.averageSpeedKph), unit.speedSuffix))
                    figure("Walks", "\(totals.sessionCount)")
                    Spacer()
                    if app.isRecordingWalk {
                        StatusChip(text: "recording", systemImage: "record.circle", tint: .green)
                    }
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

/// The last session the belt has stored internally.
struct StoredSessionView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        CardSection(
            title: "Belt's stored session",
            systemImage: "internaldrive",
            trailing: AnyView(
                Button("Refresh") { app.refreshStoredSession() }
                    .controlSize(.small)
                    .disabled(!app.isConnected)
            )
        ) {
            if let record = app.controller.lastRecord {
                HStack(spacing: 20) {
                    labelled("Time", Metrics.formatDuration(record.elapsed))
                    labelled(
                        "Distance",
                        String(format: "%.2f %@",
                               app.settings.unit.distance(fromKm: record.distanceKm),
                               app.settings.unit.distanceSuffix)
                    )
                    labelled("Steps", "\(record.steps)")
                    Spacer()
                }
            } else {
                Text(app.isConnected
                     ? "No stored session reported yet."
                     : "Connect to read the belt's last stored session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}
