// RemoteParkingDataSource.swift
// Handles all parking-related API requests

import Foundation

final class RemoteParkingDataSource {

    private let network: NetworkRequesting

    init(network: NetworkRequesting) {
        self.network = network
    }

    func create(_ session: ParkingSession) async throws -> ParkingSessionDTO {
        let endpoint = Endpoint(
            path: "/parking",
            method: .post,
            body: CreateParkingRequestDTO(from: session)
        )
        let response: APIResponse<ParkingSessionDTO> = try await network.request(endpoint)
        return response.data
    }

    func fetchActive(userId: UUID) async throws -> ParkingSessionDTO? {
        let endpoint = Endpoint(
            path: "/parking/active",
            method: .get,
            queryItems: [URLQueryItem(name: "userId", value: userId.uuidString)]
        )
        let response: APIResponse<ParkingSessionDTO?> = try await network.request(endpoint)
        return response.data
    }

    func fetchHistory(userId: UUID, limit: Int, offset: Int) async throws -> [ParkingSessionDTO] {
        let endpoint = Endpoint(
            path: "/parking/history",
            method: .get,
            queryItems: [
                URLQueryItem(name: "userId", value: userId.uuidString),
                URLQueryItem(name: "limit",  value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
        )
        let response: APIResponse<[ParkingSessionDTO]> = try await network.request(endpoint)
        return response.data
    }

    func endSession(id: UUID) async throws -> ParkingSessionDTO {
        let endpoint = Endpoint(path: "/parking/\(id.uuidString)/end", method: .patch)
        let response: APIResponse<ParkingSessionDTO> = try await network.request(endpoint)
        return response.data
    }

    func delete(id: UUID) async throws {
        let endpoint = Endpoint(path: "/parking/\(id.uuidString)", method: .delete)
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }

    func deleteAllUserData(userId: UUID) async throws {
        let endpoint = Endpoint(path: "/users/\(userId.uuidString)/data", method: .delete)
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }

    func deleteHistoryOlderThan(userId: UUID, cutoff: Date) async throws {
        struct RetentionBody: Encodable {
            let userId: String
            let before: Date
        }

        let endpoint = Endpoint(
            path: "/parking/history/purge",
            method: .post,
            body: RetentionBody(userId: userId.uuidString, before: cutoff)
        )
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }
}

struct EmptyResponse: Decodable {}

final class RemoteParkingHistoryBackupDataSource {
    private let network: NetworkRequesting

    init(network: NetworkRequesting) {
        self.network = network
    }

    func upsert(events: [ParkingHistoryEvent]) async throws {
        guard !events.isEmpty else { return }

        struct UpsertBody: Encodable {
            let events: [HistoryEventUpsertDTO]
        }

        let endpoint = Endpoint(
            path: "/history/events/upsert",
            method: .post,
            body: UpsertBody(events: events.map { HistoryEventUpsertDTO(from: $0) })
        )
        let _: APIResponse<[HistoryEventUpsertDTO]> = try await network.request(endpoint)
    }

    func deleteEvents(userId: UUID, recordIDs: [String]) async throws {
        guard !recordIDs.isEmpty else { return }

        struct DeleteBody: Encodable {
            let userId: String
            let ids: [String]
        }

        let endpoint = Endpoint(
            path: "/history/events/delete",
            method: .post,
            body: DeleteBody(userId: userId.uuidString, ids: recordIDs)
        )
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }

    func deleteAllBackups(userId: UUID) async throws {
        let endpoint = Endpoint(
            path: "/history/events/user/\(userId.uuidString)",
            method: .delete
        )
        let _: APIResponse<EmptyResponse> = try await network.request(endpoint)
    }
}
