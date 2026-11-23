import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    @State private var mapCommand: MapCommand?
    /// The friend whose card is showing above the friend bar (an inline card, not a sheet, so the bar stays usable).
    @State private var selectedFriendID: Data?
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable, Equatable {
        case addFriend
        case requests
        case settings
        case timedShare

        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                FriendMapView(friends: model.friends, command: mapCommand, onSelect: { id in
                    if let friend = model.local.friends[id] { select(friend) }
                }, onBackgroundTap: {
                    closeFriend()
                })
                .ignoresSafeArea()

                VStack(spacing: Spacing.medium) {
                    if !model.isConnected {
                        banner("Connecting to server…", systemImage: "wifi.exclamationmark")
                    } else if !model.location.hasAnyPermission {
                        banner("Location access is off, so family can't see you.", systemImage: "location.slash")
                            .onTapGesture { model.location.requestPermission() }
                    }
                    BackgroundRefreshView()
                        .padding(.horizontal, Spacing.medium)
                    if let id = selectedFriendID, model.local.friends[id] != nil {
                        FriendPanel(friendID: id, maxHeight: geometry.size.height * 0.65, onClose: closeFriend)
                            .id(id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.timedShare != nil {
                        // Running: a status strip instead of the button (Android's "peeking" sheet).
                        TimedSharePeekBar { activeSheet = .timedShare }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if selectedFriendID == nil {
                        // Android's location-pin button, bottom right above the friend bar.
                        HStack {
                            Spacer()
                            circleButton("mappin.and.ellipse", label: "Timed sharing") { activeSheet = .timedShare }
                        }
                        .padding(.horizontal, Spacing.large)
                        .transition(.opacity)
                    }
                    friendsBar
                }
                .padding(.bottom, Spacing.small)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedFriendID)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.timedShare != nil)
            }
        }
        .overlay(alignment: .topTrailing) { controls }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addFriend:
                AddFriendView().environmentObject(model)
            case .requests:
                RequestsView().environmentObject(model)
            case .settings:
                SettingsView().environmentObject(model)
            case .timedShare:
                TimedShareView()
                    .environmentObject(model)
            }
        }
        // Close a friend's card if they're removed (by us or from another device).
        .compatOnChange(of: model.local.friends.keys.count) { _ in
            if let id = selectedFriendID, model.local.friends[id] == nil { selectedFriendID = nil }
        }
        .alert("Could Not Save Request", isPresented: Binding(get: { model.safetyError != nil }, set: { if !$0 { model.safetyError = nil } })) {
            Button("OK") { model.safetyError = nil }
        } message: { Text(model.safetyError ?? "") }
        .onAppear {
            if !ScreenshotTour.isEnabled { model.location.requestPermission() }
            #if DEBUG
            if ScreenshotTour.isEnabled, let loc = model.friends.first?.location {
                mapCommand = MapCommand(kind: .focus(latitude: loc.latitude, longitude: loc.longitude))
            }
            if ["friend", "friend-long-name", "friend-updated", "friend-unsupported"].contains(ScreenshotTour.scene ?? ""), let friend = model.friends.first { select(friend) }
            // Screenshot/UI checks: SIMCTL_CHILD_ZOOD_OPEN_FIRST=1 opens the first friend's card at launch.
            if ProcessInfo.processInfo.environment["ZOOD_OPEN_FIRST"] == "1", let first = model.friends.first { select(first) }
            // End-to-end checks: SIMCTL_CHILD_ZOOD_START_TIMED_SHARE=1 starts a timed share and writes its link to
            // tmp/timed-share-url.txt in the app container (debug builds only; the link contains a secret key).
            if ProcessInfo.processInfo.environment["ZOOD_START_TIMED_SHARE"] == "1", model.timedShare == nil {
                try? model.startTimedShare()
                if let url = model.timedShareURL {
                    try? url.absoluteString.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("timed-share-url.txt"),
                                                  atomically: true, encoding: .utf8)
                }
            }
            switch ProcessInfo.processInfo.environment["ZOOD_TIMED_SHARE_UI"] {
            case "open": activeSheet = .timedShare
            case "stop": model.stopTimedShare()
            default: break
            }
            #endif
        }
    }

    private var controls: some View {
        VStack(spacing: Spacing.medium) {
            circleButton("gearshape.fill", label: "Settings") { activeSheet = .settings }
            circleButton("location.fill", label: "My location") {
                mapCommand = MapCommand(kind: .followUser)
            }
        }
        .padding(Spacing.large)
    }

    private func circleButton(_ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .floatingSurface(in: Circle(), interactive: true)
                .foregroundStyle(Color.floatingAccent)
        }
        .accessibilityLabel(Text(label))
    }

    // MARK: Friends bar

    private var friendsBar: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.large) {
                Button {
                    activeSheet = .addFriend
                } label: {
                    VStack(spacing: Spacing.tight) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(Color.zoodBlue, in: Circle())
                            .foregroundStyle(.white)
                        Text("Add").font(.caption)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .requests
                } label: {
                    VStack(spacing: Spacing.tight) {
                        Image(systemName: model.safety.pending.isEmpty ? "bell" : "bell.badge.fill")
                            .font(.title2.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(Color.zoodBlue, in: Circle())
                            .foregroundStyle(.white)
                        Text("Requests (\(model.safety.pending.count))").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pending requests, \(model.safety.pending.count)")

                ForEach(model.friends) { friend in
                    Button {
                        select(friend)
                    } label: {
                        VStack(spacing: Spacing.tight) {
                            AvatarView(username: friend.avatarName, imageData: friend.avatar, size: 52)
                                .opacity(friend.theyShare ? 1 : 0.5)
                            Text(friend.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: 64)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(friend.displayName)
                    .accessibilityAddTraits(.isButton)
                }
            }
            // Matches the edge fade below, so nothing is faded until it actually scrolls toward an edge.
            .padding(.horizontal, Spacing.xLarge)
            .padding(.vertical, Spacing.medium)
        }
        // A ScrollView clips to a plain rectangle, so the Add button and avatars slid over the bar's
        // rounded corners while scrolling. Fade them out across the corner radius at each end instead,
        // so they're gone before they reach the curve, then clip to the bar's shape as a backstop.
        .mask(edgeFade(width: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #if DEBUG
        // Tour check: start scrolled partway, so buttons sit under the bar's rounded corners.
        .onAppear {
            if ScreenshotTour.scene == "map-many-friends", let middle = model.friends.dropFirst(2).first {
                proxy.scrollTo(middle.id, anchor: .center)
            }
        }
        #endif
        }
        .floatingSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, Spacing.medium)
    }

    /// Opaque in the middle, fading to clear over `width` points at the left and right edges.
    private func edgeFade(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
        }
    }

    private func banner(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .floatingSurface(in: Capsule())
    }

    // MARK: Selection

    private func closeFriend() {
        selectedFriendID = nil
    }

    private func select(_ friend: Friend) {
        // Tapping the friend that's already open closes their card, like Android.
        if selectedFriendID == friend.id {
            closeFriend()
            return
        }
        selectedFriendID = friend.id
        if let loc = friend.location {
            mapCommand = MapCommand(kind: .focus(latitude: loc.latitude, longitude: loc.longitude))
        }
    }
}
