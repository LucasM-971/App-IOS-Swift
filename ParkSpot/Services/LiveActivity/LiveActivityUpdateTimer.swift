import ActivityKit
import Foundation

@available(iOS 16.2, *)
final class LiveActivityUpdateTimer {
    static let shared = LiveActivityUpdateTimer()
    
    private var timer: Timer?
    private var timerToken: UUID?
    private let service = LiveActivityService.shared
    
    private init() {}
    
    func startUpdating(
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
    ) {
        stopUpdating()

        guard hasTimer, endDate > Date() else { return }
        
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard endDate > Date() else {
                self.stopUpdating()
                return
            }

            Task { @MainActor in
                do {
                    try await self.service.updateLiveActivity(
                        sessionId: sessionId,
                        endDate: endDate,
                        address: address,
                        zone: zone,
                        parkingLevel: parkingLevel,
                        note: note,
                        latitude: latitude,
                        longitude: longitude,
                        distanceText: distanceText,
                        maxDurationMinutes: maxDurationMinutes,
                        hasTimer: hasTimer
                    )
                } catch {
                    print("[LiveActivityTimer] Update failed: \(error)")
                }
            }
        }

        if let timer {
            timer.tolerance = 10
            timerToken = TimerRegistry.shared.register(timer, priority: .critical)
        }
        
        // Initial update immediately
        timer?.fire()
    }
    
    func stopUpdating() {
        timer?.invalidate()
        timer = nil
        if let timerToken {
            TimerRegistry.shared.unregister(timerToken)
            self.timerToken = nil
        }
    }
}
