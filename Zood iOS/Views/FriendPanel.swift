import CoreLocation
import MapKit
import SwiftUI

/// Card for one friend, shown above the friend bar like george's InfoPanel: who/where/when, a Refresh (request
/// update) button and the "share my location" switch.
struct FriendPanel: View {
    @EnvironmentObject private var model: AppModel
    let friendID: Data
    var onClose: () -> Void = {}

    @State private var address: String?
    @State private var explanation: Explanation?
    @State private var confirmingRemove = false
    @State private var showingSafetyNumber = false
    @State private var dragOffset: CGFloat = 0

    /// Which "why?" tile is expanded.
    private enum Explanation: Equatable {
        case unsupported
        case noResponse
    }

    var body: some View {
        if let friend = model.local.friends[friendID] {
            VStack(alignment: .leading, spacing: 16) {
                header(friend)
                actions(friend)
                if let explanation {
                    explanationTile(explanation, friend: friend)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 2)
            .padding(.horizontal, 12)
            // Swipe down to close, like dismissing a sheet.
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { dragOffset = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 60 { onClose() }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
                    }
            )
            .task(id: friend.location) { await lookUpAddress(friend.location) }
            .sheet(isPresented: $showingSafetyNumber) {
                SafetyNumberView(friend: friend).environmentObject(model)
            }
            .confirmationDialog("Remove \(friend.user.username)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await model.removeFriend(friend) }
                    onClose()
                }
            } message: {
                Text("You'll stop sharing your location with them and they'll disappear from your map.")
            }
        }
    }

    // MARK: Header

    private func header(_ friend: Friend) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AvatarView(username: friend.user.username, imageData: friend.avatar, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(friend.user.username)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let platform = friend.device?.platform {
                        Image(systemName: platform == .ios ? "iphone" : "candybarphone")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(platform == .ios ? "iPhone" : "Android")
                    }
                }
                if let loc = friend.location {
                    HStack(spacing: 10) {
                        if let level = loc.batteryLevel {
                            Label("\(level)%", systemImage: batterySymbol(level: level, charging: loc.batteryCharging == true))
                        }
                        if let movement = loc.movement, movement != "unknown", movement != "stationary" {
                            Label(movement.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "figure.walk")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let address {
                        Text(address).font(.subheadline)
                    }
                    Text("Updated \(loc.time.relativeDescription)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if friend.theyShare {
                    Text("Waiting for their first location…").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Not sharing their location with you").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                FriendMenu(hasLocation: friend.location != nil,
                           openInMaps: { openInMaps(friend) },
                           viewSafetyNumber: { showingSafetyNumber = true },
                           remove: { confirmingRemove = true })
                    .fixedSize()
                CloseButton(action: onClose)
                    .fixedSize()
            }
        }
    }

    // MARK: Actions

    private func actions(_ friend: Friend) -> some View {
        HStack(alignment: .top) {
            refreshColumn(friend)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Toggle("Share my location", isOn: sharingBinding(friend))
                    .labelsHidden()
                    .tint(.zoodBlue)
                Text("Share my location").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func refreshColumn(_ friend: Friend) -> some View {
        let capability = model.requestCapability(for: friend)
        let status = model.requestStatuses[friend.id].flatMap { $0.isStale ? nil : $0 }
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { explanation = nil }
                Task { await model.requestLocationUpdate(from: friend) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.zoodBlue)
            .disabled(capability != .supported || isInFlight(status))

            switch capability {
            case .unsupported:
                // Grayed-out button, "Unsupported", and a (?) that opens an explanation tile.
                HStack(spacing: 4) {
                    Text("Unsupported")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    infoButton(for: .unsupported)
                }
            case .notSharing:
                Text("They aren't sharing with you").font(.footnote).foregroundStyle(.secondary)
            case .supported:
                if let status { statusLine(status) }
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ status: UpdateRequestStatus) -> some View {
        switch status {
        case .sent:
            Label("Requesting…", systemImage: "antenna.radiowaves.left.and.right").font(.footnote).foregroundStyle(.secondary)
        case .responded(.starting, _):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Getting their location…").font(.footnote).foregroundStyle(.secondary)
            }
        case .responded(.finished, _):
            Label("Updated", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.zoodGreen)
        case .responded(.tooSoon, _):
            Text("They updated moments ago").font(.footnote).foregroundStyle(.secondary)
        case .noResponse:
            HStack(spacing: 4) {
                Text("No response").font(.footnote.weight(.medium)).foregroundStyle(Color.zoodOrange)
                infoButton(for: .noResponse)
            }
        }
    }

    private func infoButton(for kind: Explanation) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { explanation = explanation == kind ? nil : kind }
        } label: {
            Image(systemName: explanation == kind ? "questionmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(Color.zoodBlueDark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .unsupported ? "Why is this unsupported?" : "Why no response?")
    }

    private func explanationTile(_ kind: Explanation, friend: Friend) -> some View {
        let name = friend.user.username
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(kind == .unsupported ? "Why is Refresh unsupported?" : "Why didn't they respond?",
                      systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.zoodNavy)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { explanation = nil }
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }
            switch kind {
            case .unsupported where friend.device?.platform != .ios:
                Text("\(name) has **Live Requests** turned off, so their phone isn't listening for requests.")
                Text("Their location still updates on its own whenever they move. To enable Refresh, \(name) can turn on Live Requests in Settings.")
            case .unsupported:
                Text("\(name)'s iPhone isn't listening for requests right now. Zood's servers can't wake an iPhone, so the app has to stay running in the background to hear one. That stops if **Live Requests** is off, or if the app was swiped closed.")
                Text("Their location still updates on its own whenever they move. To enable Refresh, \(name) can open the app (and turn on Live Requests with location access **Always** if it's off).")
            case .noResponse:
                Text("Requests only reach phones that currently have the app running in the background. \(name)'s phone may be offline, in Low Power Mode, or the app may have been swiped closed.")
                Text("Their location will still update the next time they move or open the app.")
            }
        }
        .font(.footnote)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.zoodBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.zoodBlue.opacity(0.35)))
    }

    // MARK: Helpers

    private func isInFlight(_ status: UpdateRequestStatus?) -> Bool {
        switch status {
        case .sent, .responded(.starting, _): return true
        default: return false
        }
    }

    private func sharingBinding(_ friend: Friend) -> Binding<Bool> {
        Binding(
            get: { model.local.friends[friend.id]?.weShare ?? false },
            set: { share in
                Task {
                    if share {
                        try? await model.startSharing(with: friend.user)
                    } else {
                        await model.stopSharing(with: friend)
                    }
                }
            }
        )
    }

    /// Same as Android's "Open in Maps": hand the friend's last location to the Maps app, pinned with their name.
    private func openInMaps(_ friend: Friend) {
        guard let loc = friend.location else { return }
        let coordinate = CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = friend.user.username
        item.openInMaps(launchOptions: [MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate)])
    }

    private func batterySymbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func lookUpAddress(_ location: FriendLocation?) async {
        guard let location else { address = nil; return }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: location.latitude, longitude: location.longitude))
        guard let p = placemarks?.first else { return }
        address = [p.name, p.locality].compactMap { $0 }.removingDuplicates().joined(separator: ", ")
    }
}

