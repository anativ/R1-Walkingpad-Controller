import SwiftUI
import WalkingPadKit

/// App preferences plus the belt's own stored settings.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppPreferencesTab()
                .tabItem { Label("App", systemImage: "gearshape") }
            BeltPreferencesTab()
                .tabItem { Label("Belt", systemImage: "figure.walk.treadmill") }
        }
        .frame(width: 460, height: 400)
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
            }

            Section("Body data (for the calorie estimate)") {
                LabeledContent("Weight") {
                    HStack {
                        Stepper(
                            value: Binding(
                                get: { app.settings.weightKg },
                                set: { app.settings.weightKg = $0 }
                            ),
                            in: 25...250, step: 1
                        ) { EmptyView() }
                        Text(String(format: "%.0f kg", app.settings.weightKg))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                LabeledContent("Height") {
                    HStack {
                        Stepper(
                            value: Binding(
                                get: { app.settings.heightCm },
                                set: { app.settings.heightCm = $0 }
                            ),
                            in: 100...230, step: 1
                        ) { EmptyView() }
                        Text(String(format: "%.0f cm", app.settings.heightCm))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text("Calories are computed with the ACSM walking equation — the belt does not report them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
