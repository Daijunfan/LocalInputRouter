/// The Windows device is gesture-only. Mouse motion/clicks use Deskflow.
/// Begin at two contacts, and always terminate a previous native gesture.
struct GestureFrameGate {
    private var active = false
    mutating func shouldSend(count: Int) -> Bool {
        if count >= 2 { active = true; return true }
        if active { active = false; return true }
        return false
    }
    mutating func reset() { active = false }
}
