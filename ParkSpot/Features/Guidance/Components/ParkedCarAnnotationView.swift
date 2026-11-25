import SwiftUI
import CoreLocation
import Combine
import UIKit
import MapKit

final class ParkedCarAnnotationView: MKAnnotationView {
    private let pinImageView = UIImageView()
    private let titleLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func update(colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        titleLabel.textColor = isDark
            ? .white
            : UIColor(red: 0.08, green: 0.10, blue: 0.13, alpha: 1)
        titleLabel.layer.shadowColor = isDark
            ? UIColor.black.cgColor
            : UIColor.white.cgColor
        titleLabel.layer.shadowOpacity = isDark ? 0.80 : 0.94
        pinImageView.layer.shadowOpacity = isDark ? 0.34 : 0.22
    }

    private func configure() {
        guard subviews.isEmpty else { return }

        bounds = CGRect(x: 0, y: 0, width: 188, height: 78)
        centerOffset = CGPoint(x: 72, y: -23)
        canShowCallout = false
        collisionMode = .rectangle
        displayPriority = .required

        pinImageView.image = UIImage(
            systemName: "mappin.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 47, weight: .bold)
        )?.withRenderingMode(.alwaysTemplate)
        pinImageView.tintColor = .systemRed
        pinImageView.contentMode = .scaleAspectFit
        pinImageView.frame = CGRect(x: 0, y: 4, width: 54, height: 60)
        pinImageView.layer.shadowColor = UIColor.black.cgColor
        pinImageView.layer.shadowOpacity = 0.34
        pinImageView.layer.shadowRadius = 3
        pinImageView.layer.shadowOffset = CGSize(width: 0, height: 2)

        titleLabel.text = "You parked near\nhere".psLocalized
        titleLabel.numberOfLines = 2
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.72
        titleLabel.layer.shadowColor = UIColor.black.cgColor
        titleLabel.layer.shadowOpacity = 0.80
        titleLabel.layer.shadowRadius = 2
        titleLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
        titleLabel.frame = CGRect(x: 52, y: 10, width: 132, height: 56)

        addSubview(pinImageView)
        addSubview(titleLabel)
    }
}
