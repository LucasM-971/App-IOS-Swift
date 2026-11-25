import SwiftUI
import CoreLocation
import Combine
import UIKit
import MapKit

final class WalkingRouteCalculation {
    struct Result {
        let displayPolyline: MKPolyline
        let distance: CLLocationDistance
        let expectedTravelTime: TimeInterval
        let usesPedestrianSnapPoint: Bool
    }

    private struct EndpointPair {
        let source: CLLocationCoordinate2D
        let destination: CLLocationCoordinate2D
        let usesPedestrianSnapPoint: Bool
    }

    private var activeDirections: MKDirections?
    private var isCancelled = false

    func cancel() {
        isCancelled = true
        activeDirections?.cancel()
        activeDirections = nil
    }

    func calculate(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        completion: @escaping (Result?) -> Void
    ) {
        let pairs = Self.endpointPairs(from: source, to: destination)
        calculateNextRoute(
            in: pairs,
            actualSource: source,
            actualDestination: destination,
            at: 0,
            completion: completion
        )
    }

    private func calculateNextRoute(
        in pairs: [EndpointPair],
        actualSource: CLLocationCoordinate2D,
        actualDestination: CLLocationCoordinate2D,
        at index: Int,
        completion: @escaping (Result?) -> Void
    ) {
        guard !isCancelled else { return }
        guard index < pairs.count else {
            completion(nil)
            return
        }

        let pair = pairs[index]
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: pair.source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: pair.destination))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let directions = MKDirections(request: request)
        activeDirections = directions

        directions.calculate { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self, !self.isCancelled else { return }
                self.activeDirections = nil

                if let route = response?.routes.first(where: { route in
                    route.transportType.contains(.walking)
                        && route.distance.isFinite
                        && route.distance > 0
                        && route.polyline.pointCount >= 2
                }),
                   route.distance.isFinite,
                   route.distance > 0,
                   route.polyline.pointCount >= 2 {
                    let sourceConnectorDistance = Self.distance(from: actualSource, to: pair.source)
                    let destinationConnectorDistance = Self.distance(
                        from: pair.destination,
                        to: actualDestination
                    )
                    let connectorDistance = sourceConnectorDistance + destinationConnectorDistance

                    completion(
                        Result(
                            displayPolyline: Self.displayPolyline(
                                actualSource: actualSource,
                                routePolyline: route.polyline,
                                actualDestination: actualDestination
                            ),
                            distance: route.distance + connectorDistance,
                            expectedTravelTime: route.expectedTravelTime
                                + connectorDistance / 80 * 60,
                            usesPedestrianSnapPoint: pair.usesPedestrianSnapPoint
                        )
                    )
                    return
                }

                self.calculateNextRoute(
                    in: pairs,
                    actualSource: actualSource,
                    actualDestination: actualDestination,
                    at: index + 1,
                    completion: completion
                )
            }
        }
    }

    private static func displayPolyline(
        actualSource: CLLocationCoordinate2D,
        routePolyline: MKPolyline,
        actualDestination: CLLocationCoordinate2D
    ) -> MKPolyline {
        var coordinates: [CLLocationCoordinate2D] = []
        append(actualSource, to: &coordinates)

        var routeCoordinates = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: routePolyline.pointCount
        )
        routePolyline.getCoordinates(
            &routeCoordinates,
            range: NSRange(location: 0, length: routePolyline.pointCount)
        )

        for coordinate in routeCoordinates {
            append(coordinate, to: &coordinates)
        }
        append(actualDestination, to: &coordinates)

        return MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    private static func append(
        _ coordinate: CLLocationCoordinate2D,
        to coordinates: inout [CLLocationCoordinate2D]
    ) {
        guard isValid(coordinate) else { return }
        if let last = coordinates.last,
           distance(from: last, to: coordinate) < 0.5 {
            return
        }
        coordinates.append(coordinate)
    }

    private static func distance(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: source.latitude, longitude: source.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
    }

    private static func endpointPairs(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> [EndpointPair] {
        let directBearing = bearing(from: source, to: destination)
        let bearings = uniqueBearings(
            [
                directBearing + 90,
                directBearing - 90,
                directBearing,
                directBearing + 180,
                90,
                270,
                0,
                180,
                45,
                135,
                225,
                315,
            ]
        )
        let snapRadii: [CLLocationDistance] = [18, 40, 72]
        let endpointOnlyRadii: [CLLocationDistance] = [18, 40]
        let endpointOnlyBearings = Array(bearings.prefix(4))

        var pairs: [EndpointPair] = []
        var seen = Set<String>()

        appendPair(
            source: source,
            destination: destination,
            usesPedestrianSnapPoint: false,
            to: &pairs,
            seen: &seen
        )

        for radius in snapRadii {
            for bearing in bearings {
                appendPair(
                    source: coordinate(source, offsetMeters: radius, bearingDegrees: bearing),
                    destination: coordinate(
                        destination,
                        offsetMeters: radius,
                        bearingDegrees: bearing
                    ),
                    usesPedestrianSnapPoint: true,
                    to: &pairs,
                    seen: &seen
                )
            }
        }

        for radius in endpointOnlyRadii {
            for bearing in endpointOnlyBearings {
                appendPair(
                    source: coordinate(source, offsetMeters: radius, bearingDegrees: bearing),
                    destination: destination,
                    usesPedestrianSnapPoint: true,
                    to: &pairs,
                    seen: &seen
                )
                appendPair(
                    source: source,
                    destination: coordinate(
                        destination,
                        offsetMeters: radius,
                        bearingDegrees: bearing
                    ),
                    usesPedestrianSnapPoint: true,
                    to: &pairs,
                    seen: &seen
                )
            }
        }

        return pairs
    }

    private static func appendPair(
        source: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        usesPedestrianSnapPoint: Bool,
        to pairs: inout [EndpointPair],
        seen: inout Set<String>
    ) {
        guard isValid(source), isValid(destination) else { return }
        let signature = [
            rounded(source.latitude),
            rounded(source.longitude),
            rounded(destination.latitude),
            rounded(destination.longitude),
        ].joined(separator: ":")
        guard seen.insert(signature).inserted else { return }
        pairs.append(
            EndpointPair(
                source: source,
                destination: destination,
                usesPedestrianSnapPoint: usesPedestrianSnapPoint
            )
        )
    }

    private static func coordinate(
        _ coordinate: CLLocationCoordinate2D,
        offsetMeters meters: CLLocationDistance,
        bearingDegrees: CLLocationDirection
    ) -> CLLocationCoordinate2D {
        let earthRadius: CLLocationDistance = 6_378_137
        let distanceRatio = meters / earthRadius
        let bearing = normalizeBearing(bearingDegrees) * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180

        let nextLatitude = asin(
            sin(latitude) * cos(distanceRatio)
                + cos(latitude) * sin(distanceRatio) * cos(bearing)
        )
        let nextLongitude = longitude + atan2(
            sin(bearing) * sin(distanceRatio) * cos(latitude),
            cos(distanceRatio) - sin(latitude) * sin(nextLatitude)
        )

        return CLLocationCoordinate2D(
            latitude: nextLatitude * 180 / .pi,
            longitude: normalizeLongitude(nextLongitude * 180 / .pi)
        )
    }

    private static func bearing(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let startLat = source.latitude * .pi / 180
        let startLon = source.longitude * .pi / 180
        let endLat = destination.latitude * .pi / 180
        let endLon = destination.longitude * .pi / 180
        let lonDelta = endLon - startLon
        let y = sin(lonDelta) * cos(endLat)
        let x = cos(startLat) * sin(endLat) - sin(startLat) * cos(endLat) * cos(lonDelta)
        return normalizeBearing(atan2(y, x) * 180 / .pi)
    }

    private static func uniqueBearings(_ values: [CLLocationDirection]) -> [CLLocationDirection] {
        var result: [CLLocationDirection] = []
        for value in values {
            let normalized = normalizeBearing(value)
            guard !result.contains(where: { angularDistance(from: $0, to: normalized) < 5 }) else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    private static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && abs(coordinate.latitude) <= 90
            && abs(coordinate.longitude) <= 180
    }

    private static func normalizeBearing(_ value: CLLocationDirection) -> CLLocationDirection {
        (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func angularDistance(
        from first: CLLocationDirection,
        to second: CLLocationDirection
    ) -> CLLocationDirection {
        let delta = abs(normalizeBearing(first) - normalizeBearing(second))
        return min(delta, 360 - delta)
    }

    private static func normalizeLongitude(_ value: CLLocationDegrees) -> CLLocationDegrees {
        (value + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private static func rounded(_ value: CLLocationDegrees) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

enum GuidanceRouteGuardrails {
    static let arrivalDistanceMeters: CLLocationDistance = 20
    static let maximumWalkingRouteDistanceMeters: CLLocationDistance = 50_000

    static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && abs(coordinate.latitude) <= 90
            && abs(coordinate.longitude) <= 180
    }

    static func straightLineDistance(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance? {
        guard isValid(start), isValid(end) else { return nil }
        return CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }
}
