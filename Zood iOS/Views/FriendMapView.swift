import MapKit
import SwiftUI

/// What the map should do next. Bumping `id` re-runs the command even if it's the same kind.
struct MapCommand: Equatable {
    enum Kind: Equatable {
        case followUser
        case focus(latitude: Double, longitude: Double)
    }
    var kind: Kind
    var id = UUID()
}

/// MKMapView wrapper (SwiftUI's annotation-builder `Map` needs iOS 17; this app supports iOS 15).
struct FriendMapView: UIViewRepresentable {
    let friends: [Friend]
    let command: MapCommand?
    let onSelect: (Data) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.register(FriendAnnotationView.self, forAnnotationViewWithReuseIdentifier: FriendAnnotationView.reuseID)
        map.setUserTrackingMode(.follow, animated: false)
        // Keep the Apple Maps logo and Legal link clear of the friend bar overlay.
        map.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 110, right: 8)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.sync(friends: friends, on: map)
        if let command, command != context.coordinator.lastCommand {
            context.coordinator.lastCommand = command
            switch command.kind {
            case .followUser:
                map.setUserTrackingMode(.follow, animated: true)
            case .focus(let lat, let lng):
                // Offset south a little so the pin isn't hidden behind the friend sheet.
                let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat - 0.002, longitude: lng),
                                                latitudinalMeters: 1500, longitudinalMeters: 1500)
                map.setRegion(region, animated: true)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelect: (Data) -> Void
        var lastCommand: MapCommand?
        private var annotations: [Data: FriendAnnotation] = [:]
        private var circles: [Data: MKCircle] = [:]

        init(onSelect: @escaping (Data) -> Void) { self.onSelect = onSelect }

        func sync(friends: [Friend], on map: MKMapView) {
            let located = friends.filter { $0.location != nil }
            let ids = Set(located.map(\.id))

            for (id, annotation) in annotations where !ids.contains(id) {
                map.removeAnnotation(annotation)
                annotations[id] = nil
            }
            for (id, circle) in circles where !ids.contains(id) {
                map.removeOverlay(circle)
                circles[id] = nil
            }

            for friend in located {
                guard let loc = friend.location else { continue }
                let coordinate = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
                if let existing = annotations[friend.id] {
                    existing.coordinate = coordinate
                    if existing.friend != friend {
                        existing.friend = friend
                        (map.view(for: existing) as? FriendAnnotationView)?.configure(with: friend)
                    }
                } else {
                    let annotation = FriendAnnotation(friend: friend, coordinate: coordinate)
                    annotations[friend.id] = annotation
                    map.addAnnotation(annotation)
                }

                // Accuracy circle, only when it's big enough to mean something.
                if let old = circles[friend.id] {
                    map.removeOverlay(old)
                    circles[friend.id] = nil
                }
                if let accuracy = loc.accuracy, accuracy > 30 {
                    let circle = MKCircle(center: coordinate, radius: accuracy)
                    circles[friend.id] = circle
                    map.addOverlay(circle)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? FriendAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: FriendAnnotationView.reuseID, for: annotation)
            (view as? FriendAnnotationView)?.configure(with: annotation.friend)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? FriendAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            onSelect(annotation.friend.id)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor(Color.zoodBlue).withAlphaComponent(0.15)
            renderer.strokeColor = UIColor(Color.zoodBlue).withAlphaComponent(0.5)
            renderer.lineWidth = 1
            return renderer
        }
    }
}

final class FriendAnnotation: NSObject, MKAnnotation {
    var friend: Friend
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { friend.user.username }

    init(friend: Friend, coordinate: CLLocationCoordinate2D) {
        self.friend = friend
        self.coordinate = coordinate
    }
}

/// Round avatar pin: photo if the friend sent one, otherwise their initial.
final class FriendAnnotationView: MKAnnotationView {
    static let reuseID = "friend"
    private let size: CGFloat = 40

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        canShowCallout = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
        displayPriority = .required
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with friend: Friend) {
        image = Self.render(username: friend.user.username, avatar: friend.avatar, size: size)
        accessibilityLabel = friend.user.username
    }

    static func render(username: String, avatar: Data?, size: CGFloat) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size).image { _ in
            let circle = UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            circle.addClip()
            if let avatar, let photo = UIImage(data: avatar) {
                photo.draw(in: rect)
            } else {
                UIColor(AvatarView.color(for: username)).setFill()
                circle.fill()
                let initial = String(username.prefix(1)).uppercased() as NSString
                let font = UIFont.systemFont(ofSize: size * 0.45, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                let textSize = initial.size(withAttributes: attrs)
                initial.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2), withAttributes: attrs)
            }
            UIColor.white.setStroke()
            circle.lineWidth = 2
            circle.stroke()
        }
    }
}
