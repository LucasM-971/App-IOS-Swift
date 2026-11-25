import XCTest
@testable import ParkSpot

func makeSamples(
    from anchor: Coordinate,
    startDate: Date,
    offsetsMeters: [Double],
    interval: TimeInterval,
    speed: Double,
    accuracy: Double
) -> [LocationSample] {
    offsetsMeters.enumerated().map { index, offset in
        makeSample(
            at: coordinate(from: anchor, northMeters: offset),
            secondsFrom: startDate,
            offset: interval * Double(index),
            speed: speed,
            accuracy: accuracy
        )
    }
}

func makeSample(
    at coordinate: Coordinate,
    secondsFrom startDate: Date,
    offset: TimeInterval,
    speed: Double,
    accuracy: Double
) -> LocationSample {
    LocationSample(
        coordinate: coordinate,
        accuracy: accuracy,
        date: startDate.addingTimeInterval(offset),
        speed: speed,
        course: nil
    )
}

func coordinate(
    from anchor: Coordinate,
    northMeters: Double = 0,
    southMeters: Double = 0,
    eastMeters: Double = 0,
    westMeters: Double = 0
) -> Coordinate {
    let latitudeDelta = (northMeters - southMeters) / 111_320.0
    let longitudeScale = max(0.2, cos(anchor.latitude * .pi / 180))
    let longitudeDelta = (eastMeters - westMeters) / (111_320.0 * longitudeScale)

    return Coordinate(
        latitude: anchor.latitude + latitudeDelta,
        longitude: anchor.longitude + longitudeDelta
    )
}
