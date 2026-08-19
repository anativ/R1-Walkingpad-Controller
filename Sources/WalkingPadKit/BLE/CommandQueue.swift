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

    /// Enqueue several frames that must arrive in this order, as one unit.
    ///
    /// Enqueuing them one at a time is not equivalent. Coalescing only replaces a frame that is
    /// still queued, so if the leading `mode` frame of an earlier batch has already been sent, a
    /// second `mode` has nothing to replace and lands at the tail — leaving `start, speed, mode`,
    /// which tells the belt to change speed before it is in manual mode. Replacing every
    /// coalescable member first and then appending the batch keeps the order intact.
    public mutating func enqueue(batch: [PadCommand]) {
        guard !batch.isEmpty else { return }
        let keys = Set(batch.compactMap(\.coalesceKey))
        control.removeAll { command in
            guard let key = command.coalesceKey else { return false }
            return keys.contains(key)
        }
        for command in batch where command.isStatusPoll == false {
            control.append(command)
        }
        // A poll inside a batch is meaningless; keep the newest one if present.
        if let poll = batch.last(where: { $0.isStatusPoll }) { self.poll = poll }
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
