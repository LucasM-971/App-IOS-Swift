import Foundation
import CoreLocation
import Combine

final class RemoteFrequentZoneDataSource {
    private let network: NetworkRequesting

    init(network: NetworkRequesting) {
        self.network = network
    }

    func fetchZones(userId: UUID, includeDeleted: Bool) async throws -> [FrequentZoneDTO] {
        let endpoint = Endpoint(
            path: "/frequent-zones",
            method: .get,
            queryItems: [
                URLQueryItem(name: "userId", value: userId.uuidString),
                URLQueryItem(name: "includeDeleted", value: includeDeleted ? "true" : "false"),
            ]
        )
        let response: APIResponse<[FrequentZoneDTO]> = try await network.request(endpoint)
        return response.data
    }

    func syncZones(_ zones: [FrequentZone], userId: UUID) async throws -> [FrequentZoneDTO] {
        struct SyncBody: Encodable {
            let userId: String
            let zones: [FrequentZoneUpsertDTO]
        }

        let endpoint = Endpoint(
            path: "/frequent-zones/sync",
            method: .post,
            body: SyncBody(
                userId: userId.uuidString,
                zones: zones.map(FrequentZoneUpsertDTO.init(from:))
            )
        )
        let response: APIResponse<[FrequentZoneDTO]> = try await network.request(endpoint)
        return response.data
    }

    func deleteZone(zoneId: UUID, userId: UUID) async throws {
        let endpoint = Endpoint(
            path: "/frequent-zones/\(zoneId.uuidString)",
            method: .delete,
            queryItems: [URLQueryItem(name: "userId", value: userId.uuidString)]
        )
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }
}
