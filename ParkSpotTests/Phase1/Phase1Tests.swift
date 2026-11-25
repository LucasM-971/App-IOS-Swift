import XCTest
@testable import ParkSpot

final class Phase1Tests: XCTestCase {

    func testHeuristicConfirmsReliableParkingAfterDrivingAndStableStop() {
        let heuristic = AutoParkingDetectionHeuristic()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)

        let driving = makeSamples(
            from: anchor,
            startDate: base,
            offsetsMeters: stride(from: 0.0, through: 560.0, by: 80.0).map { $0 },
            interval: 12,
            speed: 8.4,
            accuracy: 12
        )

        let parkedAnchor = coordinate(from: anchor, northMeters: 560)
        let parked = [
            makeSample(at: parkedAnchor, secondsFrom: base, offset: 96, speed: 0.2, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, eastMeters: 3), secondsFrom: base, offset: 118, speed: 0.15, accuracy: 9),
            makeSample(at: coordinate(from: parkedAnchor, westMeters: 2), secondsFrom: base, offset: 140, speed: 0.1, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, northMeters: 2), secondsFrom: base, offset: 162, speed: 0.05, accuracy: 7),
            makeSample(at: coordinate(from: parkedAnchor, southMeters: 2), secondsFrom: base, offset: 190, speed: 0.08, accuracy: 8),
        ]

        let result = heuristic.evaluate(samples: driving + parked, bluetoothDisconnectAt: nil, now: base.addingTimeInterval(190))

        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result?.confidence ?? 0, 0.74)
        XCTAssertLessThanOrEqual(result?.clusterRadius ?? 999, 8)
    }

    func testHeuristicCreatesCandidateAfterNormalShortParkingStop() {
        let heuristic = AutoParkingDetectionHeuristic()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)

        let driving = makeSamples(
            from: anchor,
            startDate: base,
            offsetsMeters: [0, 90, 190, 300, 410, 470],
            interval: 10,
            speed: 8.5,
            accuracy: 12
        )

        let parkedAnchor = coordinate(from: anchor, northMeters: 500)
        let parked = [
            makeSample(at: parkedAnchor, secondsFrom: base, offset: 62, speed: 0.18, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, eastMeters: 2), secondsFrom: base, offset: 74, speed: 0.12, accuracy: 9),
            makeSample(at: coordinate(from: parkedAnchor, westMeters: 2), secondsFrom: base, offset: 86, speed: 0.08, accuracy: 8),
        ]

        let result = heuristic.evaluate(samples: driving + parked, bluetoothDisconnectAt: nil, now: base.addingTimeInterval(86))

        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result?.confidence ?? 0, 0.74)
        XCTAssertGreaterThanOrEqual(result?.stationaryDuration ?? 0, 24)
    }

    func testHeuristicRejectsTrafficLikeStopWithoutStrongDrivingContext() {
        let heuristic = AutoParkingDetectionHeuristic()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)

        let slowTraffic = makeSamples(
            from: anchor,
            startDate: base,
            offsetsMeters: [0, 25, 55, 80, 95],
            interval: 18,
            speed: 3.2,
            accuracy: 14
        )

        let stopped = [
            makeSample(at: coordinate(from: anchor, northMeters: 95), secondsFrom: base, offset: 90, speed: 0.2, accuracy: 10),
            makeSample(at: coordinate(from: anchor, northMeters: 97), secondsFrom: base, offset: 112, speed: 0.15, accuracy: 10),
            makeSample(at: coordinate(from: anchor, northMeters: 95), secondsFrom: base, offset: 134, speed: 0.18, accuracy: 11),
            makeSample(at: coordinate(from: anchor, northMeters: 96), secondsFrom: base, offset: 156, speed: 0.10, accuracy: 10),
            makeSample(at: coordinate(from: anchor, northMeters: 95), secondsFrom: base, offset: 178, speed: 0.12, accuracy: 10),
        ]

        let result = heuristic.evaluate(samples: slowTraffic + stopped, bluetoothDisconnectAt: nil, now: base.addingTimeInterval(178))

        XCTAssertNil(result)
    }

    func testHeuristicRejectsStopAfterWalkingAwayFromVehicle() {
        let heuristic = AutoParkingDetectionHeuristic()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)

        let driving = makeSamples(
            from: anchor,
            startDate: base,
            offsetsMeters: [0, 110, 220, 340, 470],
            interval: 10,
            speed: 9.0,
            accuracy: 10
        )

        let walkAnchor = coordinate(from: anchor, northMeters: 470)
        let walking = [
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 12), secondsFrom: base, offset: 50, speed: 1.3, accuracy: 9),
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 26), secondsFrom: base, offset: 66, speed: 1.4, accuracy: 9),
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 42), secondsFrom: base, offset: 82, speed: 1.2, accuracy: 10),
        ]

        let desk = [
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 45), secondsFrom: base, offset: 104, speed: 0.05, accuracy: 8),
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 46), secondsFrom: base, offset: 126, speed: 0.04, accuracy: 8),
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 45), secondsFrom: base, offset: 148, speed: 0.06, accuracy: 9),
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 44), secondsFrom: base, offset: 170, speed: 0.03, accuracy: 8),
            makeSample(at: coordinate(from: walkAnchor, eastMeters: 45), secondsFrom: base, offset: 192, speed: 0.04, accuracy: 8),
        ]

        let result = heuristic.evaluate(samples: driving + walking + desk, bluetoothDisconnectAt: nil, now: base.addingTimeInterval(192))

        XCTAssertNil(result)
    }

    func testHeuristicUsesBluetoothDisconnectAsExtraConfirmation() {
        let heuristic = AutoParkingDetectionHeuristic(
            configuration: AutoParkingHeuristicConfiguration(
                minimumStationaryDuration: 90,
                minimumConfidence: 0.74
            )
        )
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)

        let sparseApproach = makeSamples(
            from: anchor,
            startDate: base,
            offsetsMeters: [0, 55, 130, 190],
            interval: 15,
            speed: 5.4,
            accuracy: 11
        )

        let parkedAnchor = coordinate(from: anchor, northMeters: 190)
        let parked = [
            makeSample(at: parkedAnchor, secondsFrom: base, offset: 60, speed: 0.08, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, eastMeters: 2), secondsFrom: base, offset: 84, speed: 0.05, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, westMeters: 2), secondsFrom: base, offset: 108, speed: 0.06, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, northMeters: 1), secondsFrom: base, offset: 132, speed: 0.05, accuracy: 7),
            makeSample(at: parkedAnchor, secondsFrom: base, offset: 156, speed: 0.04, accuracy: 7),
        ]

        let result = heuristic.evaluate(
            samples: sparseApproach + parked,
            bluetoothDisconnectAt: base.addingTimeInterval(40),
            now: base.addingTimeInterval(156)
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.triggerSource, "gps+stability+bt")
    }

    func testHeuristicRejectsStaleLocationHistory() {
        let heuristic = AutoParkingDetectionHeuristic()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let anchor = Coordinate(latitude: 48.8566, longitude: 2.3522)

        let driving = makeSamples(
            from: anchor,
            startDate: base,
            offsetsMeters: stride(from: 0.0, through: 560.0, by: 80.0).map { $0 },
            interval: 12,
            speed: 8.4,
            accuracy: 12
        )

        let parkedAnchor = coordinate(from: anchor, northMeters: 560)
        let parked = [
            makeSample(at: parkedAnchor, secondsFrom: base, offset: 96, speed: 0.2, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, eastMeters: 3), secondsFrom: base, offset: 118, speed: 0.15, accuracy: 9),
            makeSample(at: coordinate(from: parkedAnchor, westMeters: 2), secondsFrom: base, offset: 140, speed: 0.1, accuracy: 8),
            makeSample(at: coordinate(from: parkedAnchor, northMeters: 2), secondsFrom: base, offset: 162, speed: 0.05, accuracy: 7),
            makeSample(at: coordinate(from: parkedAnchor, southMeters: 2), secondsFrom: base, offset: 190, speed: 0.08, accuracy: 8),
        ]

        let result = heuristic.evaluate(
            samples: driving + parked,
            bluetoothDisconnectAt: nil,
            now: base.addingTimeInterval(260)
        )

        XCTAssertNil(result)
    }

    func testWalkAwayPolicyClearsCandidateWhenVehicleMovesAgain() {
        let policy = AutoParkingWalkAwayConfirmationPolicy()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let parked = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let detection = AutoParkingDetectionSnapshot(
            coordinate: parked,
            confidence: 0.82,
            stationaryDuration: 120,
            clusterRadius: 8,
            triggerSource: "gps+stability",
            detectedAt: base
        )

        let sample = makeSample(
            at: coordinate(from: parked, northMeters: 160),
            secondsFrom: base,
            offset: 30,
            speed: 8.2,
            accuracy: 8
        )

        let decision = policy.evaluate(
            detection: detection,
            sample: sample,
            previousSample: nil,
            previousDistance: nil
        )

        XCTAssertEqual(decision.action, .clearCandidate(reason: "vehicle_moved"))
    }

    func testWalkAwayPolicyUsesShorterDistanceForHighConfidenceCandidate() {
        let policy = AutoParkingWalkAwayConfirmationPolicy()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let parked = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let detection = AutoParkingDetectionSnapshot(
            coordinate: parked,
            confidence: 0.92,
            stationaryDuration: 120,
            clusterRadius: 6,
            triggerSource: "gps+stability",
            detectedAt: base
        )
        let previous = makeSample(
            at: coordinate(from: parked, northMeters: 48),
            secondsFrom: base,
            offset: 24,
            speed: 1.2,
            accuracy: 8
        )
        let current = makeSample(
            at: coordinate(from: parked, northMeters: 60),
            secondsFrom: base,
            offset: 32,
            speed: 1.2,
            accuracy: 8
        )

        let decision = policy.evaluate(
            detection: detection,
            sample: current,
            previousSample: previous,
            previousDistance: nil
        )

        XCTAssertEqual(decision.requiredDistance, 55)
        XCTAssertEqual(decision.action, .countProgress)
    }

    func testWalkAwayPolicyAcceptsInferredWalkingWhenGPSSpeedIsZero() {
        let policy = AutoParkingWalkAwayConfirmationPolicy()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let parked = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let detection = AutoParkingDetectionSnapshot(
            coordinate: parked,
            confidence: 0.92,
            stationaryDuration: 28,
            clusterRadius: 6,
            triggerSource: "gps+stability",
            detectedAt: base
        )
        let previous = makeSample(
            at: coordinate(from: parked, northMeters: 48),
            secondsFrom: base,
            offset: 24,
            speed: 0,
            accuracy: 8
        )
        let current = makeSample(
            at: coordinate(from: parked, northMeters: 60),
            secondsFrom: base,
            offset: 32,
            speed: 0,
            accuracy: 8
        )

        let decision = policy.evaluate(
            detection: detection,
            sample: current,
            previousSample: previous,
            previousDistance: nil
        )

        XCTAssertEqual(decision.requiredDistance, 55)
        XCTAssertEqual(decision.action, .countProgress)
    }

    func testWalkAwayPolicyKeepsWaitingForLowConfidenceCandidateAtSameDistance() {
        let policy = AutoParkingWalkAwayConfirmationPolicy()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let parked = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let detection = AutoParkingDetectionSnapshot(
            coordinate: parked,
            confidence: 0.76,
            stationaryDuration: 120,
            clusterRadius: 12,
            triggerSource: "gps+stability",
            detectedAt: base
        )
        let current = makeSample(
            at: coordinate(from: parked, northMeters: 60),
            secondsFrom: base,
            offset: 32,
            speed: 1.1,
            accuracy: 8
        )

        let decision = policy.evaluate(
            detection: detection,
            sample: current,
            previousSample: nil,
            previousDistance: nil
        )

        XCTAssertEqual(decision.requiredDistance, 70)
        XCTAssertEqual(decision.action, .waiting)
    }

    func testWalkAwayPolicyExpiresOldCandidate() {
        let policy = AutoParkingWalkAwayConfirmationPolicy()
        let base = Date(timeIntervalSince1970: 1_710_000_000)
        let parked = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let detection = AutoParkingDetectionSnapshot(
            coordinate: parked,
            confidence: 0.88,
            stationaryDuration: 120,
            clusterRadius: 6,
            triggerSource: "gps+stability",
            detectedAt: base
        )
        let current = makeSample(
            at: coordinate(from: parked, northMeters: 90),
            secondsFrom: base,
            offset: 13 * 60,
            speed: 1.1,
            accuracy: 8
        )

        let decision = policy.evaluate(
            detection: detection,
            sample: current,
            previousSample: nil,
            previousDistance: nil
        )

        XCTAssertEqual(decision.action, .clearCandidate(reason: "expired"))
    }
}
