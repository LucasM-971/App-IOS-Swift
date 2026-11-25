import Foundation
import Combine
import CoreLocation

struct AutoParkingDetectionSnapshot: Equatable {
    let coordinate: Coordinate
    let confidence: Double
    let stationaryDuration: TimeInterval
    let clusterRadius: Double
    let triggerSource: String
    let detectedAt: Date

    init(
        coordinate: Coordinate,
        confidence: Double,
        stationaryDuration: TimeInterval,
        clusterRadius: Double,
        triggerSource: String,
        detectedAt: Date = .now
    ) {
        self.coordinate = coordinate
        self.confidence = confidence
        self.stationaryDuration = stationaryDuration
        self.clusterRadius = clusterRadius
        self.triggerSource = triggerSource
        self.detectedAt = detectedAt
    }
}

struct AutoParkingHeuristicConfiguration {
    var reliableAccuracyThreshold: Double = 45
    var stillSpeedThreshold: Double = 1.35
    var stationaryRadiusMeters: Double = 28
    var minimumStationarySamples: Int = 3
    var minimumStationaryDuration: TimeInterval = 24
    var drivingLookback: TimeInterval = 5 * 60
    var minimumDrivingDistance: Double = 250
    var minimumPeakDrivingSpeed: Double = 6.8
    var minimumRollingSpeed: Double = 2.2
    var maximumGapBetweenDriveAndStop: TimeInterval = 90
    var bluetoothContextWindow: TimeInterval = 150
    var transitionLookbackWindow: TimeInterval = 140
    var maxPostDriveDriftMeters: Double = 140
    var walkingLikeSpeedThreshold: Double = 1.0
    var maximumWalkingLikeSpeedThreshold: Double = 2.1
    var minimumWalkingLikeDriftBeforePrompt: Double = 14
    var maxWalkingLikeDriftBeforeStationary: Double = 34
    var minimumApproachSamplesNearStop: Int = 2
    var approachRadiusMeters: Double = 140
    var minimumConfidence: Double = 0.74
    var maximumLatestSampleAge: TimeInterval = 45
}

struct AutoParkingWalkAwayConfirmationConfiguration {
    var maximumAccuracyMeters: Double = 55
    var minimumWalkingSpeed: Double = 0.45
    var maximumWalkingSpeed: Double = 2.25
    var minimumInferredWalkingSpeed: Double = 0.35
    var maximumInferredWalkingSpeed: Double = 2.55
    var drivingAwaySpeed: Double = 3.8
    var drivingAwayInferredSpeed: Double = 3.2
    var staleCandidateDistanceMeters: Double = 420
    var candidateExpiration: TimeInterval = 12 * 60
    var lowConfidenceWalkAwayDistance: Double = 70
    var highConfidenceWalkAwayDistance: Double = 55
    var bluetoothWalkAwayDistance: Double = 45
    var minimumProgressMeters: Double = 4
}

struct AutoParkingWalkAwayConfirmationDecision: Equatable {
    enum Action: Equatable {
        case waiting
        case resetProgress
        case clearCandidate(reason: String)
        case countProgress
    }

    let action: Action
    let distanceFromParked: Double
    let requiredDistance: Double
    let inferredSpeed: Double
}

struct AutoParkingWalkAwayConfirmationPolicy {
    let configuration: AutoParkingWalkAwayConfirmationConfiguration

    init(configuration: AutoParkingWalkAwayConfirmationConfiguration = AutoParkingWalkAwayConfirmationConfiguration()) {
        self.configuration = configuration
    }

