import Foundation

struct CreateParkingRequestDTO: Encodable {
    let id: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let note: String?
    let parkingLevel: String?
    let zone: String
    let startTime: Date
    let endTime: Date?
    let maxDuration: Double?
    let isApproximate: Bool

    init(from session: ParkingSession) {
        self.id           = session.id.uuidString
        self.latitude     = session.coordinate.latitude
        self.longitude    = session.coordinate.longitude
        self.address      = session.address
        self.note         = session.note
        self.parkingLevel = session.parkingLevel
        self.zone         = session.zone.rawValue
        self.startTime    = session.startTime
        self.endTime      = session.endTime
        self.maxDuration  = session.maxDuration
        self.isApproximate = session.isApproximate
    }
}
