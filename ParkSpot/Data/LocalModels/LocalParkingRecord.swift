import Foundation

nonisolated struct LocalParkingRecord: Codable {
    let id: String
    let userId: String
    let latitude: Double
    let longitude: Double
    let encryptedAddress: Data?    // AES-256-GCM encrypted
    let encryptedNote: Data?       // AES-256-GCM encrypted
    let parkingLevel: String?
    let zone: String
    let startTime: Date
    let endTime: Date?
    let maxDuration: Double?
    let photoPath: String?
    let isApproximate: Bool
    var isSynced: Bool

    init(
        id: String,
        userId: String,
        latitude: Double,
        longitude: Double,
        encryptedAddress: Data?,
        encryptedNote: Data?,
        parkingLevel: String?,
        zone: String,
        startTime: Date,
        endTime: Date?,
        maxDuration: Double?,
        photoPath: String?,
        isApproximate: Bool,
        isSynced: Bool
    ) {
        self.id = id
        self.userId = userId
        self.latitude = latitude
        self.longitude = longitude
        self.encryptedAddress = encryptedAddress
        self.encryptedNote = encryptedNote
        self.parkingLevel = parkingLevel
        self.zone = zone
        self.startTime = startTime
        self.endTime = endTime
        self.maxDuration = maxDuration
        self.photoPath = photoPath
        self.isApproximate = isApproximate
        self.isSynced = isSynced
    }

    enum CodingKeys: String, CodingKey {
        case id, userId, latitude, longitude, encryptedAddress, encryptedNote
        case parkingLevel, zone, startTime, endTime, maxDuration, photoPath
        case isApproximate, isSynced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        encryptedAddress = try container.decodeIfPresent(Data.self, forKey: .encryptedAddress)
        encryptedNote = try container.decodeIfPresent(Data.self, forKey: .encryptedNote)
        parkingLevel = try container.decodeIfPresent(String.self, forKey: .parkingLevel)
        zone = try container.decode(String.self, forKey: .zone)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        maxDuration = try container.decodeIfPresent(Double.self, forKey: .maxDuration)
        photoPath = try container.decodeIfPresent(String.self, forKey: .photoPath)
        isApproximate = try container.decodeIfPresent(Bool.self, forKey: .isApproximate) ?? false
        isSynced = try container.decode(Bool.self, forKey: .isSynced)
    }
}