    func evaluate(
        detection: AutoParkingDetectionSnapshot,
        sample: LocationSample,
        previousSample: LocationSample?,
        previousDistance: Double?
    ) -> AutoParkingWalkAwayConfirmationDecision {
        let distanceFromParked = distance(from: sample.coordinate, to: detection.coordinate)
        let requiredDistance = requiredWalkAwayDistance(for: detection)
        let inferredSpeed = inferredSpeedBetween(previousSample, sample) ?? max(0, sample.speed)

        if sample.date.timeIntervalSince(detection.detectedAt) > configuration.candidateExpiration {
            return decision(
                .clearCandidate(reason: "expired"),
                distanceFromParked: distanceFromParked,
                requiredDistance: requiredDistance,
                inferredSpeed: inferredSpeed
            )
        }

        guard sample.accuracy > 0, sample.accuracy <= configuration.maximumAccuracyMeters else {
            return decision(
                .resetProgress,
                distanceFromParked: distanceFromParked,
                requiredDistance: requiredDistance,
                inferredSpeed: inferredSpeed
            )
        }

        let gpsSpeed = max(0, sample.speed)
        let inferredSpeedLooksWalking =
            inferredSpeed >= configuration.minimumInferredWalkingSpeed &&
            inferredSpeed <= configuration.maximumInferredWalkingSpeed
        let gpsSpeedDoesNotContradictWalking = gpsSpeed <= configuration.maximumWalkingSpeed
        let isWalkingLike = inferredSpeedLooksWalking && gpsSpeedDoesNotContradictWalking

        if !isWalkingLike {
            if gpsSpeed >= configuration.drivingAwaySpeed ||
                inferredSpeed >= configuration.drivingAwayInferredSpeed ||
                distanceFromParked >= configuration.staleCandidateDistanceMeters {
                return decision(
                    .clearCandidate(reason: "vehicle_moved"),
                    distanceFromParked: distanceFromParked,
                    requiredDistance: requiredDistance,
                    inferredSpeed: inferredSpeed
                )
            }

            return decision(
                .resetProgress,
                distanceFromParked: distanceFromParked,
                requiredDistance: requiredDistance,
                inferredSpeed: inferredSpeed
            )
        }

        guard distanceFromParked >= requiredDistance else {
            return decision(
                .waiting,
                distanceFromParked: distanceFromParked,
                requiredDistance: requiredDistance,
                inferredSpeed: inferredSpeed
            )
        }

        if let previousDistance,
           distanceFromParked <= previousDistance + configuration.minimumProgressMeters {
            return decision(
                .waiting,
                distanceFromParked: distanceFromParked,
                requiredDistance: requiredDistance,
                inferredSpeed: inferredSpeed
            )
        }

        return decision(
            .countProgress,
            distanceFromParked: distanceFromParked,
            requiredDistance: requiredDistance,
            inferredSpeed: inferredSpeed
        )
    }

    func requiredWalkAwayDistance(for detection: AutoParkingDetectionSnapshot) -> Double {
        if detection.triggerSource.localizedCaseInsensitiveContains("+bt") {
            return configuration.bluetoothWalkAwayDistance
        }

        if detection.confidence >= 0.88 {
            return configuration.highConfidenceWalkAwayDistance
        }

        return configuration.lowConfidenceWalkAwayDistance
    }

    private func inferredSpeedBetween(_ previous: LocationSample?, _ current: LocationSample) -> Double? {
        guard let previous else { return nil }
        let elapsed = current.date.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return nil }
        return distance(from: previous.coordinate, to: current.coordinate) / elapsed
    }

    private func decision(
        _ action: AutoParkingWalkAwayConfirmationDecision.Action,
        distanceFromParked: Double,
        requiredDistance: Double,
        inferredSpeed: Double
    ) -> AutoParkingWalkAwayConfirmationDecision {
        AutoParkingWalkAwayConfirmationDecision(
            action: action,
            distanceFromParked: distanceFromParked,
            requiredDistance: requiredDistance,
            inferredSpeed: inferredSpeed
        )
    }
}

struct AutoParkingDetectionHeuristic {
    let configuration: AutoParkingHeuristicConfiguration

    init(configuration: AutoParkingHeuristicConfiguration = AutoParkingHeuristicConfiguration()) {
        self.configuration = configuration
    }

