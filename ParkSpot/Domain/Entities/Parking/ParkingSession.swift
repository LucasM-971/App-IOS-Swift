import Foundation

struct ParkingSession: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let userId: UUID
    var coordinate: Coordinate
    var address: String?
    var photoPath: String?
    var note: String?
    var parkingLevel: String?
    var startTime: Date
    var endTime: Date?
    var maxDuration: TimeInterval?
    var zone: ParkingZone
    var isSynced: Bool
    var isApproximate: Bool

    var isActive: Bool { endTime == nil }

    var remainingTime: TimeInterval? {
        guard let maxDur = maxDuration else { return nil }
        let elapsed = Date.now.timeIntervalSince(startTime)
        let remaining = maxDur - elapsed
        return remaining > 0 ? remaining : 0
    }

    var isExpiringSoon: Bool {
        guard let remaining = remainingTime else { return false }
        return remaining < 1800
    }

    init(
        id: UUID = .init(),
        userId: UUID,
        coordinate: Coordinate,
        address: String? = nil,
        photoPath: String? = nil,
        note: String? = nil,
        parkingLevel: String? = nil,
        startTime: Date = .now,
        endTime: Date? = nil,
        maxDuration: TimeInterval? = nil,
        zone: ParkingZone = .unknown,
        isSynced: Bool = false,
        isApproximate: Bool = false
    ) {
        self.id           = id
        self.userId       = userId
        self.coordinate   = coordinate
        self.address      = address
        self.photoPath    = photoPath
        self.note         = note
        self.parkingLevel = parkingLevel
        self.startTime    = startTime
        self.endTime      = endTime
        self.maxDuration  = maxDuration
        self.zone         = zone
        self.isSynced     = isSynced
        self.isApproximate = isApproximate
    }
}
