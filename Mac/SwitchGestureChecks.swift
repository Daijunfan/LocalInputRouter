import Foundation

@main
struct SwitchGestureChecks {
    static func tap(_ recognizer: inout ThreeFingerDoubleTap, fingers: Int, at time: Double,
                    moved: Bool = false) -> ThreeFingerDoubleTap.Result {
        let contacts = (0..<fingers).map { (Int32($0), 0.40 + Double($0) * 0.02, 0.50) }
        _ = recognizer.frame(contacts, time: time)
        if moved {
            _ = recognizer.frame(contacts.map { ($0.0, $0.1 + 0.04, $0.2) }, time: time + 0.05)
        }
        return recognizer.frame([], time: time + 0.1)
    }

    static func main() {
        var three = ThreeFingerDoubleTap()
        precondition(tap(&three, fingers: 3, at: 1) == .first)
        precondition(tap(&three, fingers: 3, at: 1.2) == .toggle)
        precondition(tap(&three, fingers: 4, at: 2) == .none)
        precondition(tap(&three, fingers: 3, at: 3, moved: true) == .none)

        var four = ThreeFingerDoubleTap(mode: .fourSingle)
        precondition(tap(&four, fingers: 4, at: 1) == .toggle)
        precondition(tap(&four, fingers: 3, at: 2) == .none)
        precondition(tap(&four, fingers: 4, at: 3, moved: true) == .none)
        precondition(tap(&four, fingers: 5, at: 4) == .none)
        precondition(!four.reserving)
        print("PASS: selected touch gestures remain distinct; movement and extra fingers do not switch")
    }
}
