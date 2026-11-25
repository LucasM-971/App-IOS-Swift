import Foundation

struct ParkingSessionDTO: Codable {
    let id: String
    let userId: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let note: String?
    let parkingLevel: String?
    let zone: String
    let startTime: Date
    let endTime: Date?
    let maxDuration: Double?
    let isApproximate: Bool?

    func toDomain() -> ParkingSession {
        ParkingSession(
            id: UUID(uuidString: id) ?? UUID(),
            userId: UUID(uuidString: userId) ?? UUID(),
            coordinate: Coordinate(latitude: latitude, longitude: longitude),
            address: address,
            note: note,
            parkingLevel: parkingLevel,
            startTime: startTime,
            endTime: endTime,
            maxDuration: maxDuration,
            zone: ParkingZone(rawValue: zone) ?? .unknown,
            isSynced: true,
            isApproximate: isApproximate ?? false
        )
    }
}
