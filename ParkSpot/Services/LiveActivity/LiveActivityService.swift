// LiveActivityService.swift
// Manages Live Activity lifecycle with proper iOS 16.2+ compatibility

import ActivityKit
import Foundation

@MainActor
final class LiveActivityService {
    static let shared = LiveActivityService()
    private var currentActivity: Activity<ParkingLiveActivityAttributes>?
    
    private init() {}
    
    // MARK: - Public API
    
    @available(iOS 16.2, *)
    func requestLiveActivity(
        sessionId: UUID,
        startDate: Date,
        endDate: Date,
        address: String,
        zone: String,
        parkingLevel: String?,
        note: String?,
        latitude: Double,
        longitude: Double,
        distanceText: String?,
        maxDurationMinutes: Int?,
        hasTimer: Bool
    ) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LiveActivityError.activitiesNotAuthorized
        }
        
        let attributes = ParkingLiveActivityAttributes(sessionId: sessionId)
        let totalDuration = max(1, hasTimer ? startDate.distance(to: endDate) : 0)
        let elapsed = max(0, Date().timeIntervalSince(startDate))
        let progress = min(max(elapsed / totalDuration, 0), 1)
        
        let initialState = ParkingLiveActivityAttributes.ContentState(
            address: address,
            city: zone,
            isTimerActive: hasTimer,
            endTime: hasTimer ? endDate : nil,
            startTime: startDate,
            progressPercent: progress,
            parkingLevel: parkingLevel,
            note: sanitizeTechnicalRateToken(in: note)
        )
        
        let content = ActivityContent(
            state: initialState,
            staleDate: hasTimer ? endDate.addingTimeInterval(300) : Date().addingTimeInterval(3600)
        )

        if let existingActivity = Activity<ParkingLiveActivityAttributes>.activities.first(where: {
            $0.attributes.sessionId == sessionId
        }) {
            await existingActivity.update(content)
            currentActivity = existingActivity
            return
        }
        
        do {
            currentActivity = try Activity<ParkingLiveActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            print("[LiveActivity] Requested for session \(sessionId.uuidString)")
        } catch {
            throw LiveActivityError.requestFailed(error)
        }
    }
    
    @available(iOS 16.2, *)
    func updateLiveActivity(
        sessionId: UUID,
        endDate: Date,
        address: String,
        zone: String,
        parkingLevel: String?,
        note: String?,
        latitude: Double,
        longitude: Double,
        distanceText: String?,
        maxDurationMinutes: Int?,
        hasTimer: Bool
    ) async throws {
        guard let activity = Activity<ParkingLiveActivityAttributes>.activities.first(where: {
            $0.attributes.sessionId == sessionId
        }) else {
            throw LiveActivityError.activityNotFound
        }

        let startTime = activity.content.state.startTime
        let totalDuration = max(1, hasTimer ? endDate.timeIntervalSince(startTime) : 0)
        let elapsed = max(0, Date().timeIntervalSince(startTime))
        let progress = min(max(elapsed / totalDuration, 0), 1)
        
        let updatedState = ParkingLiveActivityAttributes.ContentState(
            address: address,
            city: zone,
            isTimerActive: hasTimer,
            endTime: hasTimer ? endDate : nil,
            startTime: startTime,
            progressPercent: progress,
            parkingLevel: parkingLevel,
            note: sanitizeTechnicalRateToken(in: note)
        )
        
        let content = ActivityContent(
            state: updatedState,
            staleDate: hasTimer ? endDate.addingTimeInterval(300) : Date().addingTimeInterval(3600)
        )
        
        await activity.update(content)
        currentActivity = activity
    }
    
    @available(iOS 16.2, *)
    func endLiveActivity(sessionId: UUID) async {
        if let activity = Activity<ParkingLiveActivityAttributes>.activities.first(where: {
            $0.attributes.sessionId == sessionId
        }) {
            await activity.end(nil, dismissalPolicy: .immediate)
            if currentActivity?.id == activity.id {
                currentActivity = nil
            }
        }
    }
    
    @available(iOS 16.2, *)
    func endAllActivities() async {
        for activity in Activity<ParkingLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    // MARK: - API demandée

    @available(iOS 16.2, *)
    func start(for session: ParkingSession) async throws {
        let endTime = session.maxDuration.map { session.startTime.addingTimeInterval($0) }
        try await requestLiveActivity(
            sessionId: session.id,
            startDate: session.startTime,
            endDate: endTime ?? session.startTime.addingTimeInterval(3600),
            address: session.address ?? "Saved location",
            zone: "Paris",
            parkingLevel: session.parkingLevel,
            note: session.note,
            latitude: session.coordinate.latitude,
            longitude: session.coordinate.longitude,
            distanceText: nil,
            maxDurationMinutes: session.maxDuration.map { Int($0 / 60) },
            hasTimer: endTime != nil
        )
    }

    @available(iOS 16.2, *)
    func update(progress: Double, distanceText: String? = nil) async {
        guard let activity = currentActivity else { return }

        let current = activity.content.state
        let updated = ParkingLiveActivityAttributes.ContentState(
            address: current.address,
            city: current.city,
            isTimerActive: current.isTimerActive,
            endTime: current.endTime,
            startTime: current.startTime,
            progressPercent: min(max(progress, 0), 1),
            parkingLevel: current.parkingLevel,
            note: current.note
        )

        await activity.update(ActivityContent(state: updated, staleDate: current.endTime))
    }

    @available(iOS 16.2, *)
    func end(sessionId: UUID) async {
        await endLiveActivity(sessionId: sessionId)
    }

    @available(iOS 16.2, *)
    func endAll() async {
        await endAllActivities()
    }
}

private extension LiveActivityService {
    func parseDistanceMeters(from raw: String?) -> Int {
        guard let raw else { return 0 }
        let lowered = raw
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let values = lowered
            .split(whereSeparator: { !"0123456789.".contains($0) })
            .compactMap { Double($0) }

        guard let numeric = values.first else { return 0 }
        if lowered.contains("km") {
            return Int((numeric * 1000).rounded())
        }
        return Int(numeric.rounded())
    }

    func sanitizeTechnicalRateToken(in value: String?) -> String? {
        guard let value else { return nil }
        let patterns = [
            #"\s*\[\[(?:I?PS)_RATE_[A-Z]{3}:[0-9]+(?:[\.,][0-9]+)?\]\]"#,
            #"\s*(?:I?PS)_RATE_[A-Z]{3}:[0-9]+(?:[\.,][0-9]+)?"#
        ]

        var cleaned = value
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // Méthodes conservées volontairement pour compatibilité future.
}

enum LiveActivityError: LocalizedError {
    case activitiesNotAuthorized
    case requestFailed(Error)
    case activityNotFound
    case invalidState
    
    var errorDescription: String? {
        switch self {
        case .activitiesNotAuthorized:
            return "Live Activities are not allowed".psLocalized
        case .requestFailed(let error):
            return String(format: "Creation failed: %@".psLocalized, error.localizedDescription)
        case .activityNotFound:
            return "Activity not found".psLocalized
        case .invalidState:
            return "Invalid activity state".psLocalized
        }
    }
}

// MARK: - Timer for updating Live Activities every minute
