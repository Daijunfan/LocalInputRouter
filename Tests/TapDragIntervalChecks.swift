import Foundation

@main enum TapDragIntervalChecks {
    static func firstTap(_ tap: inout TapDrag) {
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: -0.20)
        _ = tap.contact(count: 0, x: 0.5, y: 0.5, time: 0)
        tap.nativePress()
    }

    static func main() {
        for interval in [0.01, 0.10, 0.20, 0.30] {
            for gap in [interval - 0.001, interval, interval + 0.001] {
                var tap = TapDrag(tapInterval: interval)
                firstTap(&tap)
                _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: gap)
                tap.nativePress() // A delayed native click must not change the physical interval.
                let expected = gap <= interval
                precondition(tap.armed == expected, "Interval \(interval), gap \(gap)")
                precondition(tap.move(dx: 12, dy: 0) == expected)
                precondition(tap.contact(count: 0, x: 0.5, y: 0.5, time: gap + 0.5) == expected)
                precondition(!tap.contact(count: 0, x: 0.5, y: 0.5, time: gap + 0.6), "Release only once")
            }
        }
        for interval in [0.10, 0.20] {
            var tap = TapDrag(tapInterval: interval)
            tap.reset() // Routing changes must retain the chosen setting.
            firstTap(&tap)
            _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 0.15)
            precondition(tap.armed == (interval == 0.20), "The same gesture must follow the selected interval after reset")
        }
        var tap = TapDrag()
        firstTap(&tap)
        tap.tapInterval = 0.10
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 0.15)
        precondition(!tap.armed, "Changing the interval takes effect on the next contact")
        tap.reset(); firstTap(&tap)
        tap.tapInterval = 0.30
        _ = tap.contact(count: 1, x: 0.5, y: 0.5, time: 0.25)
        precondition(tap.move(dx: 12, dy: 0))
        tap.tapInterval = 0.01
        precondition(tap.dragging, "Changing settings must not interrupt an active drag")
        precondition(tap.contact(count: 0, x: 0.5, y: 0.5, time: 1), "The active drag still releases on lift")
        tap.reset()
        precondition(tap.tapInterval == 0.01)
        print("PASS: 0.01–0.30 second boundaries, lift-based timing, immediate changes, persistent resets and balanced drag release")
    }
}
