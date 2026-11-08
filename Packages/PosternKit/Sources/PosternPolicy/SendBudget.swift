import Foundation

/// The hourly and daily limits applied to a list of recent send times: how many more emails may leave now, when
/// the next one may, and when a long batch should be done.
public enum SendBudget {
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    /// How many more emails the limits allow at `now`.
    public static func remaining(_ policy: Policy, sends: [Date], now: Date = Date()) -> Int {
        let hour = policy.sendsPerHour - sends.filter { now.timeIntervalSince($0) < Self.hour }.count
        let day = policy.sendsPerDay - sends.filter { now.timeIntervalSince($0) < Self.day }.count
        return max(0, min(hour, day))
    }

    /// When the limits next leave room for one email: nil when there is room now.
    public static func nextRoom(_ policy: Policy, sends: [Date], now: Date = Date()) -> Date? {
        guard remaining(policy, sends: sends, now: now) == 0 else { return nil }
        var waits: [Date] = []
        for (window, limit) in [(Self.hour, policy.sendsPerHour), (Self.day, policy.sendsPerDay)] {
            guard limit > 0 else { return .distantFuture }
            let inside = sends.filter { now.timeIntervalSince($0) < window }.sorted()
            guard inside.count >= limit else { continue }
            // Room appears when enough of the oldest sends leave the window.
            let index = max(0, inside.count - limit)
            waits.append(inside[index].addingTimeInterval(window))
        }
        return waits.max() ?? now
    }

    /// When the last of `count` emails should leave, starting at `start`, one every `spacing` seconds at most,
    /// within the limits, given the sends already made.
    public static func finish(
        count: Int, start: Date, spacing: TimeInterval, policy: Policy, sends: [Date]
    ) -> Date {
        var history = sends.filter { start.timeIntervalSince($0) < Self.day }
        var time = start
        for index in 0..<count {
            if index > 0 { time = time.addingTimeInterval(spacing) }
            while let room = nextRoom(policy, sends: history, now: time), room > time {
                guard room < .distantFuture else { return .distantFuture }
                time = room
            }
            history.append(time)
        }
        return time
    }
}
