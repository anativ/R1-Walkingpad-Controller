import SwiftUI
import WalkingPadKit
import os

@main
struct WalkingPadApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("WalkingPad", id: "main") {
            DashboardView()
                .environmentObject(app)
                .frame(minWidth: 460, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .sidebar) {
                HistoryWindowButton()
                    .environmentObject(app)
                Divider()
            }
            CommandMenu("Belt") {
                // Every belt command is gated on the connection: the in-window controls are
                // disabled when there is no belt, and these shortcuts must match or they will
                // move on-screen values that the belt never received.
                Button(app.isMoving ? "Stop" : "Start") { app.toggleStartStop() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!app.isConnected)
                Button("Emergency stop") { app.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!app.isConnected)
                Divider()
                Button("Faster") { app.nudgeSpeed(by: 0.5) }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                    .disabled(!app.isConnected)
                Button("Slower") { app.nudgeSpeed(by: -0.5) }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .disabled(!app.isConnected)
                Divider()
                Button(app.isProgramRunning ? "Stop program" : "Start program") { app.toggleProgram() }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(!app.isConnected || (!app.isProgramRunning && !app.canStartProgram))
                Divider()
                ForEach(PadMode.allCases, id: \.self) { mode in
                    Button("Mode: \(mode.label)") { app.setMode(mode) }
                        .disabled(!app.isConnected)
                }
                Divider()
                Button(app.isConnected ? "Disconnect" : "Connect") { app.toggleConnection() }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Reset session metrics") { app.resetSessionMetrics() }
            }
        }

        Window("History", id: "history") {
            HistoryView()
                .environmentObject(app)
                .frame(minWidth: 620, minHeight: 560)
        }
        .defaultSize(width: 820, height: 760)

        Settings {
            SettingsView()
                .environmentObject(app)
        }

        // Live readout in the menu bar, so the numbers are visible without the window.
        // Lives in the system menu bar, independent of any window: the speed stays visible while
        // the window is minimised, closed, or hidden entirely with the Dock icon off.
        MenuBarExtra(isInserted: Binding(
            get: { app.settings.showMenuBarExtra },
            set: { app.settings.showMenuBarExtra = $0 }
        )) {
            MenuBarContent()
                .environmentObject(app)
        } label: {
            MenuBarLabel()
                .environmentObject(app)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Reopens the dashboard. Needed because the window can be closed entirely while the app keeps
/// running in the menu bar.
private struct MainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open WalkingPad Window") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }
}

/// Opens the History window. Split out so it can hold the `openWindow` environment action.
private struct HistoryWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Walk History") { openWindow(id: "history") }
            .keyboardShortcut("y", modifiers: [.command])
    }
}

/// The always-visible menu-bar readout.
///
/// This lives in the system menu bar, so it keeps showing the live speed whether the window is
/// open, minimised, closed, or hidden entirely with the Dock icon turned off.
private struct MenuBarLabel: View {
    @EnvironmentObject private var app: AppModel

    private static let logger = Logger(subsystem: "io.nativ.walkingpad", category: "menubar")

    var body: some View {
        Group {
            if let summary = app.menuBarSummary {
                // Text instead of a Label: the number replaces the icon rather than sitting
                // beside it, so the speed is what you actually read in the menu bar.
                Text(summary)
            } else {
                // Nothing to report yet (not connected) — fall back to the icon.
                Image(systemName: "figure.walk.treadmill")
            }
        }
        // Confirms the status item really was created; the only way to verify this without
        // Screen Recording or Accessibility access.
        .onAppear { MenuBarLabel.logger.notice("menu bar item created and rendering") }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let status = app.status {
            // The menu bar label is a bare number, so this is where the unit is stated.
            Text(String(format: "Speed %.1f %@",
                        app.settings.unit.speed(fromKph: status.speedKph),
                        app.settings.unit.speedSuffix))
            Text("\(Metrics.formatDuration(status.elapsed)) · \(status.steps) steps")
            Text(String(format: "%.2f %@ · %.0f kcal",
                        app.settings.unit.distance(fromKm: status.distanceKm),
                        app.settings.unit.distanceSuffix,
                        app.tracker.kcal))
        } else {
            Text(app.controller.state.label)
        }
        if app.isProgramRunning {
            if let seconds = app.runner.secondsUntilNextChange() {
                Text(String(format: "Program: %.1f km/h · next in %@",
                            app.runner.currentKph,
                            Metrics.formatDuration(seconds)))
            } else {
                Text("Program paused")
            }
        }
        Divider()
        Button(app.isMoving ? "Stop belt" : "Start belt") { app.toggleStartStop() }
            .disabled(!app.isConnected)
        Button("Faster") { app.nudgeSpeed(by: 0.5) }
            .disabled(!app.isConnected)
        Button("Slower") { app.nudgeSpeed(by: -0.5) }
            .disabled(!app.isConnected)
        Divider()
        HistoryWindowButton()
        MainWindowButton()
            .environmentObject(app)
        Button("Quit WalkingPad") { NSApp.terminate(nil) }
    }
}
