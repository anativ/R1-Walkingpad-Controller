import Charts
import SwiftUI
import UniformTypeIdentifiers
import WalkingPadKit

/// The metric a history chart is showing.
enum HistoryMetric: String, CaseIterable, Identifiable {
    case distance, time, steps, calories

    var id: String { rawValue }

    var label: String {
        switch self {
        case .distance: return "Distance"
        case .time: return "Time"
        case .steps: return "Steps"
        case .calories: return "Calories"
        }
    }

    var tint: Color {
        switch self {
        case .distance: return .teal
        case .time: return .blue
        case .steps: return .indigo
        case .calories: return .orange
        }
    }

    /// The plotted value for a bucket, in the unit shown on the axis.
    func value(_ totals: WalkTotals, unit: DistanceUnit) -> Double {
        switch self {
        case .distance: return unit.distance(fromKm: totals.distanceKm)
        case .time: return Double(totals.durationSeconds) / 60
        case .steps: return Double(totals.steps)
        case .calories: return totals.kcal
        }
    }

    func axisLabel(unit: DistanceUnit) -> String {
        switch self {
        case .distance: return unit.distanceSuffix
        case .time: return "minutes"
        case .steps: return "steps"
        case .calories: return "kcal"
        }
    }
}

/// Everything the History screen displays, derived once instead of on every render.
///
/// The app republishes on every belt status frame (~1 Hz while connected), and this screen would
/// otherwise re-sort the whole history and rerun a dozen grouping passes every second just for
/// being open.
private struct HistorySnapshot {
    var sessions: [WalkSession] = []
    var lifetime = WalkTotals()
    var buckets: [WalkBucket] = []
    var averages: [(period: WalkPeriod, totals: WalkTotals, activeCount: Int)] = []
    var streak = 0
    var bestDay: WalkBucket?
    var bestMonth: WalkBucket?
    var longestWalk: Int?

    static func make(
        sessions: [WalkSession], lifetime: WalkTotals, period: WalkPeriod, bucketCount: Int, now: Date
    ) -> HistorySnapshot {
        var snapshot = HistorySnapshot()
        snapshot.sessions = sessions
        snapshot.lifetime = lifetime
        snapshot.buckets = WalkStats.continuousBuckets(
            sessions, period: period, count: bucketCount, endingAt: now
        )
        snapshot.averages = WalkPeriod.allCases.map { period in
            let grouped = WalkStats.buckets(sessions, period: period)
            return (
                period,
                WalkStats.averagePerActivePeriod(sessions, period: period),
                grouped.count
            )
        }
        snapshot.streak = WalkStats.currentDayStreak(sessions, now: now)
        snapshot.bestDay = WalkStats.best(sessions, period: .day)
        snapshot.bestMonth = WalkStats.best(sessions, period: .month)
        snapshot.longestWalk = sessions.map(\.durationSeconds).max()
        return snapshot
    }
}

/// Identifies the inputs a snapshot depends on. When this changes, and only then, we recompute.
private struct SnapshotKey: Equatable {
    var revision: Int
    var period: WalkPeriod
    var day: Date
}

