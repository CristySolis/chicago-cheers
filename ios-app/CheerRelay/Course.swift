import Foundation

/// The points on the course where a cheer can be placed.
///
/// One per mile for the first half, where she's fresh and the real crowds are
/// thick; one per half mile for the second, where she needs them most. That
/// puts 26 of the 39 slots in the back half — more than switching to kilometres
/// would give (21) — while still matching the mile markers she runs past, so a
/// cheer she's expecting at mile 20 lines up with something she can see.
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
