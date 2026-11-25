import Foundation
import CoreLocation
import Combine

final class PredictionService {
    struct PredictionResult {
        let suggestedDuration: TimeInterval
        let confidence: Double
        let basedOnCount: Int
        let contextProfile: String
        let isAnomalous: Bool
        let conservativeDuration: TimeInterval
        let aggressiveDuration: TimeInterval
        let freshnessDays: Int
        let explanation: String
    }

    private let minimumSessions = 5
    private let maxDuration: TimeInterval = 12 * 3600
    private let minDuration: TimeInterval = 5 * 60
    private let defaults = UserDefaults.standard
    private let correctionPrefix = "prediction.correction.v1"
    private let resetDatePrefix = "prediction.resetDate.v1"
    private let vehicleProfileStore = VehicleProfileStore()

    func predictDuration(from history: [ParkingSession], target: ParkingSession?, userId: UUID?) -> PredictionResult? {
        let scopedHistory: [ParkingSession]
        if let userId, let resetDate = resetDate(for: userId) {
            scopedHistory = history.filter { $0.startTime >= resetDate }
        } else {
            scopedHistory = history
        }

        let completed = scopedHistory.compactMap { session -> (ParkingSession, TimeInterval)? in
            guard let end = session.endTime else { return nil }
            let duration = min(max(end.timeIntervalSince(session.startTime), minDuration), maxDuration)
            return (session, duration)
        }
        guard completed.count >= minimumSessions else { return nil }

        let filtered = removeOutliers(from: completed)
        guard filtered.count >= minimumSessions else { return nil }

        // If no active target exists (new save flow), reference the latest known context.
        let referenceSession: ParkingSession = target ?? filtered.max(by: { $0.0.startTime < $1.0.startTime })!.0
        let referenceDate = referenceSession.startTime
        let referenceCoordinate = referenceSession.coordinate
        let referenceProfile = contextProfile(for: referenceDate)

        let weighted = filtered.map { sample -> (duration: TimeInterval, weight: Double) in
            let locationScore = spatialScore(distanceMeters: haversine(sample.0.coordinate, referenceCoordinate))
            let temporalScore = temporalSimilarity(sample.0.startTime, referenceDate)
            let hourScore = hourSimilarity(sample.0.startTime, referenceDate)
            let weekPartScore = weekPartSimilarity(sample.0.startTime, referenceDate)
            let profileScore = contextProfile(for: sample.0.startTime) == referenceProfile ? 1.0 : 0.55
            let zoneScore = sample.0.zone == referenceSession.zone ? 1.0 : 0.45
            let recencyScore = recencyWeight(sample.0.startTime, referenceDate)

            // Weighted blend of multiple independent signals.
            let score =
                (locationScore * 0.24) +
                (temporalScore * 0.16) +
                (hourScore * 0.14) +
                (weekPartScore * 0.10) +
                (profileScore * 0.14) +
                (zoneScore * 0.08) +
                (recencyScore * 0.14)

            return (sample.1, max(0.05, min(1.0, score)))
        }

        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let predicted = weightedMedian(weighted)
        guard predicted.isFinite else { return nil }
        var binned = TimeInterval((Int(predicted / 300.0)).clamped(to: 1...144) * 300)

        if let userId {
            let correction = learnedCorrectionMinutes(for: referenceSession, userId: userId)
            binned += TimeInterval(correction * 60)
            guard binned.isFinite else { return nil }
            binned = TimeInterval((Int(binned / 300.0)).clamped(to: 1...144) * 300)
        }

        // Confidence = quality of fit + effective amount of information.
        let mad = weightedMAD(weighted, center: predicted)
        let fitConfidence = max(0.2, min(0.95, 1.0 - (mad / (2.5 * 3600))))
        let effectiveSampleFactor = min(1.0, Double(filtered.count) / 12.0)
        let confidence = max(0.25, min(0.95, (fitConfidence * 0.75) + (effectiveSampleFactor * 0.25)))

        let spread = max(15 * 60, min(2 * 3600, mad * 1.2))
        var conservative = max(minDuration, binned - spread)
        var aggressive = min(maxDuration, binned + spread)

        if conservative.isFinite {
            conservative = TimeInterval((Int(conservative / 300.0)).clamped(to: 1...144) * 300)
        } else {
            conservative = binned
        }

        if aggressive.isFinite {
            aggressive = TimeInterval((Int(aggressive / 300.0)).clamped(to: 1...144) * 300)
        } else {
            aggressive = binned
        }

        let latestSampleDate = filtered.map { $0.0.startTime }.max() ?? .now
        let freshnessInterval = Date().timeIntervalSince(latestSampleDate) / 86_400
        let freshnessDays = max(0, freshnessInterval.isFinite ? Int(freshnessInterval) : 0)

        let anomaly = isAnomalousPrediction(
            predicted: binned,
            reference: referenceSession,
            samples: filtered
        )

        let explanation = buildExplanation(
            confidence: confidence,
            sampleCount: filtered.count,
            freshnessDays: freshnessDays,
            anomaly: anomaly,
            contextProfile: referenceProfile
        )

        return PredictionResult(
            suggestedDuration: binned,
            confidence: confidence,
            basedOnCount: filtered.count,
            contextProfile: referenceProfile,
            isAnomalous: anomaly,
            conservativeDuration: conservative,
            aggressiveDuration: aggressive,
            freshnessDays: freshnessDays,
            explanation: explanation
        )
    }

