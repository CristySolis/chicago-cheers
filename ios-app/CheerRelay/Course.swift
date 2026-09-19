import Foundation

/// The points on the course where a cheer can be placed.
///
/// One per mile for the first half, where the runner is fresh and the real crowds are
/// thick; one per half mile for the second, where they're needed most. That
/// puts 26 of the 39 slots in the back half — more than switching to kilometres
/// would give (21) — while still matching the mile markers on the course, so a
/// cheer expected at mile 20 lines up with a marker the runner can see.
nonisolated enum Course {

    static let metresPerMile = 1609.344

    static let slots: [Double] =
        (1...13).map(Double.init) + Array(stride(from: 13.5, through: 26.0, by: 0.5))

    /// Every value here is a whole or half number, which floating point stores
    /// exactly, so plain equality is safe.
    static func isSlot(_ miles: Double) -> Bool {
        slots.contains(miles)
    }

    static func label(_ miles: Double) -> String {
        miles == miles.rounded()
            ? "Mile \(Int(miles))"
            : "Mile \(String(format: "%.1f", miles))"
    }
}
