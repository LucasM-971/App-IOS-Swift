// DeadReckoningService.swift
// Estimation de position en intérieur via pas + capteurs (100% hors-ligne)

import Foundation
import Combine
import CoreLocation
import CoreMotion
import UIKit

protocol DeadReckoningServiceProtocol {
    var estimatedCoordinate: AnyPublisher<Coordinate, Never> { get }
    var trackedPath: AnyPublisher<[Coordinate], Never> { get }
    func startTracking(from lastKnownCoordinate: Coordinate)
    func stopTracking()
    func reset()
}

final class DeadReckoningService: DeadReckoningServiceProtocol {

    private let pedometer: CMPedometer
    private let motionManager: CMMotionManager
    private let headingPublisher: AnyPublisher<CLHeading?, Never>
    private let stepLengthProvider: () -> Double
    private let maxDistanceMeters: Double
    private let timerFactory: (TimeInterval, @escaping () -> Void) -> AnyCancellable
    private let recomputeInterval: TimeInterval
    private let motionUpdateInterval: TimeInterval

    private let estimatedCoordinateSubject = CurrentValueSubject<Coordinate, Never>(.zero)
    private let trackedPathSubject = CurrentValueSubject<[Coordinate], Never>([])

    private var trackingStartCoordinate: Coordinate?
    private var trackingStartDate: Date?
    private var latestHeadingDegrees: Double?
    private var latestYawDegrees: Double = 0
    private var smoothedHeadingDegrees: Double?
    private var totalSteps: Double = 0
    private var appliedSteps: Double = 0
    private var lastEstimatedCoordinate: Coordinate?
    private var cancellables = Set<AnyCancellable>()
    private var trackingTimer: AnyCancellable?
    private var pedometerActive = false
    private var isTracking = false
    private var isSuspendedForBackground = false
    private var lifecycleCancellables = Set<AnyCancellable>()

    var estimatedCoordinate: AnyPublisher<Coordinate, Never> {
        estimatedCoordinateSubject.eraseToAnyPublisher()
    }

    var trackedPath: AnyPublisher<[Coordinate], Never> {
        trackedPathSubject.eraseToAnyPublisher()
    }

    init(
        pedometer: CMPedometer = CMPedometer(),
        motionManager: CMMotionManager = CMMotionManager(),
        headingPublisher: AnyPublisher<CLHeading?, Never>,
        stepLengthProvider: @escaping () -> Double = {
            let saved = UserDefaults.standard.object(forKey: "settings.stepLengthMeters") as? Double
            return min(max(saved ?? 0.75, 0.4), 1.2)
        },
        maxDistanceMeters: Double = 500,
        recomputeInterval: TimeInterval = 1.5,
        motionUpdateInterval: TimeInterval = 0.5,
        timerFactory: @escaping (TimeInterval, @escaping () -> Void) -> AnyCancellable = { interval, block in
            Timer.publish(every: interval, on: .main, in: .common)
                .autoconnect()
                .sink { _ in block() }
        }
    ) {
        self.pedometer = pedometer
        self.motionManager = motionManager
        self.headingPublisher = headingPublisher
        self.stepLengthProvider = stepLengthProvider
        self.maxDistanceMeters = maxDistanceMeters
        self.recomputeInterval = max(1.0, recomputeInterval)
        self.motionUpdateInterval = max(0.3, motionUpdateInterval)
        self.timerFactory = timerFactory
        bindHeading()
        bindLifecycleEvents()
    }

    func startTracking(from lastKnownCoordinate: Coordinate) {
        reset()
        isTracking = true
        isSuspendedForBackground = false

        trackingStartCoordinate = lastKnownCoordinate
        trackingStartDate = Date()
        estimatedCoordinateSubject.send(lastKnownCoordinate)
        trackedPathSubject.send([lastKnownCoordinate])
        lastEstimatedCoordinate = lastKnownCoordinate
        appliedSteps = 0

        startMotionUpdates()
        startPedometerUpdates()

        trackingTimer = timerFactory(recomputeInterval) { [weak self] in
            self?.recomputeEstimatedPosition()
        }
    }

    func stopTracking() {
        isTracking = false
        isSuspendedForBackground = false
        trackingTimer?.cancel()
        trackingTimer = nil
        motionManager.stopDeviceMotionUpdates()
        if pedometerActive {
            pedometer.stopUpdates()
            pedometerActive = false
        }
    }

    func reset() {
        stopTracking()
        totalSteps = 0
        appliedSteps = 0
        latestYawDegrees = 0
        smoothedHeadingDegrees = nil
        trackingStartCoordinate = nil
        trackingStartDate = nil
        lastEstimatedCoordinate = nil
        trackedPathSubject.send([])
        estimatedCoordinateSubject.send(.zero)
    }