    func registerTimerCorrection(
        selectedDuration: TimeInterval,
        suggestedDuration: TimeInterval,
        context: ParkingSession,
        userId: UUID
    ) {
        let rawDelta = (selectedDuration - suggestedDuration) / 60
        guard rawDelta.isFinite else { return }
        let deltaMinutes = Int(rawDelta.rounded())
        // Ignore tiny differences (user likely just adjusted to nearest 5 min)
        guard abs(deltaMinutes) >= 10 else { return }

        let key = correctionKey(for: context, userId: userId)
        let previous = defaults.double(forKey: key)
        let hasPrevious = defaults.object(forKey: key) != nil
        
        let blendedValue = previous * 0.75 + Double(deltaMinutes) * 0.25
        let blended = hasPrevious && blendedValue.isFinite
            ? Int(blendedValue.rounded())
            : deltaMinutes
        defaults.set(blended.clamped(to: -90...90), forKey: key)
    }

    @discardableResult
    func resetLearnedCorrections(for userId: UUID) -> Int {
        let prefix = "\(correctionPrefix).\(userId.uuidString)."
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        keys.forEach { defaults.removeObject(forKey: $0) }

        // Hard reset: from now on, prediction only learns from newly created sessions.
        defaults.set(Date(), forKey: resetDateKey(for: userId))
        return keys.count
    }

    private func resetDate(for userId: UUID) -> Date? {
        defaults.object(forKey: resetDateKey(for: userId)) as? Date
    }

    private func resetDateKey(for userId: UUID) -> String {
        "\(resetDatePrefix).\(userId.uuidString)"
    }

