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
    /// The friend whose card is open; their pin is drawn above any pins it overlaps.
    var selectedID: Data? = nil
    let command: MapCommand?
    let onSelect: (Data) -> Void
    /// Tap on the map itself (not a pin), used to close the friend card.
    var onBackgroundTap: () -> Void = {}

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.register(FriendAnnotationView.self, forAnnotationViewWithReuseIdentifier: FriendAnnotationView.reuseID)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapTapped(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        map.setUserTrackingMode(.follow, animated: false)
        // Keep the Apple Maps logo and Legal link clear of the friend bar overlay.
        map.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 110, right: 8)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onBackgroundTap = onBackgroundTap
        context.coordinator.sync(friends: friends, on: map)
        context.coordinator.raise(selectedID, on: map)
        if let command, command != context.coordinator.lastCommand {
            context.coordinator.lastCommand = command
            switch command.kind {
            case .followUser:
                // Like Android: fly to you at street level (closer if you're already zoomed in), then follow.
                if let here = map.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(here) {
                    Self.zoomIn(map, to: here, liftForCard: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { map.setUserTrackingMode(.follow, animated: true) }
                } else {
                    map.setUserTrackingMode(.follow, animated: true)
                }
            case .focus(let lat, let lng):
                Self.zoomIn(map, to: CLLocationCoordinate2D(latitude: lat, longitude: lng), liftForCard: true)
            }
        }
    }

    /// Android's zoom level for "show me this place" (Constants.DEFAULT_ZOOM_LEVEL).
    static let streetZoom = 15.0

    /// The Android app's camera move: center on the coordinate at zoom 15, or the current zoom if it's already
    /// closer, facing north and flat. `liftForCard` keeps a friend's pin above their card at the bottom.
    static func zoomIn(_ map: MKMapView, to coordinate: CLLocationCoordinate2D, liftForCard: Bool) {
        let width = max(map.bounds.width, 1)
        // Web-map zoom from the current span: 256-point tiles, 360° of longitude at zoom 0.
        let currentZoom = log2(360 * Double(width) / 256 / max(map.region.span.longitudeDelta, 1e-9))
        let zoom = max(currentZoom, streetZoom)
        let lonDelta = 360 * Double(width) / 256 / pow(2, zoom)
        let latDelta = lonDelta * Double(map.bounds.height / width) * cos(coordinate.latitude * .pi / 180)
        var center = coordinate
        if liftForCard { center.latitude -= latDelta * 0.2 }
        map.setUserTrackingMode(.none, animated: false)
        let camera = map.camera.copy() as! MKMapCamera
        camera.heading = 0
        camera.pitch = 0
        map.setCamera(camera, animated: false)
        map.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)),
                      animated: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onSelect: (Data) -> Void
        var onBackgroundTap: () -> Void = {}
        var lastCommand: MapCommand?
        private var annotations: [Data: FriendAnnotation] = [:]
        private var circles: [Data: MKCircle] = [:]
        private var selectedID: Data?

        init(onSelect: @escaping (Data) -> Void) { self.onSelect = onSelect }

        @objc func mapTapped(_ recognizer: UITapGestureRecognizer) {
            guard let map = recognizer.view as? MKMapView else { return }
            // Ignore taps that land on a pin or the user's location; those are handled by didSelect.
            var hit = map.hitTest(recognizer.location(in: map), with: nil)
            while let view = hit {
                if view is MKAnnotationView { return }
                hit = view.superview
            }
            onBackgroundTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

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

        /// Brings the open friend's pin to the front. We deselect pins as soon as they're tapped (the card is
        /// our selection UI), so MapKit's own "selected pin on top" never applies; set the z-priority ourselves.
        func raise(_ id: Data?, on map: MKMapView) {
            guard id != selectedID else { return }
            let previous = selectedID
            selectedID = id
            for changed in [previous, id].compactMap({ $0 }) {
                guard let annotation = annotations[changed], let view = map.view(for: annotation) else { continue }
                view.zPriority = changed == id ? .max : .defaultUnselected
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? FriendAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: FriendAnnotationView.reuseID, for: annotation)
            (view as? FriendAnnotationView)?.configure(with: annotation.friend)
            // Reused views keep their old priority, so set it every time.
            view.zPriority = annotation.friend.id == selectedID ? .max : .defaultUnselected
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
    var title: String? { friend.displayName }

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
        image = Self.render(username: friend.avatarName, avatar: friend.displayAvatar, size: size)
        accessibilityLabel = friend.displayName
    }

    static func render(username: String, avatar: Data?, size: CGFloat) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size).image { _ in
            let circle = UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            circle.addClip()
            if let avatar, let photo = UIImage(data: avatar) {
                // Fill and crop, never stretch: a non-square photo would otherwise be squashed into the pin.
                photo.draw(in: AvatarImage.fillRect(for: photo, in: rect))
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
