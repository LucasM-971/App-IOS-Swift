import SwiftUI
import CoreLocation
import Combine
import UIKit
import MapKit

final class CurrentLocationAnnotationView: MKAnnotationView {
    private let outerCircle = UIView()
    private let innerCircle = UIView()
    private let arrowImageView = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func update(headingDegrees: CLLocationDirection) {
        let radians = CGFloat(headingDegrees * .pi / 180)
        arrowImageView.transform = CGAffineTransform(rotationAngle: radians)
    }

    private func configure() {
        guard subviews.isEmpty else { return }

        bounds = CGRect(x: 0, y: 0, width: 82, height: 82)
        centerOffset = .zero
        collisionMode = .circle
        displayPriority = .required

        outerCircle.frame = bounds
        outerCircle.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.30)
        outerCircle.layer.cornerRadius = 41
        outerCircle.layer.borderWidth = 1
        outerCircle.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        innerCircle.frame = CGRect(x: 8, y: 8, width: 66, height: 66)
        innerCircle.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.90)
        innerCircle.layer.cornerRadius = 33
        innerCircle.layer.borderWidth = 2
        innerCircle.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        innerCircle.layer.shadowColor = UIColor.black.cgColor
        innerCircle.layer.shadowOpacity = 0.24
        innerCircle.layer.shadowRadius = 8
        innerCircle.layer.shadowOffset = CGSize(width: 0, height: 3)

        arrowImageView.image = UIImage(
            systemName: "location.north.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 43, weight: .bold)
        )?.withRenderingMode(.alwaysTemplate)
        arrowImageView.tintColor = .white
        arrowImageView.contentMode = .scaleAspectFit
        arrowImageView.frame = CGRect(x: 17, y: 17, width: 48, height: 48)

        addSubview(outerCircle)
        addSubview(innerCircle)
        addSubview(arrowImageView)
    }
}
