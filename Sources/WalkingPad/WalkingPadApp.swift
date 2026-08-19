import SwiftUI
import WalkingPadKit

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

        Settings {
            SettingsView()
                .environmentObject(app)
        }

        // Live readout in the menu bar, so the numbers are visible without the window.
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

private struct MenuBarLabel: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if app.isMoving {
            Text(String(format: "%.1f %@",
                        app.settings.unit.speed(fromKph: app.beltSpeedKph),
                        app.settings.unit.speedSuffix))
        } else {
            Image(systemName: "figure.walk.treadmill")
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let status = app.status {
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
        Button("Open window") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
        Button("Quit WalkingPad") { NSApp.terminate(nil) }
    }
}
