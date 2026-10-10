import Foundation

/// Recognizes a short tap followed by a second contact and movement.
/// It never delays ordinary single clicks or starts from multi-finger gestures.
struct TapDrag {
    private let requiredTaps: Int
    private var completedTaps = 0
    private var count = 0
    private var start = (x: 0.0, y: 0.0), lastTap = (x: 0.0, y: 0.0)
    private var began = 0.0, tappedAt = -100.0, moved = false
    private(set) var armed = false
    private(set) var dragging = false
    private var motionX: Int64 = 0, motionY: Int64 = 0
    init(requiredTaps: Int = 1) { self.requiredTaps = requiredTaps }
    var suppressesTapClick: Bool {
        requiredTaps == 2 && (dragging || armed || completedTaps >= 2 || (count > 0 && completedTaps == 1))
    }

    mutating func contact(count next: Int, x: Double, y: Double, time: Double) -> Bool {
        var release = false
        if next == 1 && count == 0 {
            let continuing = time - tappedAt <= 0.45 && hypot(x-lastTap.x,y-lastTap.y) < 0.07
            if !continuing { completedTaps = 0 }
            armed = continuing && completedTaps >= requiredTaps
            start = (x,y); began = time; moved = false; motionX = 0; motionY = 0
            if armed { tappedAt = -100; completedTaps = 0 }
        } else if next == 1 && count == 1 {
            moved = moved || hypot(x-start.x,y-start.y) > 0.012
        } else if next == 0 && count == 1 {
            if dragging { release = true; dragging = false }
            else if !armed && !moved && time-began < 0.23 { tappedAt = time; lastTap = start; completedTaps += 1 }
            else { completedTaps = 0; tappedAt = -100 }
            armed = false
        } else if next > 1 {
            release = dragging; dragging = false; armed = false; tappedAt = -100; completedTaps = 0
            moved = true // A trailing finger after a gesture is not a new tap.
        }
        count = next
        return release
    }
    mutating func move(dx: Int64, dy: Int64) -> Bool {
        guard armed && !dragging && count == 1 else { return false }
        motionX += dx; motionY += dy
        // Move beyond the Windows double-click rectangle before pressing down.
        guard hypot(Double(motionX),Double(motionY)) >= 12 else { return false }
        dragging = true; return true
    }
    mutating func nativePress() {
        // Tap-to-click produces an ordinary mouse-down, sometimes after the
        // finger lifts or the second touch starts. Keep that tap history.
        if count > 0 && !armed { tappedAt = -100 }
    }
    mutating func reset() { self = TapDrag(requiredTaps: requiredTaps) }
}
