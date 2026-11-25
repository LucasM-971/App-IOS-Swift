import XCTest
@testable import ParkSpot

final class MockNetwork: NetworkRequesting {
    var responses: [String: Any] = [:]
    var errors: [String: Error] = [:]
    var delays: [String: UInt64] = [:]
    var requestedPaths: [String] = []

    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        requestedPaths.append(endpoint.path)
        if let delay = delays[endpoint.path] {
            try await Task.sleep(nanoseconds: delay)
        }
        if let error = errors[endpoint.path] { throw error }
        guard let response = responses[endpoint.path] as? T else {
            throw APIError.requestFailed(500, "Mock response missing for \(endpoint.path)")
        }
        return response
    }
}