struct HistoryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var period: WalkPeriod = .day
    @State private var metric: HistoryMetric = .distance
    @State private var selection = Set<UUID>()
    @State private var isExporting = false
    @State private var confirmingDeleteAll = false
    @State private var snapshot = HistorySnapshot()
    /// Built when the user actually asks to export, not on every render.
    @State private var exportText = ""

    private var unit: DistanceUnit { app.settings.unit }
    private var sessions: [WalkSession] { snapshot.sessions }

    private var snapshotKey: SnapshotKey {
        // The day is part of the key so a window left open overnight recomputes its buckets and
        // streak against the new today rather than yesterday's.
        SnapshotKey(
            revision: app.store.revision,
            period: period,
            day: Calendar.current.startOfDay(for: Date())
        )
    }

    /// How many buckets to plot for each grouping.
    private var bucketCount: Int {
        switch period {
        case .day: return 30
        case .week: return 16
        case .month: return 12
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Shown above everything, and not gated on having any history: after a
                // quarantine the history IS empty, which is exactly when this must be visible.
                if let notice = app.store.quarantineNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                if let error = app.store.lastError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                // Read the store directly here: the snapshot is empty until .task first runs,
                // which would otherwise flash the empty state for a frame.
                if app.store.sessions.isEmpty {
                    emptyState
                } else {
                    lifetimeCard
                    chartCard
                    averagesCard
                    activityCard
                    sessionsCard
                }
            }
            .padding(16)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .navigationTitle("History")
        // Runs outside body, so it can safely write state; re-runs only when the key changes.
        .task(id: snapshotKey) {
            snapshot = HistorySnapshot.make(
                sessions: app.sessions,
                lifetime: app.lifetimeTotals,
                period: period,
                bucketCount: bucketCount,
                now: Date()
            )
        }
        .toolbar {
            if !sessions.isEmpty {
                Button {
                    exportText = app.historyCSV()
                    isExporting = true
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .help("Export every walk as CSV")
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: CSVDocument(text: exportText),
            contentType: .commaSeparatedText,
            defaultFilename: "walkingpad-history"
        ) { _ in }
    }

    // MARK: Cards

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No walks recorded yet")
                .font(.headline)
            Text("Walks are saved automatically once the belt has been moving for a little while. "
                 + "Connect the belt and start walking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var lifetimeCard: some View {
        // Deliberately live rather than snapshotted: this one is meant to tick up as you walk.
        let totals = app.lifetimeTotalsIncludingCurrent
        return CardSection(
            title: "All time",
            systemImage: "sum",
            trailing: AnyView(
                Group {
                    if app.isRecordingWalk {
                        StatusChip(text: "walk in progress", systemImage: "record.circle", tint: .green)
                    }
                }
            )
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                MetricTile(
                    label: "Total distance",
                    value: String(format: "%.1f", unit.distance(fromKm: totals.distanceKm)),
                    unit: unit.distanceSuffix,
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    tint: .teal
                )
                MetricTile(
                    label: "Total walk time",
                    value: Metrics.formatDuration(totals.durationSeconds),
                    systemImage: "clock",
                    tint: .blue
                )
                MetricTile(
                    label: "Average speed",
                    value: String(format: "%.1f", unit.speed(fromKph: totals.averageSpeedKph)),
                    unit: unit.speedSuffix,
                    systemImage: "speedometer",
                    tint: .purple
                )
                MetricTile(
                    label: "Total steps",
                    value: totals.steps.formatted(),
                    systemImage: "shoeprints.fill",
                    tint: .indigo
                )
                SettingsLink {
                    MetricTile(
                        label: "Calories",
                        value: String(format: "%.0f", app.displayKcal(for: totals)),
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
                    label: "Walks",
                    value: "\(totals.sessionCount)",
                    systemImage: "figure.walk",
                    tint: .mint
                )
            }
        }
    }

    private var chartCard: some View {
        let buckets = snapshot.buckets
        return CardSection(
            title: "\(metric.label) per \(period.label.lowercased())",
            systemImage: "chart.bar.fill",
            trailing: AnyView(
                HStack(spacing: 6) {
                    Picker("", selection: $metric) {
                        ForEach(HistoryMetric.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: $period) {
                        ForEach(WalkPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            )
        ) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value(period.label, bucket.date, unit: period.component),
                    y: .value(
                        metric.label,
                        metric == .calories
                            ? app.displayKcal(for: bucket.totals)
                            : metric.value(bucket.totals, unit: unit)
                    )
                )
                .foregroundStyle(metric.tint.gradient)
                .cornerRadius(3)
            }
            .chartYAxisLabel(metric.axisLabel(unit: unit))
            .frame(height: 180)
        }
    }

    private var averagesCard: some View {
        CardSection(title: "Averages", systemImage: "chart.bar.doc.horizontal") {
            VStack(spacing: 8) {
                ForEach(snapshot.averages, id: \.period) { entry in
                    let period = entry.period
                    let average = entry.totals
                    let active = entry.activeCount
                    HStack {
                        Text(period.perLabel.capitalized)
                            .font(.callout.weight(.medium))
                            .frame(width: 86, alignment: .leading)
                        Text(String(format: "%.2f %@",
                                    unit.distance(fromKm: average.distanceKm), unit.distanceSuffix))
                            .frame(width: 92, alignment: .leading)
                        Text(Metrics.formatDuration(average.durationSeconds))
                            .frame(width: 72, alignment: .leading)
                        Text("\(average.steps.formatted()) steps")
                            .frame(width: 110, alignment: .leading)
                        Spacer()
                        Text("\(active) active \(period.label.lowercased())\(active == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
                Text("Averaged over periods with a walk in them, not over the whole calendar.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activityCard: some View {
        let streak = snapshot.streak
        let bestDay = snapshot.bestDay
        let bestMonth = snapshot.bestMonth
        return CardSection(title: "Highlights", systemImage: "trophy") {
            HStack(spacing: 10) {
                MetricTile(
                    label: "Current streak",
                    value: "\(streak)",
                    unit: streak == 1 ? "day" : "days",
                    systemImage: "flame",
                    tint: .red
                )
                MetricTile(
                    label: "Best day",
                    value: bestDay.map { String(format: "%.1f", unit.distance(fromKm: $0.totals.distanceKm)) } ?? "—",
                    unit: unit.distanceSuffix,
                    systemImage: "star.fill",
                    tint: .yellow,
                    footnote: bestDay.map { $0.date.formatted(date: .abbreviated, time: .omitted) }
                )
                MetricTile(
                    label: "Best month",
                    value: bestMonth.map { String(format: "%.1f", unit.distance(fromKm: $0.totals.distanceKm)) } ?? "—",
                    unit: unit.distanceSuffix,
                    systemImage: "calendar",
                    tint: .cyan,
                    footnote: bestMonth.map { $0.date.formatted(.dateTime.month(.wide).year()) }
                )
                MetricTile(
                    label: "Longest walk",
                    value: snapshot.longestWalk.map { Metrics.formatDuration($0) } ?? "—",
                    systemImage: "hourglass",
                    tint: .brown
                )
            }
        }
    }

    private var sessionsCard: some View {
        CardSection(
            title: "Walks",
            systemImage: "list.bullet",
            trailing: AnyView(
                HStack(spacing: 6) {
                    if !selection.isEmpty {
                        Button("Delete \(selection.count)") {
                            app.deleteSessions(ids: selection)
                            selection.removeAll()
                        }
                        .controlSize(.small)
                    }
                    Button("Delete all…") { confirmingDeleteAll = true }
                        .controlSize(.small)
                }
            )
        ) {
            Table(sessions, selection: $selection) {
                TableColumn("When") { session in
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                TableColumn("Time") { session in
                    Text(Metrics.formatDuration(session.durationSeconds)).monospacedDigit()
                }
                TableColumn(unit.distanceSuffix) { session in
                    Text(String(format: "%.2f", unit.distance(fromKm: session.distanceKm)))
                        .monospacedDigit()
                }
                TableColumn("Steps") { session in
                    Text(session.steps.formatted()).monospacedDigit()
                }
                TableColumn("Avg") { session in
                    Text(String(format: "%.1f", unit.speed(fromKph: session.averageSpeedKph)))
                        .monospacedDigit()
                }
                TableColumn("Peak") { session in
                    Text(String(format: "%.1f", unit.speed(fromKph: session.peakSpeedKph)))
                        .monospacedDigit()
                }
                TableColumn("kcal") { session in
                    Text(String(format: "%.0f", app.displayKcal(for: session))).monospacedDigit()
                }
                TableColumn("Program") { session in
                    Text(session.programName ?? "—").foregroundStyle(.secondary)
                }
            }
            .frame(height: 260)
            .alert("Delete every recorded walk?", isPresented: $confirmingDeleteAll) {
                Button("Delete all", role: .destructive) {
                    app.store.deleteAll()
                    selection.removeAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all \(sessions.count) walks from this Mac. It cannot be undone.")
            }

        }
    }
}

/// Minimal wrapper so the CSV can go through the standard save panel.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
