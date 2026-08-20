import SwiftUI
import WalkingPadKit

/// App preferences plus the belt's own stored settings.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppPreferencesTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            CaloriesTab()
                .tabItem { Label("Calories", systemImage: "flame") }
            BeltPreferencesTab()
                .tabItem { Label("Belt", systemImage: "figure.walk.treadmill") }
        }
        // Body data used to be the last of six sections in a 400pt window, which made it
        // effectively invisible. It now has its own tab, and the window fits its content.
        .frame(width: 520, height: 520)
    }
}

struct AppPreferencesTab: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        Form {
            Section("Display") {
                Picker("Units", selection: Binding(
                    get: { app.settings.unit },
                    set: { app.settings.unit = $0 }
                )) {
                    ForEach(DistanceUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Show menu bar readout", isOn: Binding(
                    get: { app.settings.showMenuBarExtra },
                    set: { app.settings.showMenuBarExtra = $0 }
                ))
                Picker("Menu bar shows", selection: Binding(
                    get: { app.settings.menuBarContent },
                    set: { app.settings.menuBarContent = $0 }
                )) {
                    ForEach(MenuBarReadout.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!app.settings.showMenuBarExtra)
                Toggle("Menu bar only (hide Dock icon)", isOn: Binding(
                    get: { app.settings.hideDockIcon },
                    set: { app.settings.hideDockIcon = $0 }
                ))
                .disabled(!app.settings.showMenuBarExtra)
                Text("The menu bar keeps showing live speed even when the window is closed or "
                     + "minimised. With the Dock icon hidden, reopen the window from the menu bar item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Control") {
                LabeledContent("Speed limit in app") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { app.settings.speedCeilingKph },
                                set: { app.settings.speedCeilingKph = $0 }
                            ),
                            in: 1...AppSettings.hardMaxSpeedKph,
                            step: 0.5
                        )
                        Text(String(format: "%.1f km/h", app.settings.speedCeilingKph))
                            .monospacedDigit()
                            .frame(width: 78, alignment: .trailing)
                    }
                }
                LabeledContent("Start speed") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { app.settings.startSpeedKph },
                                set: { app.settings.startSpeedKph = $0 }
                            ),
                            in: 0.5...max(1, app.settings.speedCeilingKph),
                            step: 0.5
                        )
                        Text(String(format: "%.1f km/h", app.settings.startSpeedKph))
                            .monospacedDigit()
                            .frame(width: 78, alignment: .trailing)
                    }
                }
                Toggle("Connect automatically on launch", isOn: Binding(
                    get: { app.settings.autoConnectOnLaunch },
                    set: { app.settings.autoConnectOnLaunch = $0 }
                ))
                Picker("When quitting", selection: Binding(
                    get: { app.settings.quitBehavior },
                    set: { app.settings.quitBehavior = $0 }
                )) {
                    ForEach(QuitBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(app.settings.quitBehavior.detail
                     + " Only applies while the belt is actually running; closing the window never "
                     + "quits or stops anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .formStyle(.grouped)
    }
}

/// Body data and how calories are worked out.
///
/// This has its own tab because it is what people go looking for, and it was previously the last
/// of six sections in a 400pt window — present, but effectively impossible to find.
struct CaloriesTab: View {
    @EnvironmentObject private var app: AppModel
    @State private var recalculated: Int?

    /// Spells out what the number actually is, rather than asking you to trust it.
    private var explainer: String {
        let restingPerHour = Metrics.restingKcalPerMinute(profile: app.settings.profile) * 60
        let base = "Walking cost uses the ACSM walking equation, driven mainly by your weight. "
        if app.settings.showNetCalories {
            return base + String(
                format: "Net subtracts resting metabolism (Mifflin-St Jeor, about %.0f kcal/hour "
                    + "for this body data), leaving the extra the walk actually cost.",
                restingPerHour
            )
        }
        return base + "Gross counts everything burned while walking, including what you would have "
            + "burned at rest anyway. Age and sex only affect the net figure."
    }

    var body: some View {
        Form {
            Section("Your body") {
                Picker("Weight in", selection: Binding(
                    get: { app.settings.weightUnit },
                    set: { app.settings.weightUnit = $0 }
                )) {
                    ForEach(WeightUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                numberRow(
                    "Weight",
                    value: Binding(
                        get: { app.settings.weightUnit.fromKilograms(app.settings.weightKg) },
                        set: { app.settings.weightKg = app.settings.weightUnit.toKilograms($0) }
                    ),
                    range: app.settings.weightUnit == .kilograms ? 25...250 : 55...550,
                    suffix: app.settings.weightUnit.suffix
                )
                numberRow(
                    "Height",
                    value: Binding(
                        get: { app.settings.heightCm },
                        set: { app.settings.heightCm = $0 }
                    ),
                    range: 100...230,
                    suffix: "cm"
                )
                numberRow(
                    "Age",
                    value: Binding(
                        get: { app.settings.ageYears },
                        set: { app.settings.ageYears = $0 }
                    ),
                    range: 10...100,
                    suffix: "years"
                )
                Picker("Sex", selection: Binding(
                    get: { app.settings.sex },
                    set: { app.settings.sex = $0 }
                )) {
                    ForEach(BiologicalSex.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section("How calories are counted") {
                Toggle("Show net calories", isOn: Binding(
                    get: { app.settings.showNetCalories },
                    set: { app.settings.showNetCalories = $0 }
                ))
                Text(explainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Walks already recorded") {
                LabeledContent("Past walks") {
                    HStack {
                        Button("Recalculate calories") {
                            recalculated = app.recalculateHistoryCalories()
                        }
                        .disabled(app.sessions.isEmpty)
                        if let recalculated {
                            Text(recalculated == 0
                                 ? "already up to date"
                                 : "updated \(recalculated) walk\(recalculated == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Stored walks were worked out with the body data set at the time, so changing "
                     + "your weight only affects future walks until you press this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// A typed field plus a stepper, so a weight can be entered rather than clicked up to.
    private func numberRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(
                    title,
                    value: Binding(
                        get: { value.wrappedValue },
                        // Clamp on commit so a typo cannot push the model out of range.
                        set: { value.wrappedValue = min(max(range.lowerBound, $0), range.upperBound) }
                    ),
                    format: .number.precision(.fractionLength(0))
                )
                .labelsHidden()
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Stepper(title, value: value, in: range, step: 1)
                    .labelsHidden()
            }
        }
    }
}

/// These write to the belt's own stored preferences. The belt does not report them back,
/// so the controls are write-only actions rather than two-way bindings.
struct BeltPreferencesTab: View {
    @EnvironmentObject private var app: AppModel

    @State private var beltMaxSpeed: Double = 6.0
    @State private var beltStartSpeed: Double = 2.0
    @State private var sensitivity: PadSensitivity = .medium
    @State private var childLock = false
    @State private var intelligentStart = false
    @State private var beltUsesMiles = false
    @State private var target: PadTarget = .none
    @State private var targetValue: Double = 30

    var body: some View {
        Form {
            Section {
                Text("These settings are stored on the belt. It never reports them back, so the values shown here are what this app last sent, not necessarily what the belt holds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Belt limits") {
                sliderRow("Max speed", value: $beltMaxSpeed, range: 1...AppSettings.hardMaxSpeedKph, step: 0.5, suffix: "km/h") {
                    app.applyBeltMaxSpeed(beltMaxSpeed)
                }
                sliderRow("Start speed", value: $beltStartSpeed, range: 0.5...6, step: 0.5, suffix: "km/h") {
                    app.applyBeltStartSpeed(beltStartSpeed)
                }
            }

            Section("Behaviour") {
                LabeledContent("Sensitivity") {
                    HStack {
                        Picker("", selection: $sensitivity) {
                            ForEach(PadSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        Button("Apply") { app.applySensitivity(sensitivity) }
                            .disabled(!app.isConnected)
                    }
                }
                toggleRow("Child lock", isOn: $childLock) { app.applyChildLock(childLock) }
                toggleRow("Intelligent start", isOn: $intelligentStart) { app.applyIntelligentStart(intelligentStart) }
                toggleRow("Belt display in miles", isOn: $beltUsesMiles) { app.applyBeltUnits(miles: beltUsesMiles) }
            }

            Section("Session target") {
                LabeledContent("Type") {
                    Picker("", selection: $target) {
                        ForEach(PadTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                if target != .none {
                    LabeledContent(targetUnitLabel) {
                        HStack {
                            Slider(value: $targetValue, in: 1...120, step: 1)
                            Text(String(format: "%.0f", targetValue))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Button("Send target to belt") {
                    app.applyTarget(target, value: target == .none ? 0 : Int(targetValue))
                }
                .disabled(!app.isConnected)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            beltMaxSpeed = app.settings.speedCeilingKph
            beltStartSpeed = app.settings.startSpeedKph
            beltUsesMiles = app.settings.unit == .miles
        }
    }

    private var targetUnitLabel: String {
        switch target {
        case .distance: return "Distance (x 0.1 km)"
        case .calories: return "Calories (kcal)"
        case .time: return "Time (minutes)"
        case .none: return ""
        }
    }

    private func sliderRow(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>,
        step: Double, suffix: String, apply: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(String(format: "%.1f %@", value.wrappedValue, suffix))
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
                Button("Apply", action: apply)
                    .disabled(!app.isConnected)
            }
        }
    }

    private func toggleRow(
        _ title: String, isOn: Binding<Bool>, apply: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Toggle("", isOn: isOn).labelsHidden()
                Button("Apply", action: apply)
                    .disabled(!app.isConnected)
            }
        }
    }
}
