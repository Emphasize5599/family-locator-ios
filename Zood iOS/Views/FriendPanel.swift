import CoreLocation
import MapKit
import SwiftUI

/// Card for one friend, shown above the friend bar like george's InfoPanel: who/where/when, a Refresh (request
/// update) button and the "share my location" switch.
struct FriendPanel: View {
    @EnvironmentObject private var model: AppModel
    let friendID: Data
    var maxHeight: CGFloat = .infinity
    var onClose: () -> Void = {}

    @State private var address: String?
    @State private var explanation: Explanation?
    @State private var confirmingRemove = false
    @State private var removeError: String?
    @State private var confirmingBlock = false
    @State private var blockError: String?
    @State private var showingSafetyNumber = false
    @State private var editingNickname = false
    @State private var linkingContact = false
    @State private var dragOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 320

    /// Which "why?" tile is expanded.
    private enum Explanation: Equatable {
        case unsupported
        case noResponse
    }

    var body: some View {
        if let friend = model.local.friends[friendID] {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    header(friend)
                        .gesture(closeGesture)
                    actions(friend)
                    // iOS 16.4+ shows these as popovers from the (?); earlier versions open them inline here.
                    if let explanation, !Self.usesPopovers {
                        explanationTile(explanation, friend: friend)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(Spacing.large)
                // Measure the content so the card can hug it. A PreferenceKey never got the measurement
                // out of the ScrollView (the card stayed at its 320-point default with blank space below),
                // so read the size directly and store it.
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { contentHeight = geometry.size.height }
                        .compatOnChange(of: geometry.size.height) { contentHeight = $0 }
                })
            }
            // Keep the friend bar and warnings reachable on short screens and at accessibility sizes.
            // A flexible height lets the surrounding stack give the card only the space that remains.
            .frame(minHeight: 0, idealHeight: min(contentHeight, maxHeight), maxHeight: min(contentHeight, maxHeight))
            .floatingSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, Spacing.medium)
            // Swipe down to close, like dismissing a sheet.
            .offset(y: max(0, dragOffset))
            .task(id: friend.location) { await lookUpAddress(friend.location) }
            // Re-check a cached "can't answer requests" before showing Unsupported (it may be out of date).
            .task(id: friendID) { await model.refreshDeviceStatusIfNeeded(friend) }
            .sheet(isPresented: $editingNickname) {
                FriendNicknameView(friend: friend).environmentObject(model)
            }
            .sheet(isPresented: $linkingContact) {
                ContactLinkView(friendID: friend.id).environmentObject(model)
            }
            .sheet(isPresented: $showingSafetyNumber) {
                SafetyNumberView(friend: friend).environmentObject(model)
            }
            .alert("Could Not Block User", isPresented: Binding(get: { blockError != nil }, set: { if !$0 { blockError = nil } })) {
                Button("OK") { blockError = nil }
            } message: { Text(blockError ?? "") }
            .alert("Remove & Block \(friend.displayName)?", isPresented: $confirmingBlock) {
                Button("Cancel", role: .cancel) {}
                Button("Remove & Block", role: .destructive) {
                    Task {
                        do { try await model.blockUser(friend.user); onClose() }
                        catch { blockError = error.localizedDescription }
                    }
                }
            } message: {
                Text("Stops sharing and blocks their requests on this iPhone. Previously received locations may remain on their device. You can unblock them in Settings.")
            }
            .alert("Remove \(friend.displayName)?", isPresented: $confirmingRemove) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    Task {
                        do { try await model.removeFriend(friend); onClose() }
                        catch { removeError = error.localizedDescription }
                    }
                }
            } message: {
                Text("You’ll be removed from each other’s maps. Either of you can send a new request later.")
            }
            .alert("Could Not Remove Friend", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
                Button("OK") { removeError = nil }
            } message: { Text(removeError ?? "") }
        }
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { dragOffset = $0.translation.height }
            .onEnded { value in
                if value.translation.height > 60 { onClose() }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
            }
    }

    // MARK: Header

    private func header(_ friend: Friend) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            nameAndControls(friend)
            // Battery, address and status: the same even gap between every line.
            if let loc = friend.location {
                batteryAndActivity(loc)
                addressLink(friend, loc)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                unifiedStatus(friend, now: context.date)
            }
        }
    }

    /// The name sits beside the avatar while it fits on one line between the avatar and the icons; a longer
    /// name moves to its own line under them and wraps across the card's full width instead of truncating.
    @ViewBuilder
    private func nameAndControls(_ friend: Friend) -> some View {
        if #available(iOS 16, *) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.small) {
                    avatar(friend)
                    Text(friend.displayName)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Spacer(minLength: Spacing.small)
                    headerControls(friend)
                }
                nameBelowAvatar(friend)
            }
        } else {
            nameBelowAvatar(friend)
        }
    }

    private func nameBelowAvatar(_ friend: Friend) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.tight) {
                avatar(friend)
                Spacer(minLength: 0)
                headerControls(friend)
            }
            Text(friend.displayName)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func avatar(_ friend: Friend) -> some View {
        AvatarView(username: friend.avatarName, imageData: friend.displayAvatar, size: 56)
    }

    /// Platform logo, ✎, ⋯ and ✕, all the same size.
    private func headerControls(_ friend: Friend) -> some View {
        HStack(spacing: Spacing.tight) {
            if let platform = friend.device?.platform { PlatformBadge(platform: platform) }
            // Drawn by UIKit with the same symbol configuration as ⋯ and ✕, so all three match.
            PanelIconButton(systemName: "pencil.circle", tint: UIColor(Color.zoodBlueDark),
                            accessibilityLabel: String(localized: "Edit friend's nickname")) {
                editingNickname = true
            }
            .frame(width: 44, height: 44)
            FriendMenu(linked: friend.linkedContact != nil,
                       username: friend.user.username,
                       linkContact: { linkingContact = true },
                       viewSafetyNumber: { showingSafetyNumber = true },
                       remove: { confirmingRemove = true },
                       block: { confirmingBlock = true })
                .frame(width: 44, height: 44)
            CloseButton(action: onClose).frame(width: 44, height: 44)
        }
    }

    private func batteryAndActivity(_ loc: FriendLocation) -> some View {
        HStack(spacing: Spacing.small) {
            if let level = loc.batteryLevel {
                Label("\(level)%", systemImage: batterySymbol(level: level, charging: loc.batteryCharging == true))
            }
            if let movement = loc.movement, movement != "unknown", movement != "stationary" {
                Label(movement.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "figure.walk")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color.cardSecondary)
    }

    private func addressLink(_ friend: Friend, _ loc: FriendLocation) -> some View {
        Button { openInMaps(friend) } label: {
            // An inline glyph consumes space on the first line only; wrapped lines use the whole card.
            (Text(Image(systemName: "map.fill")) + Text(" ") + Text(address ?? "\(loc.latitude), \(loc.longitude)").underline())
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open in Apple Maps")
        // The underline eats into the gap below the address, so the even 4-point gap to the status line
        // looked tighter here than between the other lines. A little extra space evens it out visually.
        .padding(.bottom, 3)
    }

    /// One line, always below the address, for everything "freshness" related: requesting, the green
    /// Updated check, no response, and finally the plain "Updated …" time. Keeping it in one place means the
    /// card doesn't jump around while a request is in progress.
    @ViewBuilder
    private func unifiedStatus(_ friend: Friend, now: Date) -> some View {
        let capability = model.requestCapability(for: friend)
        let status = model.requestStatuses[friend.id].flatMap { $0.isStale ? nil : $0 }

        // The green check is a brief confirmation; after a few seconds it fades into the regular time.
        let showingSuccess: Bool = {
            if case .responded(.finished, let time) = status { return now.timeIntervalSince(time) < 3 }
            return false
        }()

        // Both lines stay in the layout and cross-fade with opacity. Swapping views with a transition
        // inside this once-a-second TimelineView could leave the "Updated …" time invisible after the
        // check faded (seen on iOS 17), so nothing is inserted or removed here.
        ZStack(alignment: .leading) {
            regularStatus(friend, status: status, capability: capability)
                .opacity(showingSuccess ? 0 : 1)
            Label("Updated", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.zoodGreen)
                .opacity(showingSuccess ? 1 : 0)
                .accessibilityHidden(!showingSuccess)
        }
        .font(.footnote)
        .foregroundStyle(Color.cardSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.35), value: showingSuccess)
    }

    /// A relative time ("5 min. ago") reads best today; an older update gets a date so "Updated 2 days ago"
    /// can't be mistaken for something more recent.
    private func updatedText(_ loc: FriendLocation) -> Text {
        if Calendar.current.isDateInToday(loc.time) {
            return Text("Updated \(loc.time.relativeDescription)")
        }
        return Text("Updated \(loc.time.formatted(date: .abbreviated, time: .shortened))")
    }

    /// The status line when no green check is showing: request progress if there is any, otherwise how
    /// fresh their location is.
    @ViewBuilder
    private func regularStatus(_ friend: Friend, status: UpdateRequestStatus?, capability: RequestCapability) -> some View {
        if let status, showsRequestStatus(status) {
            statusLine(status, friend: friend)
        } else if capability == .checking {
            HStack(spacing: Spacing.tight) { ProgressView().controlSize(.mini); Text("Checking…") }
        } else if case .unsupported = capability {
            // Keep the update time; the unsupported note goes underneath it.
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let loc = friend.location { updatedText(loc) }
                HStack(spacing: Spacing.tight) { Text("On-demand refresh unsupported"); infoButton(for: .unsupported, friend: friend) }
            }
        } else if let loc = friend.location {
            updatedText(loc)
        } else {
            Text(friend.theyShare ? "Waiting for their first location…" : "Not sharing their location with you")
        }
    }

    /// Request results that should replace the "Updated …" time until they go stale.
    /// A finished request is handled separately (the timed green check).
    private func showsRequestStatus(_ status: UpdateRequestStatus) -> Bool {
        switch status {
        case .sent, .responded(.starting, _), .responded(.tooSoon, _), .noResponse:
            return true
        case .responded(.finished, _):
            return false
        }
    }

    // MARK: Actions

    private func actions(_ friend: Friend) -> some View {
        HStack(spacing: Spacing.medium) {
            refreshColumn(friend)
            Spacer(minLength: Spacing.small)
            Toggle(isOn: sharingBinding(friend)) {
                Text("Share my location")
                    .font(.subheadline)
                    .foregroundStyle(Color.cardSecondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .tint(.zoodBlue)
        }
    }

    /// Refresh is hidden while their phone can't answer requests; it comes back once a later check finds it can.
    @ViewBuilder
    private func refreshColumn(_ friend: Friend) -> some View {
        let capability = model.requestCapability(for: friend)
        let status = model.requestStatuses[friend.id].flatMap { $0.isStale ? nil : $0 }
        if case .unsupported = capability {
            EmptyView()
        } else {
            refreshButton(friend, capability: capability, status: status)
        }
    }

    private func refreshButton(_ friend: Friend, capability: RequestCapability, status: UpdateRequestStatus?) -> some View {
        Button {
            withAnimation { explanation = nil }
            Task { await model.requestLocationUpdate(from: friend) }
        } label: {
            // Drawn exactly like the bottom bar's Add and Requests buttons: a 52-point filled circle.
            Image(systemName: "arrow.clockwise")
                .font(.title2.weight(.semibold))
                .frame(width: 52, height: 52)
                .background(Color.zoodBlue, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh location")
        .disabled(capability != .supported || isInFlight(status))
        .opacity(capability != .supported || isInFlight(status) ? 0.4 : 1)
    }

    @ViewBuilder
    private func statusLine(_ status: UpdateRequestStatus, friend: Friend) -> some View {
        switch status {
        case .sent:
            Label("Requesting…", systemImage: "antenna.radiowaves.left.and.right").font(.footnote).foregroundStyle(Color.cardSecondary)
        case .responded(.starting, _):
            HStack(spacing: Spacing.tight) {
                ProgressView().controlSize(.mini)
                Text("Getting their location…").font(.footnote).foregroundStyle(Color.cardSecondary)
            }
        case .responded(.finished, _):
            Label("Updated", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.zoodGreen)
        case .responded(.tooSoon, _):
            Text("They updated moments ago").font(.footnote).foregroundStyle(Color.cardSecondary)
        case .noResponse:
            HStack(spacing: Spacing.tight) {
                Text("No response").font(.footnote.weight(.medium)).foregroundStyle(Color.zoodOrange)
                infoButton(for: .noResponse, friend: friend)
            }
        }
    }

    /// Popovers that stay popovers on iPhone need iOS 16.4 (`presentationCompactAdaptation`).
    static var usesPopovers: Bool {
        if #available(iOS 16.4, *) { return true }
        return false
    }

    /// The (?) next to a status. On iOS 16.4+ it opens a small popover anchored to itself, the way Apple uses
    /// popovers for brief, optional help: tap outside to dismiss, no buttons. Earlier iOS opens it inline.
    @ViewBuilder
    private func infoButton(for kind: Explanation, friend: Friend) -> some View {
        let button = Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { explanation = explanation == kind ? nil : kind }
        } label: {
            // The tap area reaches 8 points past the icon without adding to the layout, so the (?) sits
            // right after its text and doesn't push the line apart.
            Image(systemName: explanation == kind ? "questionmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(Color.zoodBlueDark)
                .padding(8)
                .contentShape(Rectangle())
                .padding(-8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .unsupported ? "Why is on-demand refresh unsupported?" : "Why no response?")
        if #available(iOS 16.4, *) {
            button.popover(isPresented: Binding(get: { explanation == kind }, set: { if !$0 { explanation = nil } }),
                           arrowEdge: .bottom) {
                explanationText(kind, friend: friend)
                    .padding(Spacing.large)
                    .frame(idealWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .presentationCompactAdaptation(.popover)
            }
        } else {
            button
        }
    }

    /// The explanation itself, shared by the popover and the inline fallback.
    private func explanationText(_ kind: Explanation, friend: Friend) -> some View {
        let name = friend.displayName
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Text(kind == .unsupported ? "Why is on-demand refresh unsupported?" : "Why didn't they respond?")
                .font(.headline)
            Group {
                switch kind {
                case .unsupported where friend.device?.platform != .ios:
                    Text("\(name)’s phone reported that it can’t answer on-demand requests right now. They can open Family Locator and check Live Requests and location access.")
                    Text("The map can still show their last published location.")
                case .unsupported:
                    Text("\(name)'s iPhone isn't listening for requests right now. Zood's servers can't wake an iPhone, so the app has to stay running in the background to hear one. That stops if **Live Requests** is off, or if the app was swiped closed.")
                    Text("Their location still updates on its own whenever they move. Refresh comes back once \(name) opens the app (and turns on Live Requests with location access **Always** if it's off).")
                case .noResponse:
                    Text("Requests only reach phones that currently have the app running in the background. \(name)'s phone may be offline, in Low Power Mode, or the app may have been swiped closed.")
                    Text("Their location will still update the next time they move or open the app.")
                }
            }
            .font(.subheadline)
            // Primary text: secondary gray is too faint on a translucent popover.
        }
    }

    /// iOS 15–16.3: the explanation opens inline under the actions, with its own close button.
    private func explanationTile(_ kind: Explanation, friend: Friend) -> some View {
        explanationText(kind, friend: friend)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { explanation = nil }
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(Color.cardSecondary)
                        .frame(minWidth: 30, minHeight: 30)
                }
                .accessibilityLabel("Close")
            }
            .padding(Spacing.large)
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
        item.name = friend.displayName
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

/// The username expands in place, keeping the other friend actions available.
/// The ⋯ menu as a UIKit button + UIMenu: the system menu, with its Liquid Glass look and placement. SwiftUI's `Menu`
/// refreshes its open popup whenever the surrounding view updates (new location, reconnect, …), which made items
/// flash; a UIMenu only changes when we replace it, which we do only when its items change.
private struct FriendMenu: UIViewRepresentable {
    let linked: Bool
    let username: String
    let linkContact: () -> Void
    let viewSafetyNumber: () -> Void
    let remove: () -> Void
    let block: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: panelIconConfig), for: .normal)
        button.tintColor = UIColor(Color.zoodBlueDark)
        button.showsMenuAsPrimaryAction = true
        if #available(iOS 16, *) { button.preferredMenuElementOrder = .fixed }
        button.accessibilityLabel = String(localized: "More")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.linkContact = linkContact
        coordinator.viewSafetyNumber = viewSafetyNumber
        coordinator.remove = remove
        coordinator.block = block

        // Rebuild only when something shown changes, so an open menu never flashes.
        let signature = "\(linked)|\(username)"
        guard coordinator.builtFor != signature else { return }
        coordinator.builtFor = signature

        var items: [UIMenuElement] = []
        items.append(UIAction(title: String(localized: "Remove & Block"), image: UIImage(systemName: "hand.raised"), attributes: .destructive) { [weak coordinator] _ in
            coordinator?.block?()
        })
        items.append(UIAction(title: String(localized: "Remove Friend"), image: UIImage(systemName: "person.crop.circle.badge.minus"), attributes: .destructive) { [weak coordinator] _ in
            coordinator?.remove?()
        })
        items.append(UIAction(title: String(localized: "View Safety Number"), image: UIImage(systemName: "lock.shield")) { [weak coordinator] _ in
            coordinator?.viewSafetyNumber?()
        })
        // One item rather than a submenu: a UIKit submenu puts its chevron on the leading side and indents the
        // menu for it. The handle shows underneath; tapping copies it.
        let handle = "@\(username)"
        items.append(UIAction(title: String(localized: "View Username"), subtitle: handle, image: UIImage(systemName: "at")) { _ in
            UIPasteboard.general.string = handle
        })
        items.append(UIAction(title: String(localized: linked ? "Linked Contact" : "Link Contact"),
                              image: UIImage(systemName: "person.crop.circle.badge.plus")) { [weak coordinator] _ in
            coordinator?.linkContact?()
        })
        // iOS 16+ keeps this order (`.fixed`); iOS 15 lists a menu from the button outward, so reverse it there.
        if #unavailable(iOS 16) { items.reverse() }
        button.menu = UIMenu(children: items)
    }

    final class Coordinator {
        var builtFor: String?
        var linkContact: (() -> Void)?
        var viewSafetyNumber: (() -> Void)?
        var remove: (() -> Void)?
        var block: (() -> Void)?
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