    private func temporalSimilarity(_ a: Date, _ b: Date) -> Double {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: a) == cal.component(.weekday, from: b) ? 1.0 : 0.6
        let hourDiff = abs(cal.component(.hour, from: a) - cal.component(.hour, from: b))
        let hourScore = max(0.2, 1.0 - (Double(hourDiff) / 12.0))
        return (weekday + hourScore) / 2
    }

    private func hourSimilarity(_ a: Date, _ b: Date) -> Double {
        let cal = Calendar.current
        let h1 = cal.component(.hour, from: a)
        let h2 = cal.component(.hour, from: b)
        let diff = min(abs(h1 - h2), 24 - abs(h1 - h2))
        return max(0.15, 1.0 - (Double(diff) / 10.0))
    }

    private func weekPartSimilarity(_ a: Date, _ b: Date) -> Double {
        let cal = Calendar.current
        let wa = cal.isDateInWeekend(a)
        let wb = cal.isDateInWeekend(b)
        return wa == wb ? 1.0 : 0.45
    }

    private func recencyWeight(_ sampleDate: Date, _ referenceDate: Date) -> Double {
        let days = abs(referenceDate.timeIntervalSince(sampleDate)) / 86_400
        // Half-life around 45 days.
        return max(0.25, pow(0.5, days / 45.0))
    }

    private func spatialScore(distanceMeters: Double) -> Double {
        if distanceMeters <= 80 { return 1.0 }
        if distanceMeters <= 250 { return 0.85 }
        if distanceMeters <= 700 { return 0.6 }
        if distanceMeters <= 1500 { return 0.35 }
        return 0.15
    }

    private func removeOutliers(from samples: [(ParkingSession, TimeInterval)]) -> [(ParkingSession, TimeInterval)] {
        let durations = samples.map { $0.1 }.sorted()
        guard durations.count >= 8 else { return samples }

        let q1 = percentile(durations, 0.25)
        let q3 = percentile(durations, 0.75)
        let iqr = q3 - q1
        let low = q1 - (1.5 * iqr)
        let high = q3 + (1.5 * iqr)
        return samples.filter { $0.1 >= low && $0.1 <= high }
    }

    private func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let clampedP = max(0, min(1, p))
        let idx = clampedP * Double(sorted.count - 1)
        let lower = Int(idx.rounded(.down))
        let upper = Int(idx.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = idx - Double(lower)
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * fraction)
    }

    private func weightedMedian(_ weighted: [(duration: TimeInterval, weight: Double)]) -> TimeInterval {
        let sorted = weighted.sorted { $0.duration < $1.duration }
        let total = sorted.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return sorted.map(\.duration).reduce(0, +) / Double(max(sorted.count, 1)) }

        var cumulative = 0.0
        for item in sorted {
            cumulative += item.weight
            if cumulative >= total / 2 {
                return item.duration
            }
        }
        return sorted.last?.duration ?? 60 * 60
    }

    private func weightedMAD(_ weighted: [(duration: TimeInterval, weight: Double)], center: TimeInterval) -> TimeInterval {
        let deviations = weighted.map { (duration: abs($0.duration - center), weight: $0.weight) }
        return weightedMedian(deviations)
    }

    private func contextProfile(for date: Date) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let isWeekend = cal.isDateInWeekend(date)

        let base: String
        switch hour {
        case 6...10:
            base = "Matin"
        case 11...15:
            base = "Midi / Courses"
        case 16...19:
            base = "Après-midi"
        case 20...23:
            base = "Soirée"
        default:
            base = "Nuit"
        }
        return isWeekend ? "Weekend · \(base)" : "Semaine · \(base)"
    }

    private func isAnomalousPrediction(
        predicted: TimeInterval,
        reference: ParkingSession,
        samples: [(ParkingSession, TimeInterval)]
    ) -> Bool {
        let referenceProfile = contextProfile(for: reference.startTime)
        let neighbors = samples
            .filter {
                contextProfile(for: $0.0.startTime) == referenceProfile
                && haversine($0.0.coordinate, reference.coordinate) < 1500
            }
            .map { $0.1 }

        guard neighbors.count >= 4 else { return false }
        let sorted = neighbors.sorted()
        let median = percentile(sorted, 0.5)
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = percentile(deviations, 0.5)
        let threshold = max(45 * 60, 2.5 * mad)
        return abs(predicted - median) > threshold
    }

    private func learnedCorrectionMinutes(for context: ParkingSession, userId: UUID) -> Int {
        let key = correctionKey(for: context, userId: userId)
        let value = defaults.object(forKey: key) as? Int ?? 0
        return value.clamped(to: -90...90)
    }

    private func correctionKey(for context: ParkingSession, userId: UUID) -> String {
        let profile = contextProfile(for: context.startTime)
        let normalizedProfile = profile.replacingOccurrences(of: " ", with: "_")
        return "\(correctionPrefix).\(userId.uuidString).\(context.zone.rawValue).\(normalizedProfile)"
    }

    private func buildExplanation(
        confidence: Double,
        sampleCount: Int,
        freshnessDays: Int,
        anomaly: Bool,
        contextProfile: String
    ) -> String {
        var parts: [String] = []

        if confidence >= 0.75 {
            parts.append("Confiance élevée")
        } else if confidence >= 0.55 {
            parts.append("Confiance moyenne")
        } else {
            parts.append("Confiance limitée")
        }

        parts.append("\(sampleCount) sessions comparables")

        if freshnessDays <= 7 {
            parts.append("données récentes")
        } else if freshnessDays <= 30 {
            parts.append("données partiellement récentes")
        } else {
            parts.append("données anciennes")
        }

        parts.append(contextProfile)

        if anomaly {
            parts.append("profil inhabituel")
        }

        if let vehicle = vehicleProfileStore.load() {
            let monthly = Int(vehicle.estimatedMonthlyEnergyBudgetEUR.rounded())
            let consumption = String(format: "%.1f", vehicle.averageConsumptionPer100Km)
            parts.append("tracker \(vehicle.type.trackerLabel) actif")
            parts.append("~\(monthly) €/mois (\(consumption)/100 km)")
        }

        return parts.joined(separator: " · ")
    }

    private func haversine(_ a: Coordinate, _ b: Coordinate) -> Double {
        let R = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(h), sqrt(1 - h))
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
