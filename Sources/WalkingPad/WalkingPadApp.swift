import SwiftUI
import WalkingPadKit
import os

/// Intercepts the quit so a moving belt can be dealt with first.
///
/// SwiftUI has no hook for this — `applicationShouldTerminate` is the only place AppKit lets you
/// delay or veto a quit, which is what stopping the belt first requires.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired from the scenes below, because the model is owned by the App struct.
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // No model yet means nothing is connected, so never block the quit.
        model?.handleQuitRequest() ?? .terminateNow
    }

    /// Closing the last window must not quit: the app lives on in the menu bar, still showing the
    /// speed and still driving any running program.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct WalkingPadApp: App {
    @StateObject private var app = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("WalkingPad", id: "main") {
            DashboardView()
                .environmentObject(app)
                .frame(minWidth: 460, minHeight: 620)
                .task { appDelegate.model = app }
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
                // Switching to Meeting mode is the thing you reach for while a meeting is starting,
                // so it has to be doable without finding and focusing the window.
                Picker("Pace mode", selection: Binding(
                    get: { app.settings.paceMode },
                    set: { app.setPaceMode($0) }
                )) {
                    ForEach(PaceMode.allCases) { Text($0.label).tag($0) }
                }
                Menu("Pace algorithm") {
                    ForEach(PaceAlgorithm.all) { algorithm in
                        Button(app.isRunning(algorithm) ? "Stop \(algorithm.name)" : algorithm.name) {
                            app.toggleAlgorithm(algorithm)
                        }
                        .disabled(!app.isConnected
                                  || (!app.isRunning(algorithm) && !app.canStart(algorithm)))
                    }
                }
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
                // Also wired here: with the window closed or the Dock icon hidden, this may be
                // the only scene that ever appears.
                .task { appDelegate.model = app }
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
                        app.sessionKcal))
        } else {
            Text(app.controller.state.label)
        }
        if app.isProgramRunning {
            let label = app.runningAlgorithm?.name ?? "Program"
            if let seconds = app.runner.secondsUntilNextChange() {
                Text(String(format: "%@: %.1f km/h %@ · next in %@",
                            label,
                            app.runner.currentKph,
                            app.runner.state.tier.label,
                            Metrics.formatDuration(seconds)))
            } else {
                Text("\(label) paused")
            }
            if let target = app.runningAlgorithm?.sessionWorkSeconds {
                Text("Brisk \(Metrics.formatDuration(Int(app.runner.workSeconds)))"
                     + " of \(Metrics.formatDuration(target)) · \(app.settings.paceMode.label)")
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
        // Reachable from here too: with the window closed or the Dock icon hidden, the app menu's
        // Settings item is not available, and this was the only route left.
        SettingsLink { Text("Settings…") }
        Button("Quit WalkingPad") { NSApp.terminate(nil) }
    }
}
