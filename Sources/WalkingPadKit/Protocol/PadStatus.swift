import Foundation

/// A live status frame from the belt (`F8 A2 ...`, 20 bytes).
///
/// Byte layout, verified against a captured frame:
/// `f8 a2 01 3c 01 00 02 2a 00 00 4f 00 03 d1 b4 00 00 00 e3 fd`
/// -> state 1, speed 6.0 km/h, manual, 554 s, 0.79 km, 977 steps, app speed 6.0
public struct PadStatus: Equatable, Sendable {
    public var beltState: PadBeltState
    /// Raw speed in 0.1 km/h units.
    public var speedRaw: UInt8
    /// Raw mode byte as reported by the belt.
    public var modeRaw: UInt8
    /// Elapsed belt time, seconds.
    public var elapsed: Int
    /// Distance in 10 m units (100 == 1 km).
    public var distanceRaw: Int
    public var steps: Int
    /// Last speed set by an app, in 1/30 km/h units.
    public var appSpeedRaw: UInt8
    public var controllerButton: UInt8
    public var raw: [UInt8]
    public var receivedAt: Date

    public static let frameSignature: [UInt8] = [0xF8, 0xA2]

    public static func matches(_ data: [UInt8]) -> Bool {
        data.count >= 18 && data[0] == frameSignature[0] && data[1] == frameSignature[1]
    }

    public init?(data: [UInt8], now: Date = Date()) {
        guard PadStatus.matches(data) else { return nil }
        beltState = PadBeltState(raw: data[2])
        speedRaw = data[3]
        modeRaw = data[4]
        elapsed = PadPacket.int24(data[5...])
        distanceRaw = PadPacket.int24(data[8...])
        steps = PadPacket.int24(data[11...])
        appSpeedRaw = data[14]
        controllerButton = data[16]
        raw = data
        receivedAt = now
    }

    /// Current speed in km/h.
    public var speedKph: Double { Double(speedRaw) / 10.0 }
    /// Distance in km.
    public var distanceKm: Double { Double(distanceRaw) / 100.0 }
    /// Last app-requested speed in km/h.
    public var appSpeedKph: Double { Double(appSpeedRaw) / 30.0 }
    public var mode: PadMode? { PadMode(rawValue: modeRaw) }

    public var isMoving: Bool { speedRaw > 0 }

    public var hexDump: String {
        raw.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

/// The last stored session summary (`F8 A7 ...`).
public struct PadRecord: Equatable, Sendable {
    public var elapsed: Int
    /// Distance in 10 m units.
    public var distanceRaw: Int
    public var steps: Int
    public var raw: [UInt8]
    public var receivedAt: Date

    public static func matches(_ data: [UInt8]) -> Bool {
        data.count >= 17 && data[0] == 0xF8 && data[1] == 0xA7
    }

    public init?(data: [UInt8], now: Date = Date()) {
        guard PadRecord.matches(data) else { return nil }
        elapsed = PadPacket.int24(data[8...])
        distanceRaw = PadPacket.int24(data[11...])
        steps = PadPacket.int24(data[14...])
        raw = data
        receivedAt = now
    }

    public var distanceKm: Double { Double(distanceRaw) / 100.0 }
}

/// Anything the belt sends us.
public enum PadFrame: Equatable, Sendable {
    case status(PadStatus)
    case record(PadRecord)
    case unknown([UInt8])

    public init(data: [UInt8], now: Date = Date()) {
        if let s = PadStatus(data: data, now: now) {
            self = .status(s)
        } else if let r = PadRecord(data: data, now: now) {
            self = .record(r)
        } else {
            self = .unknown(data)
        }
    }
}
