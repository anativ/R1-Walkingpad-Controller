import SwiftUI
import WalkingPadKit

/// Freehand editor and transport for a hand-tuned program.
///
/// The research-backed protocols live in `PaceAlgorithmsView`, one box each; this is the place
/// to build something else. Both drive the same `ProgramRunner`, so `isFreehandProgramRunning`
/// keeps this card from claiming a run that an algorithm box started.
struct ProgramView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingSaveAs = false
    @State private var newName = ""

    /// Programs are always expressed in km/h, the belt's native protocol unit: a step is exactly
    /// 0.1 km/h, so offering 0.1 mph steps would promise a precision the hardware cannot honour.
    private static let programUnitLabel = "km/h"

    /// The editor's upper bound. A saved program may exceed the current ceiling; a Slider whose
    /// value sits outside its own range renders a pinned thumb and inert steppers, so the range
    /// stretches to fit rather than silently rewriting what the user configured.
    private var editorMaxSpeed: Double {
        max(app.effectiveMaxSpeed, app.program.maxKph, 1.0)
    }

    var body: some View {
        CardSection(
            title: "Custom program",
            systemImage: "chart.line.uptrend.xyaxis",
            trailing: AnyView(presetMenu)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                kindRow
                if app.isFreehandProgramRunning {
                    runningStatus
                } else {
                    parameters
                    previewRow
                }
                if app.settings.unit == .miles {
                    Text("Programs are set in km/h — the belt's own unit, where one step is exactly 0.1.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let error = app.program.validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let note = app.programCeilingNote {
                    Label(note, systemImage: "arrow.down.to.line.compact")
                        .font(.caption)
                        .foregroundStyle(app.canStartProgram ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                transportRow
            }
        }
        .alert("Save program as", isPresented: $showingSaveAs) {
            TextField("Name", text: $newName)
            Button("Save") {
                app.saveProgramAsNew(named: newName)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Keeps the current settings under a new name.")
        }
    }

    // MARK: Pieces

    private var kindRow: some View {
        HStack {
            Picker("", selection: Binding(
                get: { app.program.kind },
                set: { app.program.kind = $0 }
            )) {
                ForEach(SpeedProgram.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(app.isProgramRunning)
            Text(app.program.kind.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var parameters: some View {
        VStack(spacing: 8) {
            stepperRow(
                "Minimum",
                value: Binding(get: { app.program.minKph }, set: { app.program.minKph = $0 }),
                range: 0.5...editorMaxSpeed,
                step: 0.1,
                format: "%.1f",
                suffix: ProgramView.programUnitLabel,
                display: { $0 }
            )
            stepperRow(
                "Maximum",
                value: Binding(get: { app.program.maxKph }, set: { app.program.maxKph = $0 }),
                range: 0.5...editorMaxSpeed,
                step: 0.1,
                format: "%.1f",
                suffix: ProgramView.programUnitLabel,
                display: { $0 }
            )
            // The researched protocols carry their own block timings — they come from the trials,
            // not from a slider — so these two only appear for the freehand drift.
            if app.program.kind.usesStepAndInterval {
                stepperRow(
                    "Change by",
                    value: Binding(get: { app.program.stepKph }, set: { app.program.stepKph = $0 }),
                    range: 0.1...2.0,
                    step: 0.1,
                    format: "%.1f",
                    suffix: ProgramView.programUnitLabel,
                    display: { $0 }
                )
                stepperRow(
                    "Every",
                    value: Binding(
                        get: { Double(app.program.intervalSeconds) },
                        set: { app.program.intervalSeconds = Int($0) }
                    ),
                    range: 15...3600,
                    step: 15,
                    format: nil,
                    suffix: "min:sec",
                    display: { $0 }
                )
            }
        }
    }

    /// One labelled stepper. `display` converts the stored km/h value for presentation.
    private func stepperRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String?,
        suffix: String,
        display: @escaping (Double) -> Double
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(format.map { String(format: $0, display(value.wrappedValue)) }
                 ?? Metrics.formatDuration(Int(value.wrappedValue)))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
            Text(suffix)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
        .disabled(app.isProgramRunning)
    }

    private var previewRow: some View {
        let speeds = app.program.preview(count: 6)
        return VStack(alignment: .leading, spacing: 4) {
            if speeds.isEmpty {
                EmptyView()
            } else {
                Text(speeds.map { String(format: "%.1f", $0) }
                        .joined(separator: " → ") + " → …")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                CycleStrip(blocks: app.program.cycle)
                Text("\(app.program.blocksPerCycle) blocks per cycle · "
                     + "\(Metrics.formatDuration(Int(app.program.cycleDuration))) per full cycle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var runningStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Image(systemName: app.runner.state.isRising ? "arrow.up.right" : "arrow.down.right")
                    .foregroundStyle(app.runner.state.isRising ? .green : .blue)
                Text(String(format: "%.1f", app.runner.currentKph))
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(ProgramView.programUnitLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StatusChip(text: app.runner.state.tier.label,
                           tint: app.runner.state.tier.tint)
                Spacer()
                if app.runner.isPaused {
                    StatusChip(text: "Paused", systemImage: "pause.fill", tint: .orange)
                } else if let seconds = app.runner.secondsUntilNextChange() {
                    StatusChip(
                        text: "next in \(Metrics.formatDuration(seconds))",
                        systemImage: "timer",
                        tint: .secondary
                    )
                }
            }
            ProgressView(value: app.runner.cycleProgress())
                .progressViewStyle(.linear)
            HStack {
                if let active = app.runner.activeProgram {
                    Text(String(format: "%@ · %.1f–%.1f km/h · %@ cycle",
                                active.name,
                                active.minKph,
                                active.maxKph,
                                Metrics.formatDuration(Int(active.cycleDuration))))
                }
                Spacer()
                Text("block \(app.runner.stepsApplied)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("Changing speed by hand, or stopping the belt, ends the program.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 8) {
            Button {
                // Starting from here takes over from a running algorithm box, which is what
                // pressing Start on a different program plainly means.
                app.isFreehandProgramRunning ? app.stopProgram() : app.startProgram()
            } label: {
                Label(
                    app.isFreehandProgramRunning ? "Stop program" : "Start program",
                    systemImage: app.isFreehandProgramRunning ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(app.isFreehandProgramRunning ? .red : .accentColor)
            .disabled(!app.isConnected
                      || (!app.isFreehandProgramRunning && !app.canStartProgram))

            Button("Save") { app.saveProgram() }
                .disabled(app.isProgramRunning || !app.program.isValid || !app.programHasUnsavedChanges)
                .help("Save these settings as the program's defaults")

            Button("Save as…") {
                newName = app.program.name
                showingSaveAs = true
            }
            .disabled(app.isProgramRunning || !app.program.isValid)
        }
    }

    private var presetMenu: some View {
        Menu {
            if app.savedPrograms.isEmpty {
                Text("No saved programs")
            } else {
                ForEach(app.savedPrograms) { saved in
                    Button {
                        app.loadProgram(saved)
                    } label: {
                        Text(String(format: "%@  (%.1f–%.1f, %.1f, %@)",
                                    saved.name, saved.minKph, saved.maxKph, saved.stepKph,
                                    Metrics.formatDuration(saved.intervalSeconds)))
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(app.savedPrograms) { saved in
                        Button(saved.name) { app.deleteProgram(saved) }
                    }
                }
            }
            Divider()
            Button("Reset to defaults") { app.resetProgramToDefaults() }
        } label: {
            Label("Saved", systemImage: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(app.isProgramRunning)
    }
}