    func evaluate(
        samples: [LocationSample],
        bluetoothDisconnectAt: Date?,
        now: Date = .now
    ) -> AutoParkingDetectionSnapshot? {
        let lookback = max(configuration.drivingLookback, configuration.minimumStationaryDuration + 120)
        let recent = samples
            .filter {
                $0.coordinate.isValidGeoCoordinate &&
                $0.date <= now.addingTimeInterval(5) &&
                now.timeIntervalSince($0.date) <= lookback
            }
            .sorted { $0.date < $1.date }
        let reliable = recent.filter { $0.accuracy > 0 && $0.accuracy <= configuration.reliableAccuracyThreshold }

        guard reliable.count >= configuration.minimumStationarySamples,
              let latest = reliable.last else {
            return nil
        }

        guard now.timeIntervalSince(latest.date) <= configuration.maximumLatestSampleAge else {
            return nil
        }

        let stationarySamples = trailingStationarySamples(in: reliable)
        guard stationarySamples.count >= configuration.minimumStationarySamples,
              let stationaryStart = stationarySamples.first?.date else {
            return nil
        }

        let stationaryDuration = latest.date.timeIntervalSince(stationaryStart)
        guard stationaryDuration >= configuration.minimumStationaryDuration else {
            return nil
        }

        let parkedCoordinate = weightedCoordinate(for: stationarySamples)
        let clusterRadius = stationarySamples
            .map { distance(from: $0.coordinate, to: parkedCoordinate) }
            .max() ?? 0

        guard clusterRadius <= configuration.stationaryRadiusMeters else {
            return nil
        }

        let drivingSamples = recent.filter {
            $0.date < stationaryStart &&
            stationaryStart.timeIntervalSince($0.date) <= configuration.drivingLookback
        }
        let peakDrivingSample = drivingSamples.last(where: { $0.speed >= configuration.minimumPeakDrivingSpeed })
        let peakSpeed = peakDrivingSample?.speed ?? 0
        let peakDrivingAge = peakDrivingSample.map { stationaryStart.timeIntervalSince($0.date) } ?? .infinity
        let rollingSamples = drivingSamples.filter { $0.speed >= configuration.minimumRollingSpeed }
        let drivingDistance = pathDistance(of: drivingSamples)
        let transitionWindowStart = stationaryStart.addingTimeInterval(-configuration.transitionLookbackWindow)
        let transitionSamples = drivingSamples.filter { $0.date >= transitionWindowStart }

        let approachSamplesNearStop = transitionSamples.filter {
            $0.speed >= configuration.minimumRollingSpeed &&
            distance(from: $0.coordinate, to: parkedCoordinate) <= configuration.approachRadiusMeters
        }

        let walkingLikeTransitionSamples = transitionSamples.filter {
            $0.speed >= configuration.walkingLikeSpeedThreshold &&
            $0.speed < configuration.maximumWalkingLikeSpeedThreshold
        }
        let walkingLikeDrift = pathDistance(of: walkingLikeTransitionSamples)
        let postDriveDrift = peakDrivingSample.map {
            distance(from: $0.coordinate, to: parkedCoordinate)
        } ?? .infinity

        let bluetoothBoost = bluetoothDisconnectAt.map {
            now.timeIntervalSince($0) <= configuration.bluetoothContextWindow
        } ?? false

        guard bluetoothBoost || (
            peakSpeed >= configuration.minimumPeakDrivingSpeed &&
            peakDrivingAge <= configuration.maximumGapBetweenDriveAndStop &&
            drivingDistance >= configuration.minimumDrivingDistance &&
            rollingSamples.count >= 3
        ) else {
            return nil
        }

        guard bluetoothBoost || (
            approachSamplesNearStop.count >= configuration.minimumApproachSamplesNearStop &&
            postDriveDrift <= configuration.maxPostDriveDriftMeters &&
            walkingLikeDrift <= configuration.minimumWalkingLikeDriftBeforePrompt
        ) else {
            return nil
        }

        let averageStillSpeed = stationarySamples.reduce(0) { $0 + max(0, $1.speed) } / Double(stationarySamples.count)
        let medianAccuracy = median(of: stationarySamples.map(\.accuracy))
        let drivingScore: Double = {
            if bluetoothBoost { return 1.0 }
            let peakComponent = min(1, peakSpeed / 11.0)
            let distanceComponent = min(1, drivingDistance / 450.0)
            return (peakComponent * 0.58) + (distanceComponent * 0.42)
        }()
        let stillnessScore = min(1, stationaryDuration / (configuration.minimumStationaryDuration + 30))
        let stabilityScore = max(0, 1 - (clusterRadius / configuration.stationaryRadiusMeters))
        let accuracyScore = max(0, 1 - ((medianAccuracy - 5) / max(10, configuration.reliableAccuracyThreshold - 5)))
        let stillSpeedScore = max(0, 1 - (averageStillSpeed / max(0.1, configuration.stillSpeedThreshold + 0.25)))
        let approachScore = min(1, Double(approachSamplesNearStop.count) / Double(max(1, configuration.minimumApproachSamplesNearStop + 1)))
        let antiWalkScore = max(0, 1 - (walkingLikeDrift / max(1, configuration.minimumWalkingLikeDriftBeforePrompt)))
        let postDriveDriftScore = bluetoothBoost ? 1 : max(0, 1 - (postDriveDrift / max(1, configuration.maxPostDriveDriftMeters)))

        let bluetoothBonus = bluetoothBoost ? 0.06 : 0
        let confidence = min(
            1,
            (drivingScore * 0.26) +
            (stillnessScore * 0.24) +
            (stabilityScore * 0.16) +
            (accuracyScore * 0.10) +
            (stillSpeedScore * 0.09) +
            (approachScore * 0.06) +
            (antiWalkScore * 0.05) +
            (postDriveDriftScore * 0.04) +
            bluetoothBonus
        )

        guard confidence >= configuration.minimumConfidence else {
            return nil
        }

        return AutoParkingDetectionSnapshot(
            coordinate: parkedCoordinate,
            confidence: confidence,
            stationaryDuration: stationaryDuration,
            clusterRadius: clusterRadius,
            triggerSource: bluetoothBoost ? "gps+stability+bt" : "gps+stability",
            detectedAt: now
        )
    }
}