/// The ⋯ menu as a UIKit button + UIMenu. SwiftUI's `Menu` refreshes its open popup whenever the surrounding view
/// updates (new location, reconnect, …), which made "Remove Friend" flash. A UIMenu only changes when we replace
/// it, which we do only when its items change. The actions read the latest closures, so they never go stale.
private struct FriendMenu: UIViewRepresentable {
    let hasLocation: Bool
    let openInMaps: () -> Void
    let viewSafetyNumber: () -> Void
    let remove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: panelIconConfig), for: .normal)
        button.tintColor = UIColor(Color.zoodBlueDark)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "More")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.openInMaps = openInMaps
        coordinator.viewSafetyNumber = viewSafetyNumber
        coordinator.remove = remove
        guard coordinator.builtFor != hasLocation else { return }
        coordinator.builtFor = hasLocation
        var items: [UIMenuElement] = []
        if hasLocation {
            items.append(UIAction(title: String(localized: "Open in Maps"), image: UIImage(systemName: "map")) { [weak coordinator] _ in
                coordinator?.openInMaps?()
            })
        }
        items.append(UIAction(title: String(localized: "View Safety Number"), image: UIImage(systemName: "lock.shield")) { [weak coordinator] _ in
            coordinator?.viewSafetyNumber?()
        })
        items.append(UIAction(title: String(localized: "Remove Friend"), image: UIImage(systemName: "person.crop.circle.badge.minus"),
                              attributes: .destructive) { [weak coordinator] _ in
            coordinator?.remove?()
        })
        button.menu = UIMenu(children: items)
    }

    final class Coordinator {
        var builtFor: Bool?
        var openInMaps: (() -> Void)?
        var viewSafetyNumber: (() -> Void)?
        var remove: (() -> Void)?
    }
}

/// Shared by the ⋯ and ✕ buttons so they're always exactly the same size.
private let panelIconConfig = UIImage.SymbolConfiguration(textStyle: .title2)

/// Closes the friend card. UIKit like `FriendMenu`, with the same symbol configuration, so the two match.
private struct CloseButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark.circle", withConfiguration: panelIconConfig), for: .normal)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = String(localized: "Close")
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func tapped() { action?() }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