    private func suspendForBackground() {
        guard isTracking else { return }
        isSuspendedForBackground = true
        trackingTimer?.cancel()
        trackingTimer = nil
        motionManager.stopDeviceMotionUpdates()
        if pedometerActive {
            pedometer.stopUpdates()
            pedometerActive = false
        }
    }

    private func resumeAfterBackgroundIfNeeded() {
        guard isTracking, isSuspendedForBackground else { return }
        isSuspendedForBackground = false
        startMotionUpdates()
        startPedometerUpdates()
        trackingTimer = timerFactory(recomputeInterval) { [weak self] in
            self?.recomputeEstimatedPosition()
        }
    }

    private func bindHeading() {
        headingPublisher
            .sink { [weak self] heading in
                guard let self, let heading else { return }
                // headingAccuracy == -1 → cap invalide ; >= 0 inclut boussole parfaitement calibrée (0°)
                guard heading.headingAccuracy >= 0 else { return }
                // trueHeading == -1 → pas de GPS dispo ; >= 0 couvre plein Nord (0°)
                let value = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
                self.latestHeadingDegrees = self.smoothAngle(previous: self.latestHeadingDegrees, next: value, alpha: 0.35)
            }
            .store(in: &cancellables)
    }

    private func startPedometerUpdates() {
        guard CMPedometer.isStepCountingAvailable(), let start = trackingStartDate else { return }
        pedometer.startUpdates(from: start) { [weak self] data, _ in
            guard let self else { return }
            self.totalSteps = data?.numberOfSteps.doubleValue ?? self.totalSteps
        }
        pedometerActive = true
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = motionUpdateInterval
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.latestYawDegrees = motion.attitude.yaw * 180 / .pi
        }
    }

    private func bindLifecycleEvents() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.suspendForBackground()
            }
            .store(in: &lifecycleCancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resumeAfterBackgroundIfNeeded()
            }
            .store(in: &lifecycleCancellables)
    }

    private func recomputeEstimatedPosition() {
        guard let current = lastEstimatedCoordinate ?? trackingStartCoordinate else { return }

        let stepLength = stepLengthProvider()
        let newSteps = max(0, totalSteps - appliedSteps)
        let deltaDistance = newSteps * stepLength
        let cumulativeDistance = totalSteps * stepLength

        guard deltaDistance > 0 else { return }

        if cumulativeDistance >= maxDistanceMeters {
            stopTracking()
            return
        }

        let headingSource = latestHeadingDegrees ?? latestYawDegrees
        let normalizedHeading = normalizeAngle(headingSource)
        smoothedHeadingDegrees = smoothAngle(previous: smoothedHeadingDegrees, next: normalizedHeading, alpha: 0.28)
        let headingForStep = smoothedHeadingDegrees ?? normalizedHeading

        let next = Self.estimateCoordinate(
            from: current,
            distanceMeters: deltaDistance,
            headingDegrees: headingForStep
        )

        appliedSteps = totalSteps
        lastEstimatedCoordinate = next
        estimatedCoordinateSubject.send(next)

        var path = trackedPathSubject.value
        if path.isEmpty || Self.distance(from: path.last ?? current, to: next) >= 1 {
            path.append(next)
            trackedPathSubject.send(path)
        }
    }

    private func normalizeAngle(_ angle: Double) -> Double {
        var normalized = angle.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return normalized
    }

    private func smoothAngle(previous: Double?, next: Double, alpha: Double) -> Double {
        guard let previous else { return normalizeAngle(next) }
        let prev = normalizeAngle(previous)
        let target = normalizeAngle(next)
        var delta = target - prev
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return normalizeAngle(prev + (alpha * delta))
    }

    static func estimateCoordinate(
        from start: Coordinate,
        distanceMeters: Double,
        headingDegrees: Double
    ) -> Coordinate {
        let earthRadius = 6_371_000.0
        let angularDistance = distanceMeters / earthRadius
        let bearing = headingDegrees * .pi / 180

        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180

        let lat2 = asin(
            sin(lat1) * cos(angularDistance) +
            cos(lat1) * sin(angularDistance) * cos(bearing)
        )

        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angularDistance) * cos(lat1),
            cos(angularDistance) - sin(lat1) * sin(lat2)
        )

        return Coordinate(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }

    static func distance(from a: Coordinate, to b: Coordinate) -> Double {
        let r = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(h), sqrt(1 - h))
    }
}