@MainActor
final class AutoParkingDetectionCoordinator {
    typealias EligibilityProvider = () -> Bool
    typealias ConfirmationHandler = @MainActor (AutoParkingDetectionSnapshot) async -> Void

    private let locationService: LocationServiceProtocol
    private let bluetoothService: BluetoothMonitoringServiceProtocol?
    private let heuristic: AutoParkingDetectionHeuristic
    private let nowProvider: () -> Date
    private let shouldMonitor: EligibilityProvider
    private let onConfirmed: ConfirmationHandler

    private var cancellables = Set<AnyCancellable>()
    private var history: [LocationSample] = []
    private var lastBluetoothDisconnectAt: Date?
    private var lastDetectionDate: Date?
    private var lastDetectionCoordinate: Coordinate?
    private var isRunning = false
    private var isHandlingConfirmation = false
    private var lastDebugLogAt: Date?
    private var lastHeuristicEvaluationAt: Date?
    private var lastHeuristicEvaluationCoordinate: Coordinate?

    private let retentionWindow: TimeInterval = 8 * 60
    private let cooldownDuration: TimeInterval = 12 * 60
    private let cooldownResetDistanceMeters: Double = 280
    private let maximumHistorySamples = 180
    private let minimumEvaluationDistanceMeters: Double = 12
    private let minimumEvaluationIntervalMoving: TimeInterval = 8
    private let minimumEvaluationIntervalStationary: TimeInterval = 4
    private let maximumEvaluationAccuracyMeters: Double = 75

