/// Shared, deterministic math for direct-manipulation orbit controls.
///
/// Keeping the pointer-to-camera mapping outside AppKit gives the model stage
/// a small regression seam without exposing SceneKit or view lifecycle details
/// to the core module.
public enum OrbitInteractionMath {
    /// Keeps continuous horizontal orbiting numerically stable no matter how
    /// many complete turns the user makes.
    public static func normalizedRadians(_ angle: Float) -> Float {
        guard angle.isFinite else { return 0 }
        let turn = Float.pi * 2
        var normalized = angle.truncatingRemainder(dividingBy: turn)
        if normalized > .pi { normalized -= turn }
        if normalized < -.pi { normalized += turn }
        return normalized
    }

    public static func elevation(
        current: Float,
        verticalDrag deltaY: Float,
        sensitivity: Float,
        minimum: Float,
        maximum: Float
    ) -> Float {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { return 0 }
        let neutral = min(max(0, minimum), maximum)
        guard current.isFinite else { return neutral }
        let safeCurrent = min(max(current, minimum), maximum)
        guard deltaY.isFinite, sensitivity.isFinite else { return safeCurrent }
        // SCNView uses AppKit's unflipped coordinate system, so an upward drag
        // produces a positive delta. Orbiting the camera upward makes the model
        // appear to rotate downward on screen; invert the camera elevation so
        // the product follows the pointer's vertical direction instead.
        let candidate = safeCurrent - deltaY * sensitivity
        guard candidate.isFinite else { return safeCurrent }
        return min(max(candidate, minimum), maximum)
    }
}
