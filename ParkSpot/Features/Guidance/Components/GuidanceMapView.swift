import SwiftUI
import CoreLocation
import Combine
import UIKit
import MapKit

struct GuidanceMapView: UIViewRepresentable {
    private enum Camera3D {
        static let pitch: CGFloat = 58
        static let userDistance: CLLocationDistance = 430
        static let carOnlyDistance: CLLocationDistance = 430
        static let routeDistanceMultiplier = 3.6
        static let minCenterDistance: CLLocationDistance = 35
        static let maxCenterDistance: CLLocationDistance = 50_000
        static let distanceTolerance: CLLocationDistance = 45
        static let followMovementThreshold: CLLocationDistance = 7
        static let followHeadingThreshold: CLLocationDirection = 8
    }

    let carCoordinate: Coordinate
    let userLocation: CLLocation?
    let userHeading: CLHeading?
    let colorScheme: ColorScheme
    @Binding var isMapCameraLocked: Bool
    let recenterRequest: Int
    @Binding var walkingRouteDistanceMeters: Double?
    @Binding var walkingRouteExpectedTravelTime: TimeInterval?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        applyMapAppearance(on: mapView)
        mapView.showsUserLocation = true
        mapView.showsBuildings = true
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.userTrackingMode = .none
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: Camera3D.minCenterDistance,
            maxCenterCoordinateDistance: Camera3D.maxCenterDistance
        )
        context.coordinator.installInteractionTracking(on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        applyMapAppearance(on: mapView)
        context.coordinator.installInteractionTracking(on: mapView)
        context.coordinator.sync(
            mapView: mapView,
            carCoordinate: carCoordinate,
            userLocation: userLocation,
            userHeading: userHeading,
            colorScheme: colorScheme,
            recenterRequest: recenterRequest,
            walkingRouteDistanceMeters: $walkingRouteDistanceMeters,
            walkingRouteExpectedTravelTime: $walkingRouteExpectedTravelTime
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isMapCameraLocked: $isMapCameraLocked,
            initialRecenterRequest: recenterRequest
        )
    }

    private func applyMapAppearance(on mapView: MKMapView) {
        mapView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        mapView.tintColor = .systemBlue
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.showsBuildings = true

        if #available(iOS 16.0, *) {
            let configuration = MKStandardMapConfiguration(
                elevationStyle: .realistic,
                emphasisStyle: .default
            )
            configuration.pointOfInterestFilter = .excludingAll
            configuration.showsTraffic = false
            mapView.preferredConfiguration = configuration
        } else {
            mapView.mapType = .standard
            mapView.pointOfInterestFilter = .excludingAll
            mapView.showsTraffic = false
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var carAnnotation: MKPointAnnotation?
        private var routeOverlay: MKPolyline?
        private var routeOverlayIsWalkingRoute = false
        private var activeRouteCalculation: WalkingRouteCalculation?
        private var pendingRouteSignature: String?
        private var renderedRouteSignature: String?
        private var failedRouteSignature: String?
        private var failedRouteAt: Date?
        private var nonWalkableRouteSignature: String?
        private var lastRouteRequestAt: Date?
        private var lastRouteRequestUserCoordinate: CLLocationCoordinate2D?
        private var latestCarCoordinate: CLLocationCoordinate2D?
        private var latestUserLocation: CLLocation?
        private var latestUserHeading: CLHeading?
        private var latestWalkingRouteDistanceMeters: Binding<Double?>?
        private var latestWalkingRouteExpectedTravelTime: Binding<TimeInterval?>?
        private let failedRouteRetryInterval: TimeInterval = 8
        private let minimumRouteRefreshInterval: TimeInterval = 30
        private let minimumRouteRefreshDistanceMeters: CLLocationDistance = 35
        private var lastCameraUserCoordinate: CLLocationCoordinate2D?
        private var lastCameraHeadingDegrees: CLLocationDirection?
        private var lastRecenterRequest: Int
        private var isMapCameraLocked: Binding<Bool>
        private var trackedGestureIDs = Set<ObjectIdentifier>()
        private var currentColorScheme: ColorScheme = .dark
        private var isApplyingForced3DPitch = false
        private var userDetachedCamera = false

        init(isMapCameraLocked: Binding<Bool>, initialRecenterRequest: Int) {
            self.isMapCameraLocked = isMapCameraLocked
            lastRecenterRequest = initialRecenterRequest
        }

        func installInteractionTracking(on mapView: MKMapView) {
            installGestureTracking(in: mapView)
        }

        private func installGestureTracking(in view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] {
                let id = ObjectIdentifier(recognizer)
                guard !trackedGestureIDs.contains(id) else { continue }
                recognizer.addTarget(self, action: #selector(mapGestureDidChange(_:)))
                trackedGestureIDs.insert(id)
            }

            for subview in view.subviews {
                installGestureTracking(in: subview)
            }
        }

        @objc private func mapGestureDidChange(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            detachCameraFromUserTracking()
        }

        private func detachCameraFromUserTracking() {
            userDetachedCamera = true
            isMapCameraLocked.wrappedValue = false
        }

        func sync(
            mapView: MKMapView,
            carCoordinate: Coordinate,
            userLocation: CLLocation?,
            userHeading: CLHeading?,
            colorScheme: ColorScheme,
            recenterRequest: Int,
            walkingRouteDistanceMeters: Binding<Double?>,
            walkingRouteExpectedTravelTime: Binding<TimeInterval?>
        ) {
            currentColorScheme = colorScheme
            let car = CLLocationCoordinate2D(
                latitude: carCoordinate.latitude,
                longitude: carCoordinate.longitude
            )

            if carAnnotation == nil {
                let annotation = MKPointAnnotation()
                annotation.title = "You parked near here".psLocalized
                annotation.coordinate = car
                carAnnotation = annotation
                mapView.addAnnotation(annotation)
            } else {
                carAnnotation?.coordinate = car
            }

            let resolvedUserLocation = userLocation ?? mapView.userLocation.location
            latestCarCoordinate = car
            latestUserLocation = resolvedUserLocation
            latestUserHeading = userHeading
            latestWalkingRouteDistanceMeters = walkingRouteDistanceMeters
            latestWalkingRouteExpectedTravelTime = walkingRouteExpectedTravelTime
            updateParkedCarAnnotationStyle(on: mapView)

            updateUserAnnotation(on: mapView, location: resolvedUserLocation, heading: userHeading)
            syncUserCamera(
                on: mapView,
                userLocation: resolvedUserLocation,
                car: car,
                recenterRequest: recenterRequest
            )
            syncRoute(
                mapView: mapView,
                car: car,
                userLocation: resolvedUserLocation,
                walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
            )
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            installInteractionTracking(on: mapView)

            if hasActiveUserGesture(in: mapView) {
                detachCameraFromUserTracking()
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            installInteractionTracking(on: mapView)

            if hasActiveUserGesture(in: mapView) {
                detachCameraFromUserTracking()
            }

            if isMapCameraLocked.wrappedValue, !userDetachedCamera {
                enforce3DPitchIfNeeded(on: mapView)
            }
            updateUserAnnotation(
                on: mapView,
                location: latestUserLocation ?? mapView.userLocation.location,
                heading: latestUserHeading
            )
        }

        private func hasActiveUserGesture(in view: UIView) -> Bool {
            if (view.gestureRecognizers ?? []).contains(where: { recognizer in
                recognizer.state == .began || recognizer.state == .changed
            }) {
                return true
            }

            return view.subviews.contains { hasActiveUserGesture(in: $0) }
        }

        private func syncRoute(
            mapView: MKMapView,
            car: CLLocationCoordinate2D,
            userLocation: CLLocation?,
            walkingRouteDistanceMeters: Binding<Double?>,
            walkingRouteExpectedTravelTime: Binding<TimeInterval?>
        ) {
            let signature = routeSignature(car: car, user: userLocation?.coordinate)

            guard let user = userLocation?.coordinate,
                  GuidanceRouteGuardrails.isValid(user),
                  GuidanceRouteGuardrails.isValid(car) else {
                activeRouteCalculation?.cancel()
                activeRouteCalculation = nil
                pendingRouteSignature = nil
                renderedRouteSignature = nil
                nonWalkableRouteSignature = nil
                lastRouteRequestAt = nil
                lastRouteRequestUserCoordinate = nil
                removeRouteOverlay(from: mapView)
                setWalkingRouteMetrics(
                    distance: nil,
                    expectedTravelTime: nil,
                    walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                    walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
                )
                if isMapCameraLocked.wrappedValue,
                   GuidanceRouteGuardrails.isValid(car),
                   routeOverlay == nil {
                    setCarOnlyRegion(on: mapView, car: car, animated: true)
                }
                return
            }

            guard let directDistance = GuidanceRouteGuardrails.straightLineDistance(
                from: user,
                to: car
            ) else { return }

            nonWalkableRouteSignature = nil

            if directDistance <= GuidanceRouteGuardrails.arrivalDistanceMeters {
                activeRouteCalculation?.cancel()
                activeRouteCalculation = nil
                pendingRouteSignature = nil
                renderedRouteSignature = nil
                failedRouteSignature = nil
                failedRouteAt = nil
                lastRouteRequestAt = nil
                lastRouteRequestUserCoordinate = nil
                removeRouteOverlay(from: mapView)
                setWalkingRouteMetrics(
                    distance: directDistance,
                    expectedTravelTime: nil,
                    walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                    walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
                )
                syncUserCamera(
                    on: mapView,
                    userLocation: userLocation,
                    car: car,
                    recenterRequest: lastRecenterRequest
                )
                return
            }

            if routeOverlay == nil {
                let fallbackPolyline = directRouteOverlay(from: user, to: car)
                replaceRouteOverlay(fallbackPolyline, isWalkingRoute: false, on: mapView)
                syncUserCamera(
                    on: mapView,
                    userLocation: userLocation,
                    car: car,
                    recenterRequest: lastRecenterRequest
                )
                setWalkingRouteMetrics(
                    distance: directDistance,
                    expectedTravelTime: nil,
                    walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                    walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
                )
            }

            let recentlyFailed =
                signature == failedRouteSignature
                && failedRouteAt.map { Date().timeIntervalSince($0) < failedRouteRetryInterval }
                    == true
            guard signature != pendingRouteSignature,
                  signature != renderedRouteSignature,
                  !recentlyFailed,
                  shouldRefreshRoute(from: user, signature: signature) else { return }

            lastRouteRequestAt = Date()
            lastRouteRequestUserCoordinate = user
            requestWalkingRoute(
                from: user,
                to: car,
                signature: signature,
                mapView: mapView,
                walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
            )
        }

        private func shouldRefreshRoute(
            from user: CLLocationCoordinate2D,
            signature: String
        ) -> Bool {
            if routeOverlay == nil
                || (renderedRouteSignature == nil && lastRouteRequestAt == nil)
            {
                return true
            }

            if signature == renderedRouteSignature {
                return false
            }

            let now = Date()
            let enoughTime = lastRouteRequestAt.map {
                now.timeIntervalSince($0) >= minimumRouteRefreshInterval
            } ?? true
            let enoughDistance = lastRouteRequestUserCoordinate.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: user.latitude, longitude: user.longitude))
                    >= minimumRouteRefreshDistanceMeters
            } ?? true

            return enoughTime || enoughDistance
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = routeOverlayIsWalkingRoute
                ? UIColor.systemBlue.withAlphaComponent(0.96)
                : UIColor.systemBlue.withAlphaComponent(0.82)
            renderer.lineWidth = routeOverlayIsWalkingRoute ? 8 : 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if !routeOverlayIsWalkingRoute {
                renderer.lineDashPattern = [10, 7]
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let car = latestCarCoordinate,
                  let walkingRouteDistanceMeters = latestWalkingRouteDistanceMeters,
                  let walkingRouteExpectedTravelTime = latestWalkingRouteExpectedTravelTime else {
                return
            }

            latestUserLocation = userLocation.location
            updateUserAnnotation(on: mapView, location: userLocation.location, heading: latestUserHeading)
            syncUserCamera(
                on: mapView,
                userLocation: userLocation.location,
                car: car,
                recenterRequest: lastRecenterRequest
            )
            syncRoute(
                mapView: mapView,
                car: car,
                userLocation: userLocation.location,
                walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
            )
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let identifier = "current-location"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? CurrentLocationAnnotationView
                    ?? CurrentLocationAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                return view
            }

            let identifier = "parked-car"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? ParkedCarAnnotationView
                ?? ParkedCarAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.update(colorScheme: currentColorScheme)
            return view
        }

        private func updateParkedCarAnnotationStyle(on mapView: MKMapView) {
            guard let carAnnotation,
                  let view = mapView.view(for: carAnnotation) as? ParkedCarAnnotationView else {
                return
            }

            view.update(colorScheme: currentColorScheme)
        }

        private func requestWalkingRoute(
            from user: CLLocationCoordinate2D,
            to car: CLLocationCoordinate2D,
            signature: String,
            mapView: MKMapView,
            walkingRouteDistanceMeters: Binding<Double?>,
            walkingRouteExpectedTravelTime: Binding<TimeInterval?>
        ) {
            activeRouteCalculation?.cancel()
            pendingRouteSignature = signature
            failedRouteSignature = nil
            failedRouteAt = nil

            let hadWalkingRoute = routeOverlayIsWalkingRoute
            if routeOverlay == nil {
                let fallbackPolyline = directRouteOverlay(from: user, to: car)
                replaceRouteOverlay(fallbackPolyline, isWalkingRoute: false, on: mapView)
            }
            let directDistance = CLLocation(
                latitude: user.latitude,
                longitude: user.longitude
            ).distance(from: CLLocation(latitude: car.latitude, longitude: car.longitude))
            guard directDistance > GuidanceRouteGuardrails.arrivalDistanceMeters else {
                pendingRouteSignature = nil
                renderedRouteSignature = nil
                removeRouteOverlay(from: mapView)
                setWalkingRouteMetrics(
                    distance: directDistance,
                    expectedTravelTime: nil,
                    walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                    walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
                )
                return
            }

            setWalkingRouteMetrics(
                distance: routeOverlayIsWalkingRoute
                    ? walkingRouteDistanceMeters.wrappedValue
                    : directDistance,
                expectedTravelTime: routeOverlayIsWalkingRoute
                    ? walkingRouteExpectedTravelTime.wrappedValue
                    : nil,
                walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
            )

            let calculation = WalkingRouteCalculation()
            activeRouteCalculation = calculation

            calculation.calculate(from: user, to: car) { [weak self, weak mapView] result in
                guard let self,
                      let mapView,
                      self.pendingRouteSignature == signature else {
                    return
                }
                self.pendingRouteSignature = nil
                self.activeRouteCalculation = nil

                guard let result else {
                    self.failedRouteSignature = signature
                    self.failedRouteAt = Date()
                    let directDistance = CLLocation(
                        latitude: user.latitude,
                        longitude: user.longitude
                    ).distance(from: CLLocation(latitude: car.latitude, longitude: car.longitude))
                    if !hadWalkingRoute {
                        self.replaceRouteOverlay(
                            self.directRouteOverlay(from: user, to: car),
                            isWalkingRoute: false,
                            on: mapView
                        )
                    }
                    self.setWalkingRouteMetrics(
                        distance: hadWalkingRoute
                            ? walkingRouteDistanceMeters.wrappedValue
                            : directDistance,
                        expectedTravelTime: hadWalkingRoute
                            ? walkingRouteExpectedTravelTime.wrappedValue
                            : nil,
                        walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                        walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
                    )
                    return
                }

                self.replaceRouteOverlay(result.displayPolyline, isWalkingRoute: true, on: mapView)
                self.renderedRouteSignature = signature
                self.failedRouteSignature = nil
                self.failedRouteAt = nil
                self.setWalkingRouteMetrics(
                    distance: result.distance,
                    expectedTravelTime: result.expectedTravelTime,
                    walkingRouteDistanceMeters: walkingRouteDistanceMeters,
                    walkingRouteExpectedTravelTime: walkingRouteExpectedTravelTime
                )
            }
        }

        private func setWalkingRouteMetrics(
            distance: Double?,
            expectedTravelTime: TimeInterval?,
            walkingRouteDistanceMeters: Binding<Double?>,
            walkingRouteExpectedTravelTime: Binding<TimeInterval?>
        ) {
            DispatchQueue.main.async {
                if !Self.metric(walkingRouteDistanceMeters.wrappedValue, equals: distance) {
                    walkingRouteDistanceMeters.wrappedValue = distance
                }
                if !Self.metric(walkingRouteExpectedTravelTime.wrappedValue, equals: expectedTravelTime) {
                    walkingRouteExpectedTravelTime.wrappedValue = expectedTravelTime
                }
            }
        }

        private static func metric(_ lhs: Double?, equals rhs: Double?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                return abs(lhs - rhs) < 0.5
            default:
                return false
            }
        }

        private func replaceRouteOverlay(
            _ polyline: MKPolyline,
            isWalkingRoute: Bool,
            on mapView: MKMapView
        ) {
            removeRouteOverlay(from: mapView)
            routeOverlay = polyline
            routeOverlayIsWalkingRoute = isWalkingRoute
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        private func removeRouteOverlay(from mapView: MKMapView) {
            if let routeOverlay {
                mapView.removeOverlay(routeOverlay)
                self.routeOverlay = nil
                routeOverlayIsWalkingRoute = false
            }
        }

        private func directRouteOverlay(
            from user: CLLocationCoordinate2D,
            to car: CLLocationCoordinate2D
        ) -> MKPolyline {
            let coordinates = [user, car]
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }

        private func syncUserCamera(
            on mapView: MKMapView,
            userLocation: CLLocation?,
            car: CLLocationCoordinate2D,
            recenterRequest: Int
        ) {
            let didRequestRecenter = recenterRequest != lastRecenterRequest
            if didRequestRecenter {
                userDetachedCamera = false
                isMapCameraLocked.wrappedValue = true
            }

            guard isMapCameraLocked.wrappedValue, !userDetachedCamera else {
                lastRecenterRequest = recenterRequest
                return
            }

            guard let user = userLocation?.coordinate,
                  GuidanceRouteGuardrails.isValid(user),
                  GuidanceRouteGuardrails.isValid(car) else {
                if GuidanceRouteGuardrails.isValid(car),
                   lastCameraUserCoordinate == nil || didRequestRecenter {
                    setCarOnlyRegion(on: mapView, car: car, animated: true)
                }
                lastRecenterRequest = recenterRequest
                return
            }

            let movedDistance = lastCameraUserCoordinate.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: user.latitude, longitude: user.longitude))
            } ?? .infinity
            let needsCameraUpdate = didRequestRecenter
                || movedDistance >= Camera3D.followMovementThreshold
                || headingDelta(
                    from: lastCameraHeadingDegrees,
                    to: resolvedCameraHeading(for: userLocation, user: user, car: car)
                ) >= Camera3D.followHeadingThreshold
                || abs(mapView.camera.pitch - Camera3D.pitch) >= 1
                || abs(mapView.camera.centerCoordinateDistance - Camera3D.userDistance) >= Camera3D.distanceTolerance
                || mapView.camera.centerCoordinateDistance > Camera3D.maxCenterDistance

            guard needsCameraUpdate else {
                lastRecenterRequest = recenterRequest
                return
            }

            lastRecenterRequest = recenterRequest
            lastCameraUserCoordinate = user
            let cameraHeading = resolvedCameraHeading(for: userLocation, user: user, car: car)
            lastCameraHeadingDegrees = cameraHeading

            let camera = MKMapCamera(
                lookingAtCenter: user,
                fromDistance: Camera3D.userDistance,
                pitch: Camera3D.pitch,
                heading: cameraHeading
            )
            mapView.setCamera(
                camera,
                animated: didRequestRecenter || movedDistance >= Camera3D.followMovementThreshold
            )
            updateUserAnnotation(on: mapView, location: userLocation, heading: latestUserHeading)
        }

        private func focusMap(
            on user: CLLocationCoordinate2D,
            and car: CLLocationCoordinate2D,
            in mapView: MKMapView
        ) {
            let userPoint = MKMapPoint(user)
            let carPoint = MKMapPoint(car)
            let rect = MKMapRect(
                x: min(userPoint.x, carPoint.x),
                y: min(userPoint.y, carPoint.y),
                width: max(abs(userPoint.x - carPoint.x), 1),
                height: max(abs(userPoint.y - carPoint.y), 1)
            )

            mapView.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 170, left: 46, bottom: 210, right: 46),
                animated: true
            )
        }

        private func focusRoute(
            _ polyline: MKPolyline,
            user: CLLocationCoordinate2D,
            car: CLLocationCoordinate2D,
            in mapView: MKMapView,
            animated: Bool
        ) {
            mapView.setVisibleMapRect(
                polyline.boundingMapRect,
                edgePadding: routeInsets,
                animated: animated
            )

            let userLocation = CLLocation(latitude: user.latitude, longitude: user.longitude)
            let carLocation = CLLocation(latitude: car.latitude, longitude: car.longitude)
            let routeDistance = max(userLocation.distance(from: carLocation), 40)
            let camera = MKMapCamera(
                lookingAtCenter: centerCoordinate(between: user, and: car),
                fromDistance: max(routeDistance * Camera3D.routeDistanceMultiplier, Camera3D.userDistance),
                pitch: Camera3D.pitch,
                heading: bearing(from: user, to: car)
            )
            mapView.setCamera(camera, animated: animated)
        }

        private func setCarOnlyRegion(
            on mapView: MKMapView,
            car: CLLocationCoordinate2D,
            animated: Bool
        ) {
            let camera = MKMapCamera(
                lookingAtCenter: car,
                fromDistance: Camera3D.carOnlyDistance,
                pitch: Camera3D.pitch,
                heading: mapView.camera.heading
            )
            mapView.setCamera(camera, animated: animated)
        }

        private func enforce3DPitchIfNeeded(on mapView: MKMapView) {
            if isApplyingForced3DPitch {
                isApplyingForced3DPitch = false
                return
            }

            mapView.isPitchEnabled = true
            mapView.isRotateEnabled = true

            guard abs(mapView.camera.pitch - Camera3D.pitch) >= 1 else { return }

            isApplyingForced3DPitch = true
            let camera = MKMapCamera(
                lookingAtCenter: mapView.centerCoordinate,
                fromDistance: min(
                    max(mapView.camera.centerCoordinateDistance, Camera3D.minCenterDistance),
                    Camera3D.maxCenterDistance
                ),
                pitch: Camera3D.pitch,
                heading: mapView.camera.heading
            )
            mapView.setCamera(camera, animated: true)
        }

        private var routeInsets: UIEdgeInsets {
            UIEdgeInsets(top: 170, left: 46, bottom: 230, right: 46)
        }

        private func updateUserAnnotation(
            on mapView: MKMapView,
            location: CLLocation?,
            heading: CLHeading?
        ) {
            guard let view = mapView.view(for: mapView.userLocation) as? CurrentLocationAnnotationView else {
                return
            }

            if let headingValue = resolvedHeadingDegrees(from: heading) {
                view.update(headingDegrees: screenHeadingDegrees(for: headingValue, on: mapView))
                return
            }

            let course = location?.course ?? -1
            if course >= 0, course.isFinite {
                view.update(headingDegrees: screenHeadingDegrees(for: course, on: mapView))
                return
            }

            view.update(headingDegrees: 0)
        }

        private func screenHeadingDegrees(
            for absoluteHeading: CLLocationDirection,
            on mapView: MKMapView
        ) -> CLLocationDirection {
            (absoluteHeading - mapView.camera.heading + 360)
                .truncatingRemainder(dividingBy: 360)
        }

        private func resolvedHeadingDegrees(from heading: CLHeading?) -> CLLocationDirection? {
            guard let heading, heading.headingAccuracy >= 0 else { return nil }
            let value = heading.trueHeading >= 0
                ? heading.trueHeading
                : heading.magneticHeading
            return value.isFinite ? value : nil
        }

        private func resolvedCameraHeading(
            for location: CLLocation?,
            user: CLLocationCoordinate2D,
            car: CLLocationCoordinate2D
        ) -> CLLocationDirection {
            if let headingValue = resolvedHeadingDegrees(from: latestUserHeading) {
                return headingValue
            }

            let course = location?.course ?? -1
            if course >= 0, course.isFinite {
                return course
            }

            return bearing(from: user, to: car)
        }

        private func headingDelta(
            from previous: CLLocationDirection?,
            to next: CLLocationDirection
        ) -> CLLocationDirection {
            guard let previous else { return .infinity }
            let delta = abs(normalizeHeading(next) - normalizeHeading(previous))
            return min(delta, 360 - delta)
        }

        private func normalizeHeading(_ value: CLLocationDirection) -> CLLocationDirection {
            (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }

        private func centerCoordinate(
            between first: CLLocationCoordinate2D,
            and second: CLLocationCoordinate2D
        ) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: (first.latitude + second.latitude) / 2,
                longitude: (first.longitude + second.longitude) / 2
            )
        }

        private func bearing(
            from start: CLLocationCoordinate2D,
            to end: CLLocationCoordinate2D
        ) -> CLLocationDirection {
            let startLat = start.latitude * .pi / 180
            let startLon = start.longitude * .pi / 180
            let endLat = end.latitude * .pi / 180
            let endLon = end.longitude * .pi / 180
            let longitudeDelta = endLon - startLon

            let y = sin(longitudeDelta) * cos(endLat)
            let x = cos(startLat) * sin(endLat) - sin(startLat) * cos(endLat) * cos(longitudeDelta)
            let degrees = atan2(y, x) * 180 / .pi
            return (degrees + 360).truncatingRemainder(dividingBy: 360)
        }

        private func routeSignature(car: CLLocationCoordinate2D, user: CLLocationCoordinate2D?) -> String {
            guard let user else {
                return "car:\(rounded(car.latitude)):\(rounded(car.longitude))"
            }

            return [
                rounded(user.latitude),
                rounded(user.longitude),
                rounded(car.latitude),
                rounded(car.longitude)
            ].joined(separator: ":")
        }

        private func rounded(_ value: CLLocationDegrees) -> String {
            String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }
}