    init(
        locationService: LocationServiceProtocol,
        bluetoothService: BluetoothMonitoringServiceProtocol?,
        heuristic: AutoParkingDetectionHeuristic,
        nowProvider: @escaping () -> Date = Date.init,
        shouldMonitor: @escaping EligibilityProvider,
        onConfirmed: @escaping ConfirmationHandler
    ) {
        self.locationService = locationService
        self.bluetoothService = bluetoothService
        self.heuristic = heuristic
        self.nowProvider = nowProvider
        self.shouldMonitor = shouldMonitor
        self.onConfirmed = onConfirmed
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        history.removeAll(keepingCapacity: true)
        lastHeuristicEvaluationAt = nil
        lastHeuristicEvaluationCoordinate = nil
        bindStreams()
        bluetoothService?.startMonitoring()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        history.removeAll(keepingCapacity: true)
        lastBluetoothDisconnectAt = nil
        isHandlingConfirmation = false
        lastHeuristicEvaluationAt = nil
        lastHeuristicEvaluationCoordinate = nil
        cancellables.removeAll()
        bluetoothService?.stopMonitoring()
    }

    private func bindStreams() {
        locationService.currentLocationSample
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                self?.consume(sample)
            }
            .store(in: &cancellables)

        bluetoothService?.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard case .carDisconnected = event else { return }
                self?.lastBluetoothDisconnectAt = self?.nowProvider()
            }
            .store(in: &cancellables)
    }

    private func consume(_ sample: LocationSample) {
        let now = nowProvider()

        guard shouldMonitor() else {
            history.removeAll(keepingCapacity: true)
            debugLog("monitoring disabled -> history cleared", now: now)
            return
        }

        history.append(sample)
        history.removeAll { now.timeIntervalSince($0.date) > retentionWindow }
        if history.count > maximumHistorySamples {
            history.removeFirst(history.count - maximumHistorySamples)
        }

        guard !isHandlingConfirmation else {
            debugLog("skip while confirmation in-flight", now: now)
            return
        }
        guard passesCooldown(for: sample.coordinate, now: now) else {
            debugLog("cooldown active", now: now)
            return
        }
        guard shouldEvaluateHeuristic(for: sample, now: now) else {
            debugLog("heuristic throttled", now: now)
            return
        }

        guard let detection = heuristic.evaluate(
            samples: history,
            bluetoothDisconnectAt: lastBluetoothDisconnectAt,
            now: now
        ) else {
            let speedText = String(format: "%.2f", sample.speed)
            debugLog(
                "no match (samples=\(history.count), acc=\(Int(sample.accuracy.rounded()))m, speed=\(speedText))",
                now: now
            )
            return
        }

        isHandlingConfirmation = true
        lastDetectionDate = now
        lastDetectionCoordinate = detection.coordinate
        lastBluetoothDisconnectAt = nil
        debugLog(
            "match conf=\(Int((detection.confidence * 100).rounded()))% source=\(detection.triggerSource)",
            now: now,
            force: true
        )

        Task { [weak self] in
            guard let self else { return }
            await onConfirmed(detection)
            self.isHandlingConfirmation = false
        }
    }

    private func passesCooldown(for coordinate: Coordinate, now: Date) -> Bool {
        guard let lastDetectionDate else { return true }
        let elapsed = now.timeIntervalSince(lastDetectionDate)
        if elapsed >= cooldownDuration {
            return true
        }

        guard let lastDetectionCoordinate else { return false }
        return distance(from: coordinate, to: lastDetectionCoordinate) >= cooldownResetDistanceMeters
    }

    private func shouldEvaluateHeuristic(for sample: LocationSample, now: Date) -> Bool {
        let configuration = heuristic.configuration
        let maxAllowedAccuracy = max(maximumEvaluationAccuracyMeters, configuration.reliableAccuracyThreshold * 1.5)
        guard sample.accuracy > 0, sample.accuracy <= maxAllowedAccuracy else {
            return false
        }

        let hasRecentBluetoothDisconnect = lastBluetoothDisconnectAt.map {
            now.timeIntervalSince($0) <= configuration.bluetoothContextWindow
        } ?? false
        let clearlyDriving = sample.speed >= (configuration.minimumRollingSpeed + 0.9)
        if clearlyDriving && !hasRecentBluetoothDisconnect {
            return false
        }

        if let lastHeuristicEvaluationAt {
            let minInterval = sample.speed <= configuration.stillSpeedThreshold
                ? minimumEvaluationIntervalStationary
                : minimumEvaluationIntervalMoving
            let enoughTime = now.timeIntervalSince(lastHeuristicEvaluationAt) >= minInterval

            let enoughDistance: Bool
            if let lastHeuristicEvaluationCoordinate {
                enoughDistance = distance(from: sample.coordinate, to: lastHeuristicEvaluationCoordinate) >= minimumEvaluationDistanceMeters
            } else {
                enoughDistance = true
            }

            if !enoughTime && !enoughDistance {
                return false
            }
        }

        lastHeuristicEvaluationAt = now
        lastHeuristicEvaluationCoordinate = sample.coordinate
        return true
    }

    private func debugLog(_ message: String, now: Date, force: Bool = false) {
        guard AppConfig.isDebugLoggingEnabled else { return }
        if !force,
           let lastDebugLogAt,
           now.timeIntervalSince(lastDebugLogAt) < 10 {
            return
        }
        lastDebugLogAt = now
        print("[AutoParking][Coordinator] \(message)")
    }
}

