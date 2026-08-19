import Foundation

/// The belt's write queue, split out from `PadController` so its ordering rules can be verified
/// without a CoreBluetooth session (see `padctl selftest`).
///
/// Two rules matter, and both are correctness rather than optimisation:
///
/// - **Control frames outrank status polls.** A poll must never delay a speed change.
/// - **Coalescing replaces in place.** A repeated command supersedes the queued one *at its
///   existing position*. Removing and re-appending would turn a queued `mode -> start -> speed`
///   sequence into `start -> speed -> mode`, telling the belt to change speed before starting.
public struct CommandQueue: Equatable {
    private var control: [PadCommand] = []
    private var poll: PadCommand?

    public init() {}

    public mutating func enqueue(_ command: PadCommand) {
        if command.isStatusPoll {
            // Only the most recent poll is ever worth sending.
            poll = command
            return
        }
        if let key = command.coalesceKey,
           let index = control.firstIndex(where: { $0.coalesceKey == key }) {
            control[index] = command
        } else {
            control.append(command)
        }
    }

    /// Next frame to write, control frames first.
    public mutating func dequeue() -> PadCommand? {
        if !control.isEmpty { return control.removeFirst() }
        if let poll {
            self.poll = nil
            return poll
        }
        return nil
    }

    public var isEmpty: Bool { control.isEmpty && poll == nil }
    public var controlCount: Int { control.count }
    /// Queued control frames in send order. For diagnostics and tests.
    public var pendingControl: [PadCommand] { control }

    public mutating func removeAll() {
        control.removeAll()
        poll = nil
    }
}
