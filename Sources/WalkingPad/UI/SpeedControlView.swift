import SwiftUI
import WalkingPadKit

/// Speed dial, presets, and start/stop. The belt only accepts a new speed roughly
/// every 0.7 s, so the slider updates locally and commits on release / after a pause.
struct SpeedControlView: View {
    @EnvironmentObject private var app: AppModel

    /// Presets suited to the ceiling in force — a different ladder once running is unlocked.
    private var presets: [Double] { app.speedPresets }

    var body: some View {
        CardSection(title: "Speed", systemImage: "speedometer") {
            VStack(spacing: 14) {
                modeRow
                targetRow
                slider
                presetRow
                transportRow
            }
        }
    }

    /// Walk / Run. Running mode only unlocks the range up to the belt's maximum — it never
    /// changes the current speed, so switching to it cannot make the belt speed up under you.
    private var modeRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { app.settings.isRunningMode },
                set: { app.setRunningMode($0) }
            )) {
                Text("Walk").tag(false)
                Text("Run").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Text(app.settings.isRunningMode
                 ? String(format: "Up to %.0f %@ — the belt's maximum",
                          app.settings.unit.speed(fromKph: app.effectiveMaxSpeed),
                          app.settings.unit.speedSuffix)
                 : String(format: "Up to %.1f %@ — raise it in Settings, or switch to Run",
                          app.settings.unit.speed(fromKph: app.effectiveMaxSpeed),
                          app.settings.unit.speedSuffix))
                .font(.caption2)
                .foregroundStyle(app.settings.isRunningMode ? Color.orange : Color.secondary)
            Spacer()
        }
    }

    private var targetRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text("Target")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f", app.settings.unit.speed(fromKph: app.desiredSpeedKph)))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(app.settings.unit.speedSuffix)
                .font(.caption)
                .foregroundStyle(.secondary)
            if app.isSpeedPending {
                ProgressView()
                    .controlSize(.small)
                    .help("Waiting for the belt to confirm")
            }
        }
    }

    private var slider: some View {
        HStack(spacing: 10) {
            Button {
                app.nudgeSpeed(by: -0.5)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 26, height: 22)
            }
            .disabled(!app.isConnected || app.desiredSpeedKph <= 0)
            .keyboardShortcut(.downArrow, modifiers: [])
            .help("Slower (↓)")

            Slider(
                value: $app.desiredSpeedKph,
                in: 0...app.effectiveMaxSpeed,
                step: 0.1,
                onEditingChanged: { editing in
                    // Commit once the drag ends; mid-drag writes would be dropped by the belt.
                    if !editing { app.commitSpeed(app.desiredSpeedKph) }
                }
            )
            .disabled(!app.isConnected)

            Button {
                app.nudgeSpeed(by: 0.5)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 22)
            }
            .disabled(!app.isConnected || app.desiredSpeedKph >= app.effectiveMaxSpeed)
            .keyboardShortcut(.upArrow, modifiers: [])
            .help("Faster (↑)")
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.self) { preset in
                Button {
                    app.commitSpeed(preset)
                } label: {
                    Text(String(format: "%.1f", app.settings.unit.speed(fromKph: preset)))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(abs(app.desiredSpeedKph - preset) < 0.05 ? .accentColor : nil)
                .disabled(!app.isConnected)
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            Button {
                app.start()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.isConnected || app.isMoving)
            .keyboardShortcut("s", modifiers: .command)

            Button {
                app.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!app.isConnected)
            // Space is the panic button: it always stops, moving or not.
            .keyboardShortcut(.space, modifiers: [])
            .help("Stop the belt (Space)")
        }
    }
}

/// Belt operating mode picker.
struct ModePickerView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        CardSection(title: "Mode", systemImage: "dial.medium") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(PadMode.allCases, id: \.self) { mode in
                        Button {
                            app.setMode(mode)
                        } label: {
                            Text(mode.label)
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(app.status?.mode == mode ? .accentColor : nil)
                        .disabled(!app.isConnected)
                        .help(mode.help)
                    }
                }
                Text(app.status?.mode?.help ?? "Belt mode is reported once connected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
