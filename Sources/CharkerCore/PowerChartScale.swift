import Foundation

/// Stable, user-selectable vertical ranges for power charts.
///
/// `0` is the persisted automatic mode. Positive values are requested manual
/// ceilings in watts. A manual ceiling is promoted when a later reading exceeds
/// it: silently clipping a real power spike would make the chart look calmer
/// than the charger actually was.
public enum PowerChartScale {
    public static let automatic = 0

    public static func options(for product: ChargerProduct) -> [Int] {
        switch product {
        case .a2687:
            [50, 100, 160]
        case .a2345:
            [50, 100, 150, 200, 250]
        }
    }

    public static func normalizedPreference(_ value: Int, for product: ChargerProduct) -> Int {
        value == automatic || options(for: product).contains(value) ? value : automatic
    }

    /// Resolves the displayed top tick. Automatic mode adds 15% headroom and
    /// snaps to a small set of stable ranges, so a steady feed cannot make the
    /// axis breathe on every sample. Manual mode holds its requested range until
    /// a real sample exceeds it, then promotes to the next safe range.
    public static func effectiveMaximum(
        preference: Int,
        product: ChargerProduct,
        observedPeak: Double
    ) -> Int {
        let choices = options(for: product)
        let normalized = normalizedPreference(preference, for: product)
        let finitePeak = observedPeak.isFinite ? max(0, observedPeak) : 0
        let target = normalized == automatic ? finitePeak * 1.15 : finitePeak
        let requestedFloor = normalized == automatic ? (choices.first ?? 1) : normalized
        let required = max(Double(requestedFloor), target)

        if let choice = choices.first(where: { Double($0) >= required }) {
            return choice
        }

        // Hardware should not exceed its rating, but imported or malformed
        // history must still remain visible rather than being clipped.
        return max(Int(ceil(required / 50)) * 50, choices.last ?? 1)
    }

    /// A little plot-space headroom keeps a point exactly on the top tick from
    /// being clipped while the labelled maximum remains the user's chosen range.
    public static func chartCeiling(maximum: Int) -> Double {
        Double(max(1, maximum)) * 1.05
    }

    /// Human-scale ticks for every supported range. The list always includes
    /// both zero and the selected maximum, so the UI never implies a different
    /// range from the one shown in its menu.
    public static func axisValues(maximum: Int) -> [Int] {
        let safeMaximum = max(1, maximum)
        let step: Int
        switch safeMaximum {
        case ...50: step = 10
        case ...100: step = 25
        case 150: step = 50
        case 160: step = 40
        case ...250: step = 50
        default: step = max(50, Int(ceil(Double(safeMaximum) / 5 / 50)) * 50)
        }

        var values = Array(stride(from: 0, through: safeMaximum, by: step))
        if values.last != safeMaximum { values.append(safeMaximum) }
        return values
    }
}
