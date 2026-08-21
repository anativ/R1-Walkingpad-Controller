import SwiftUI
import WalkingPadKit

extension PaceTier {
    /// Tier colours live here, not in WalkingPadKit — the kit stays free of UI.
    var tint: Color {
        switch self {
        case .easy: return .teal
        case .steady: return .blue
        case .brisk: return .orange
        case .surge: return .red
        }
    }
}

/// The research-backed pace algorithms, one box each, plus the mode that decides how fast they
/// are allowed to walk you.
struct PaceAlgorithmsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        CardSection(title: "Pace algorithms", systemImage: "figure.walk.motion") {
            VStack(alignment: .leading, spacing: 12) {
                modeRow
                anchorRow
                Divider()
                ForEach(PaceAlgorithm.all) { algorithm in
                    AlgorithmBox(algorithm: algorithm)
                }
                Text("Walking at one unvarying pace for two hours is the thing these are meant to "
                     + "replace. Each one changes the pace on a schedule taken from published "
                     + "research — open Research in any box for what was actually measured.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Mode

    private var modeRow: some View {
        HStack(spacing: 6) {
            ForEach(PaceMode.allCases) { mode in
                Button {
                    app.setPaceMode(mode)
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(app.settings.paceMode == mode ? .accentColor : nil)
                .help(mode.detail)
            }
        }
    }

    private var anchorRow: some View {
        let mode = app.settings.paceMode
        let range = mode.anchorRange
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Anchor pace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(app.settings.anchorRaw(for: mode)) },
                        set: { app.setAnchorRaw(Int($0.rounded()), for: mode) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
                Text(String(format: "%.1f", Double(app.settings.anchorRaw(for: mode)) / 10))
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                Text("km/h")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(mode.detail + " Every algorithm places its own band around this pace.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One algorithm: what it is, what it will do to the belt, and a button to run it.
struct AlgorithmBox: View {
    @EnvironmentObject private var app: AppModel
    let algorithm: PaceAlgorithm
    @State private var showingEvidence = false

    private var program: SpeedProgram { app.bandedProgram(for: algorithm) }
    private var isRunning: Bool { app.isRunning(algorithm) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(algorithm.goal)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isRunning {
                runningStatus
            } else {
                summary
                CycleStrip(blocks: program.cycle)
            }
            if let note = app.ceilingNote(for: program) {
                Label(note, systemImage: "arrow.down.to.line.compact")
                    .font(.caption2)
                    .foregroundStyle(app.canStart(algorithm) ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            evidenceDisclosure
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isRunning ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isRunning ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2))
        )
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(algorithm.name)
                .font(.callout.weight(.semibold))
            if isRunning {
                StatusChip(text: "running", systemImage: "waveform", tint: .accentColor)
            }
            Spacer()
            Button {
                app.toggleAlgorithm(algorithm)
            } label: {
                Label(isRunning ? "Stop" : "Start",
                      systemImage: isRunning ? "stop.fill" : "play.fill")
                    .font(.caption)
                    .frame(minWidth: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRunning ? .red : .accentColor)
            .disabled(!app.isConnected || (!isRunning && !app.canStart(algorithm)))
            .help(app.isConnected
                  ? algorithm.shape
                  : "Connect to the belt to run an algorithm")
        }
    }

    private var summary: some View {
        let work = program.workSecondsPerCycle
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.1f – %.1f km/h  ·  %@", program.minKph, program.maxKph,
                        algorithm.shape))
                .font(.caption)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text("\(Metrics.formatDuration(Int(program.cycleDuration))) cycle"
                 + (work > 0
                    ? " · \(Metrics.formatDuration(work)) of it brisk"
                    : " · no hard blocks"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var runningStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Image(systemName: app.runner.state.isRising ? "arrow.up.right" : "arrow.down.right")
                    .foregroundStyle(app.runner.state.isRising ? .green : .blue)
                Text(String(format: "%.1f", app.runner.currentKph))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("km/h")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                StatusChip(text: app.runner.state.tier.label,
                           tint: app.runner.state.tier.tint)
                Spacer()
                if app.runner.isPaused {
                    StatusChip(text: "Paused", systemImage: "pause.fill", tint: .orange)
                } else if let seconds = app.runner.secondsUntilNextChange() {
                    StatusChip(text: "next in \(Metrics.formatDuration(seconds))",
                               systemImage: "timer", tint: .secondary)
                }
            }
            CycleStrip(blocks: app.runner.activeProgram?.cycle ?? [],
                       highlighted: app.runner.state.index,
                       progress: app.runner.cycleProgress())
            HStack(spacing: 10) {
                Text(app.runner.state.tier.feel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let dose = app.runner.doseProgress, let target = algorithm.sessionWorkSeconds {
                    Text("brisk \(Metrics.formatDuration(Int(app.runner.workSeconds)))"
                         + " / \(Metrics.formatDuration(target))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(dose >= 1 ? Color.green : Color.secondary)
                        .help("One researched session's worth of fast walking. "
                              + algorithm.cadence)
                }
            }
        }
    }

    private var evidenceDisclosure: some View {
        DisclosureGroup(isExpanded: $showingEvidence) {
            VStack(alignment: .leading, spacing: 6) {
                Text(algorithm.evidence)
                    .fixedSize(horizontal: false, vertical: true)
                Text(algorithm.cadence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
            .padding(.top, 4)
        } label: {
            Text("Research")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// The cycle drawn to scale: one segment per block, width proportional to its length, coloured by
/// how hard it is. Makes "ten minutes easy then ninety seconds hard" legible at a glance.
struct CycleStrip: View {
    let blocks: [PaceBlock]
    var highlighted: Int? = nil
    var progress: Double? = nil

    private var total: Double {
        max(1, Double(blocks.reduce(0) { $0 + $1.seconds }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                // Widths are computed in Double and converted once: mixing CGFloat and Double
                // arithmetic inline is the kind of thing that compiles differently by platform.
                let full = Double(geometry.size.width)
                ZStack(alignment: .leading) {
                    HStack(spacing: 1) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                            Rectangle()
                                .fill(item.element.tier.tint
                                    .opacity(item.offset == highlighted ? 1 : 0.45))
                                .frame(width: CGFloat(max(1,
                                    full * Double(item.element.seconds) / total - 1)))
                        }
                    }
                    if let progress {
                        Rectangle()
                            .fill(.primary.opacity(0.7))
                            .frame(width: 1.5)
                            .offset(x: CGFloat(full * min(1, max(0, progress))))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            if !blocks.isEmpty {
                Text(legend)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// A compact reading of the cycle: consecutive blocks at the same speed are merged, and a long
    /// cycle is summarised rather than listed block by block.
    private var legend: String {
        var parts: [String] = []
        var index = 0
        while index < blocks.count, parts.count < 4 {
            let block = blocks[index]
            var seconds = block.seconds
            var next = index + 1
            while next < blocks.count, blocks[next].raw == block.raw,
                  blocks[next].tier == block.tier {
                seconds += blocks[next].seconds
                next += 1
            }
            parts.append(String(format: "%.1f for %@", block.kph,
                                Metrics.formatDuration(seconds)))
            index = next
        }
        if index < blocks.count { parts.append("…") }
        return parts.joined(separator: " · ")
    }
}
