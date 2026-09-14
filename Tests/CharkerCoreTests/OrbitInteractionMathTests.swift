import XCTest
@testable import CharkerCore

final class OrbitInteractionMathTests: XCTestCase {
    func testHorizontalOrbitStaysStableAcrossArbitrarilyManyTurns() {
        let turns = Float.pi * 2 * 100_000
        XCTAssertEqual(
            OrbitInteractionMath.normalizedRadians(turns + 0.25),
            0.25,
            accuracy: 0.04
        )
        XCTAssertEqual(OrbitInteractionMath.normalizedRadians(.infinity), 0)
    }

    func testAppKitUpwardDragMakesTheModelFollowThePointer() {
        let next = OrbitInteractionMath.elevation(
            current: 0,
            verticalDrag: 20,
            sensitivity: 0.007,
            minimum: -0.46,
            maximum: 0.62
        )

        // Raising the orbit camera makes the model appear to rotate downward.
        // Lower the camera so the visible product follows an upward pointer.
        XCTAssertLessThan(next, 0)
    }

    func testVerticalDragStillClampsAtBothPoles() {
        XCTAssertEqual(
            OrbitInteractionMath.elevation(
                current: 0,
                verticalDrag: -10_000,
                sensitivity: 0.007,
                minimum: -0.46,
                maximum: 0.62
            ),
            0.62
        )
        XCTAssertEqual(
            OrbitInteractionMath.elevation(
                current: 0,
                verticalDrag: 10_000,
                sensitivity: 0.007,
                minimum: -0.46,
                maximum: 0.62
            ),
            -0.46
        )
    }

    func testNonFiniteInputCannotPoisonTheCameraElevation() {
        XCTAssertEqual(
            OrbitInteractionMath.elevation(
                current: .nan,
                verticalDrag: 20,
                sensitivity: 0.007,
                minimum: -0.46,
                maximum: 0.62
            ),
            0
        )
        XCTAssertEqual(
            OrbitInteractionMath.elevation(
                current: 0.2,
                verticalDrag: .infinity,
                sensitivity: 0.007,
                minimum: -0.46,
                maximum: 0.62
            ),
            0.2
        )
    }
}
