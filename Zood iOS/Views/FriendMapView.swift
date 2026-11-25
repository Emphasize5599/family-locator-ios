import MapKit
import SwiftUI

/// What the map should do next. Bumping `id` re-runs the command even if it's the same kind.
struct MapCommand: Equatable {
    enum Kind: Equatable {
        case followUser
        case northUp
        case focus(latitude: Double, longitude: Double)
        case recenter(latitude: Double, longitude: Double)
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
    var onHeadingChanged: (Double) -> Void = { _ in }

    final class MapView: MKMapView {
        var onSizeChanged: (() -> Void)?
        private var lastSize = CGSize.zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != lastSize else { return }
            lastSize = bounds.size
            onSizeChanged?()
        }
    }

    func makeUIView(context: Context) -> MapView {
        let map = MapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
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

    func updateUIView(_ map: MapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onBackgroundTap = onBackgroundTap
        coordinator.onHeadingChanged = onHeadingChanged
        coordinator.sync(friends: friends, on: map)
        coordinator.raise(selectedID, on: map)
        let command = command
        let selectedFriend = friends.first { $0.id == selectedID }
        let updateCamera = { [weak map, weak coordinator] in
            guard let map, let coordinator else { return }
            coordinator.updateCamera(on: map, command: command, selectedFriend: selectedFriend)
        }
        map.onSizeChanged = updateCamera
        updateCamera()
    }

    static func dismantleUIView(_ map: MapView, coordinator: Coordinator) {
        coordinator.stopFlight()
        map.onSizeChanged = nil
        map.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onSelect: (Data) -> Void
        var onBackgroundTap: () -> Void = {}
        var onHeadingChanged: (Double) -> Void = { _ in }
        private var lastHeading: Double = 0
        var lastCommand: MapCommand?
        private var followedFriendID: Data?
        private var cameraSelectionID: Data?
        private var lastFriendPoint: MKMapPoint?
        // MapKit can render a wider rect than requested, depending on the screen and map insets.
        private var settledFriendScale: Double?
        private var flight: Flight?
        private var displayLink: CADisplayLink?
        private weak var flyingMap: MKMapView?

        // MapLibre uses a 512-point world at zoom 0. Zoom 15 is the Android app's street-level floor.
        private static let mapLibreStreetScale = 512.0 * Double(1 << 15)
        private static let globeWidth = MKMapRect.world.size.width

        private struct Flight {
            let start: MKMapPoint
            let end: MKMapPoint
            let startWidth: Double
            let endWidth: Double
            let aspect: Double
            let path: ZoomPath?
            let startedAt: CFTimeInterval
            let trackUser: Bool
            let liftForCard: Bool
        }

        /// The van Wijk–Nuij path used for a map flight. A distant target naturally widens the view mid-flight.
        private struct ZoomPath {
            private static let rho = 1.42
            private let startWidth: Double
            private let distance: Double
            private let startR: Double
            private let endR: Double

            init?(startWidth: Double, endWidth: Double, distance: Double) {
                guard distance > max(startWidth, endWidth) * 0.001 else { return nil }
                self.startWidth = startWidth
                self.distance = distance
                let rhoSquared = Self.rho * Self.rho
                let projected = rhoSquared * distance
                let delta = endWidth * endWidth - startWidth * startWidth
                startR = -asinh((delta + projected * projected) / (2 * startWidth * projected))
                endR = -asinh((delta - projected * projected) / (2 * endWidth * projected))
            }

            func sample(_ fraction: Double) -> (along: Double, width: Double) {
                let r = startR + (endR - startR) * fraction
                let coshStart = cosh(startR)
                let width = startWidth * coshStart / cosh(r)
                let along = startWidth * (coshStart * tanh(r) - sinh(startR))
                    / (Self.rho * Self.rho * distance)
                return (min(max(along, 0), 1), width)
            }
        }

        func updateCamera(on map: MKMapView, command: MapCommand?, selectedFriend: Friend?) {
            guard map.bounds.width > 1, map.bounds.height > 1 else { return }
            if cameraSelectionID != selectedFriend?.id {
                // Dismissing a card leaves the camera free to finish the move already in progress.
                if selectedFriend != nil, command == nil || command == lastCommand { stopFlight() }
                cameraSelectionID = selectedFriend?.id
                followedFriendID = selectedFriend?.id
                lastFriendPoint = nil
            }

            let loc = selectedFriend?.location
            if let command, command != lastCommand {
                lastCommand = command
                switch command.kind {
                case .northUp:
                    let camera = map.camera
                    guard camera.heading != 0 else { return }
                    stopFlight()
                    if map.userTrackingMode == .followWithHeading {
                        map.setUserTrackingMode(.follow, animated: false)
                    }
                    camera.heading = 0
                    map.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
                case .followUser:
                    followedFriendID = nil
                    lastFriendPoint = nil
                    if let here = map.userLocation.location?.coordinate, CLLocationCoordinate2DIsValid(here) {
                        fly(map, to: MKMapPoint(here), liftForCard: false, trackUser: true)
                    } else {
                        stopFlight()
                        map.setUserTrackingMode(.follow, animated: true)
                    }
                case .focus(let lat, let lng):
                    followedFriendID = selectedFriend?.id
                    let point = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lng))
                    lastFriendPoint = selectedFriend == nil ? nil : point
                    fly(map, to: point, liftForCard: selectedFriend != nil, trackUser: false)
                case .recenter(let lat, let lng):
                    followedFriendID = selectedFriend?.id
                    let point = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lng))
                    lastFriendPoint = point
                    stopFlight()
                    recenter(map, at: point)
                }
                return
            }

            guard followedFriendID != nil, followedFriendID == selectedFriend?.id, let loc, flight == nil else { return }
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude))
            if let previous = lastFriendPoint {
                guard previous.x != point.x || previous.y != point.y else { return }
                lastFriendPoint = point
                recenter(map, at: point)
            } else {
                lastFriendPoint = point
                fly(map, to: point, liftForCard: true, trackUser: false)
            }
        }

        private func recenter(_ map: MKMapView, at point: MKMapPoint) {
            map.setUserTrackingMode(.none, animated: false)
            let lifted = MKMapPoint(x: point.x, y: point.y + map.visibleMapRect.size.height * 0.06)
            map.setCenter(lifted.coordinate, animated: !UIAccessibility.isReduceMotionEnabled)
        }

        private func fly(_ map: MKMapView, to point: MKMapPoint, liftForCard: Bool, trackUser: Bool) {
            let intendedWidth = flight?.endWidth
            let rect = map.visibleMapRect
            let width = min(max(rect.size.width, 1), Self.globeWidth)
            let aspect = Double(map.bounds.height / map.bounds.width)
            let streetWidth = Self.globeWidth * Double(map.bounds.width) / Self.mapLibreStreetScale
            // Keep a tighter manual zoom, including when a new tap interrupts the zoomed-out part of a flight.
            let endWidth = max(1, min(intendedWidth ?? width, streetWidth))
            let start = MKMapPoint(x: rect.midX, y: rect.midY)
            let dx = horizontalDelta(from: start.x, to: point.x)
            let end = MKMapPoint(x: start.x + dx, y: point.y + (liftForCard ? endWidth * aspect * 0.06 : 0))
            let camera = map.camera
            if liftForCard, camera.heading == 0, camera.pitch == 0, map.userTrackingMode == .none {
                // Android retains the current zoom when already close. Allow a small screen-space
                // tolerance so rounding, or another pin at the same place, doesn't restart the flight.
                let currentCenter = flight?.end ?? start
                let currentWidth = intendedWidth ?? width
                let settledWidth = (settledFriendScale ?? 0) * Double(map.bounds.width)
                let separation = hypot(horizontalDelta(from: currentCenter.x, to: end.x), end.y - currentCenter.y)
                if flight?.trackUser != true, currentWidth <= max(endWidth, settledWidth) * 1.02,
                   separation <= endWidth * 16 / Double(map.bounds.width) { return }
            }
            stopFlight()
            let distance = hypot(dx, end.y - start.y)
            map.setUserTrackingMode(.none, animated: false)
            if camera.heading != 0 || camera.pitch != 0 {
                camera.heading = 0
                camera.pitch = 0
                map.setCamera(camera, animated: false)
            }

            if UIAccessibility.isReduceMotionEnabled {
                setViewport(map, center: end, width: endWidth, aspect: aspect)
                if liftForCard { settledFriendScale = map.visibleMapRect.size.width / Double(map.bounds.width) }
                if trackUser { map.setUserTrackingMode(.follow, animated: false) }
                return
            }

            let path = ZoomPath(startWidth: width, endWidth: endWidth, distance: distance)
            flight = Flight(start: start, end: end, startWidth: width, endWidth: endWidth, aspect: aspect,
                            path: path, startedAt: CACurrentMediaTime(), trackUser: trackUser, liftForCard: liftForCard)
            flyingMap = map
            let link = CADisplayLink(target: self, selector: #selector(animateFlight))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        private func horizontalDelta(from start: Double, to end: Double) -> Double {
            let delta = (end - start).truncatingRemainder(dividingBy: Self.globeWidth)
            return abs(delta) > Self.globeWidth / 2 ? delta - copysign(Self.globeWidth, delta) : delta
        }

        static let flightDuration: CFTimeInterval = 0.4

        @objc private func animateFlight(_ link: CADisplayLink) {
            guard let flight, let map = flyingMap else { stopFlight(); return }
            // About as quick as Android's camera moves (MapLibre animates them in 300 ms).
            let fraction = min(max((link.timestamp - flight.startedAt) / Self.flightDuration, 0), 1)
            let eased = fraction * fraction * (3 - 2 * fraction)
            let frame = flight.path?.sample(eased)
            let along = frame?.along ?? eased
            let width = frame?.width ?? flight.startWidth * pow(flight.endWidth / flight.startWidth, eased)
            let point = MKMapPoint(x: flight.start.x + (flight.end.x - flight.start.x) * along,
                                   y: flight.start.y + (flight.end.y - flight.start.y) * along)
            if fraction >= 1 {
                setViewport(map, center: flight.end, width: flight.endWidth, aspect: flight.aspect)
                if flight.liftForCard { settledFriendScale = map.visibleMapRect.size.width / Double(map.bounds.width) }
                stopFlight()
                if flight.trackUser { map.setUserTrackingMode(.follow, animated: false) }
            } else {
                setViewport(map, center: point, width: width, aspect: flight.aspect)
            }
        }

        private func setViewport(_ map: MKMapView, center: MKMapPoint, width: Double, aspect: Double) {
            let width = min(width, Self.globeWidth)
            let height = min(width * aspect, Self.globeWidth)
            let x = (center.x.truncatingRemainder(dividingBy: Self.globeWidth) + Self.globeWidth)
                .truncatingRemainder(dividingBy: Self.globeWidth)
            let y = min(max(center.y, height / 2), Self.globeWidth - height / 2)
            map.setVisibleMapRect(MKMapRect(x: x - width / 2, y: y - height / 2, width: width, height: height),
                                  edgePadding: .zero, animated: false)
        }

        func stopFlight() {
            displayLink?.invalidate()
            displayLink = nil
            flyingMap = nil
            flight = nil
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let heading = mapView.camera.heading
            guard heading != lastHeading else { return }
            lastHeading = heading
            DispatchQueue.main.async { [weak self] in
                guard let self, lastHeading == heading else { return }
                onHeadingChanged(heading)
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if mapView.subviews.first?.gestureRecognizers?.contains(where: {
                $0.state == .began || $0.state == .changed
            }) == true {
                stopFlight()
            }
        }

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
