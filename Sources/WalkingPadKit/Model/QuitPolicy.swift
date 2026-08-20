import Foundation

/// What the app should do about a moving belt when you quit.
public enum QuitBehavior: String, CaseIterable, Sendable {
    /// Ask, every time the belt is actually running.
    case ask
    /// Quit and leave the belt running.
    case leaveRunning
    /// Stop the belt, then quit.
    case stopBelt

    public var label: String {
        switch self {
        case .ask: return "Ask me"
        case .leaveRunning: return "Leave the belt running"
        case .stopBelt: return "Stop the belt"
        }
    }

    public var detail: String {
        switch self {
        case .ask:
            return "Confirm each time, showing the speed the belt is running at."
        case .leaveRunning:
            return "Quitting is silent and the belt keeps going — quitting a remote does not change the machine."
        case .stopBelt:
            return "The belt is told to stop and the app waits for it before quitting."
        }
    }
}

/// The decision the app acts on when a quit is requested.
public enum QuitAction: Equatable, Sendable {
    /// Nothing to do; let the quit proceed.
    case quitNow
    /// Put the choice to the user.
    case askUser
    /// Send a stop, wait for the belt, then quit.
    case stopThenQuit
}

/// Resolves the quit decision. Pure, so it is covered by `padctl selftest` rather than
/// only being exercised by actually quitting the app.
public enum QuitPolicy {
    public static func action(
        behavior: QuitBehavior, isConnected: Bool, beltIsMoving: Bool
    ) -> QuitAction {
        // A belt that is not running (or not even connected) needs no decision: never delay a
        // quit, and never prompt, over a belt that is already still.
        guard isConnected, beltIsMoving else { return .quitNow }
        switch behavior {
        case .ask: return .askUser
        case .leaveRunning: return .quitNow
        case .stopBelt: return .stopThenQuit
        }
    }

    /// How long to wait for the belt to confirm a stop before quitting anyway.
    ///
    /// A quit must never hang on hardware. The belt also decelerates over a few seconds, so this
    /// allows for the command queue's spacing plus the ramp down.
    public static let stopConfirmationTimeout: TimeInterval = 6.0
}
