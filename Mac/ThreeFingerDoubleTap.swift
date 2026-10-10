import Foundation
import CoreGraphics

/// Only two short, stationary three-finger contacts form a toggle.
struct ThreeFingerDoubleTap {
    static let interval = 0.42
    enum Result { case none, first, double }
    private var peak = 0, began = 0.0, distance = 0.0
    private var starts: [Int32: CGPoint] = [:]
    private var firstTime: Double?
    private var firstCenter = CGPoint.zero
    var reserving: Bool { firstTime != nil || (peak == 3 && distance < 0.025) }

    mutating func frame(_ contacts: [(Int32, Double, Double)], time: Double) -> Result {
        if let firstTime, time - firstTime > Self.interval { self.firstTime = nil }
        if !contacts.isEmpty && peak == 0 { began = time }
        peak = max(peak, contacts.count)
        for (id, x, y) in contacts {
            let point = CGPoint(x: x, y: y)
            if let start = starts[id] { distance = max(distance, hypot(point.x-start.x, point.y-start.y)) }
            else { starts[id] = point }
        }
        if peak > 3 || distance >= 0.025 { firstTime = nil }
        guard contacts.isEmpty, peak != 0 else { return .none }
        defer { peak = 0; starts.removeAll(); distance = 0 }
        guard peak == 3, time-began < 0.3, distance < 0.025 else { firstTime = nil; return .none }
        let center = CGPoint(x: starts.values.map(\.x).reduce(0,+)/Double(starts.count),
                             y: starts.values.map(\.y).reduce(0,+)/Double(starts.count))
        if let firstTime, time-firstTime <= Self.interval,
           hypot(center.x-firstCenter.x, center.y-firstCenter.y) < 0.15 {
            self.firstTime = nil; return .double
        }
        firstTime = time; firstCenter = center; return .first
    }
    mutating func expire() { firstTime = nil }
}
