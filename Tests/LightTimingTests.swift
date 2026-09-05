import Foundation

private struct TimingFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TimingFailure(description: message) }
}

private func near(_ actual: TimeInterval?, _ expected: TimeInterval) -> Bool {
    guard let actual else { return false }
    return abs(actual - expected) < 0.000_000_1
}

@main
enum LightTimingTests {
    static func main() throws {
        var count = 0
        var failures = 0
        func test(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        func edge(_ down: Bool, _ ns: UInt64) -> KeyLightEvent {
            KeyLightEvent(down: down, timestamp: ns)
        }

        test("timing adds eight bytes per edge and keeps the legacy state byte") {
            for down in [false, true] {
                let original = edge(down, UInt64.max - 17)
                let payload = original.payload
                try expect(payload.count == 9, "unexpected bandwidth increase")
                try expect(payload.first == (down ? 1 : 0), "legacy receiver would read the wrong state")
                var slice = Data([99]) + payload
                slice.removeFirst()
                let decoded = KeyLightEvent.read(slice)
                try expect(decoded?.timestamp == original.timestamp && decoded?.down == down, "timestamp did not round-trip")
            }
            for payload in [Data(), Data([1]), Data(repeating: 0, count: 8),
                            Data(repeating: 0, count: 10), Data([2]) + Data(repeating: 0, count: 8)] {
                try expect(KeyLightEvent.read(payload) == nil, "malformed timing accepted")
            }
        }
        test("bursty packet arrivals preserve ON pulses and OFF gaps") {
            var timeline = KeyLightTimeline()
            let timestamps: [UInt64] = [10_000_000_000, 10_125_000_000, 10_375_000_000, 10_425_000_000]
            let arrivals: [TimeInterval] = [100, 100.8, 100.81, 100.82]
            for i in timestamps.indices {
                try expect(timeline.append(edge(i % 2 == 0, timestamps[i]), receivedAt: arrivals[i]), "edge rejected")
            }
            let deadlines: [TimeInterval] = [101, 101.125, 101.375, 101.425]
            for i in deadlines.indices {
                try expect(near(timeline.nextDeadline, deadlines[i]), "deadline followed packet jitter")
                try expect(timeline.takeDue(at: deadlines[i] - 0.001) == nil, "edge ran early")
                try expect(timeline.takeDue(at: deadlines[i])?.down == (i % 2 == 0), "edge missing or out of order")
            }
            try expect(timeline.nextDeadline == nil, "idle playback still needs a timer")
        }
        test("late timer wakeups shift queued rhythm without catch-up flashes") {
            var timeline = KeyLightTimeline()
            try expect(timeline.append(edge(true, 0), receivedAt: 100), "press")
            try expect(timeline.append(edge(false, 100_000_000), receivedAt: 100.1), "release")
            try expect(timeline.append(edge(true, 300_000_000), receivedAt: 100.2), "next press")
            try expect(timeline.takeDue(at: 101.4)?.down == true, "late press")
            try expect(timeline.takeDue(at: 101.4) == nil, "late timer compressed the flash")
            try expect(near(timeline.nextDeadline, 101.5), "100 ms ON duration changed")
            _ = timeline.takeDue(at: 101.5)
            try expect(near(timeline.nextDeadline, 101.7), "200 ms OFF duration changed")
        }
        test("long ON and OFF intervals refill the buffer without carrying timing drift") {
            var timeline = KeyLightTimeline()
            try expect(timeline.append(edge(true, 0), receivedAt: 100), "press")
            _ = timeline.takeDue(at: 101)
            try expect(timeline.append(edge(false, 8_000_000_000), receivedAt: 105), "long hold release")
            try expect(near(timeline.nextDeadline, 106), "long hold tried to preserve irrelevant exact duration")
            _ = timeline.takeDue(at: 106)
            try expect(timeline.append(edge(true, 20_000_000_000), receivedAt: 109), "long pause press")
            try expect(near(timeline.nextDeadline, 110), "long pause did not refill the buffer")
            _ = timeline.takeDue(at: 110)
            try expect(timeline.append(edge(false, 20_050_000_000), receivedAt: 110.01), "short release")
            try expect(near(timeline.nextDeadline, 110.05), "long pause changed the next short pulse")
        }
        test("a one-second interval is flexible but never becomes a short gap") {
            var timeline = KeyLightTimeline()
            try expect(timeline.append(edge(true, 0), receivedAt: 100), "press")
            try expect(timeline.append(edge(false, 1_000_000_000), receivedAt: 100), "release")
            _ = timeline.takeDue(at: 101)
            try expect(near(timeline.nextDeadline, 102), "coalesced long hold collapsed below one second")
        }
        test("late packets cannot shorten the following known interval") {
            var timeline = KeyLightTimeline()
            try expect(timeline.append(edge(true, 0), receivedAt: 100), "press")
            _ = timeline.takeDue(at: 101)
            // Delay beyond the buffer cannot undo the already visible long ON.
            try expect(timeline.append(edge(false, 100_000_000), receivedAt: 102), "late release")
            try expect(timeline.append(edge(true, 300_000_000), receivedAt: 102), "next press")
            _ = timeline.takeDue(at: 102)
            try expect(near(timeline.nextDeadline, 102.2), "late release crushed the next OFF gap")
        }
        test("timestamp discontinuities and excessive replay queues fail closed") {
            var timeline = KeyLightTimeline()
            try expect(timeline.append(edge(true, 100), receivedAt: 100), "press")
            try expect(!timeline.append(edge(false, 100), receivedAt: 100), "duplicate timestamp")
            try expect(!timeline.append(edge(false, 99), receivedAt: 100), "backward timestamp")
            try expect(!timeline.append(edge(true, 101), receivedAt: 100), "missing transition")
            timeline.reset()
            for i in 0..<256 {
                try expect(timeline.append(edge(i % 2 == 0, UInt64(i) * 1_000), receivedAt: 100), "bounded edge rejected")
            }
            try expect(!timeline.append(edge(true, 256_000), receivedAt: 100), "unbounded queue")
            timeline.reset()
            try expect(timeline.latest == nil && timeline.nextDeadline == nil, "reset retained old rhythm")
            try expect(timeline.append(edge(true, 0), receivedAt: 100), "new session")
            try expect(timeline.append(edge(false, 900_000_000), receivedAt: 100), "first interval")
            try expect(!timeline.append(edge(true, 1_800_000_000), receivedAt: 100), "backlog exceeded the freshness window")
        }
        test("500 mixed intervals retain subsecond timing with up to 850 ms jitter") {
            var timeline = KeyLightTimeline()
            let intervals: [UInt64] = [40_000_000, 90_000_000, 250_000_000, 999_000_000,
                                      1_000_000_000, 5_000_000_000, 2_000_000, 600_000_000]
            var timestamps: [UInt64] = [9_000_000_000_000]
            var arrivals: [TimeInterval] = [100]
            for i in 1..<500 {
                timestamps.append(timestamps[i - 1] + intervals[(i - 1) % intervals.count])
                let elapsed = Double(timestamps[i] - timestamps[0]) / 1_000_000_000
                let jitter = Double((i * 73) % 851) / 1000
                arrivals.append(max(arrivals[i - 1] + 0.0001, 100 + elapsed + jitter))
            }
            var received = 0
            var played: [(KeyLightEvent, TimeInterval)] = []
            while received < timestamps.count || timeline.nextDeadline != nil {
                let arrival = received < timestamps.count ? arrivals[received] : .infinity
                if arrival <= (timeline.nextDeadline ?? .infinity) {
                    try expect(timeline.append(edge(received % 2 == 0, timestamps[received]), receivedAt: arrival), "valid stream rejected at \(received)")
                    received += 1
                } else if let deadline = timeline.nextDeadline, let event = timeline.takeDue(at: deadline) {
                    played.append((event, deadline))
                }
            }
            try expect(played.count == timestamps.count, "stream lost edges")
            for i in 1..<played.count {
                try expect(played[i].0.timestamp == timestamps[i], "stream reordered edges")
                let source = Double(timestamps[i] - timestamps[i - 1]) / 1_000_000_000
                let output = played[i].1 - played[i - 1].1
                if source < 1 { try expect(near(output, source), "short interval \(i) distorted: \(output) vs \(source)") }
                else { try expect(output >= 1 - 0.000_000_1, "long interval collapsed into a short one") }
            }
        }
        print("\(count - failures)/\(count) light timing tests passed")
        if failures > 0 { throw TimingFailure(description: "\(failures) light timing tests failed") }
    }
}