private extension AutoParkingDetectionHeuristic {
    func trailingStationarySamples(in samples: [LocationSample]) -> [LocationSample] {
        guard let latest = samples.last else { return [] }

        var collected = [latest]
        var anchor = latest.coordinate

        for sample in samples.dropLast().reversed() {
            guard let next = collected.first else { break }
            let segmentSpeed = inferredSegmentSpeed(from: sample, to: next)
            let effectiveSpeed = max(max(0, sample.speed), segmentSpeed)
            let distanceToAnchor = distance(from: sample.coordinate, to: anchor)

            guard effectiveSpeed <= configuration.stillSpeedThreshold,
                  distanceToAnchor <= configuration.stationaryRadiusMeters else {
                break
            }

            collected.insert(sample, at: 0)
            anchor = weightedCoordinate(for: collected)
        }

        return collected
    }

    func inferredSegmentSpeed(from lhs: LocationSample, to rhs: LocationSample) -> Double {
        let elapsed = rhs.date.timeIntervalSince(lhs.date)
        guard elapsed > 0 else { return 0 }
        return distance(from: lhs.coordinate, to: rhs.coordinate) / elapsed
    }
}

private func weightedCoordinate(for samples: [LocationSample]) -> Coordinate {
    guard !samples.isEmpty else { return .zero }

    var latitude = 0.0
    var longitude = 0.0
    var weightSum = 0.0

    for sample in samples {
        let weight = 1.0 / max(5, sample.accuracy)
        latitude += sample.coordinate.latitude * weight
        longitude += sample.coordinate.longitude * weight
        weightSum += weight
    }

    guard weightSum > 0 else { return samples[samples.count / 2].coordinate }
    return Coordinate(latitude: latitude / weightSum, longitude: longitude / weightSum)
}

private func pathDistance(of samples: [LocationSample]) -> Double {
    guard samples.count > 1 else { return 0 }

    return zip(samples, samples.dropFirst()).reduce(0) { partial, pair in
        partial + distance(from: pair.0.coordinate, to: pair.1.coordinate)
    }
}

private func median(of values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2

    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func distance(from lhs: Coordinate, to rhs: Coordinate) -> Double {
    let a = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
    let b = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
    return a.distance(from: b)
}
