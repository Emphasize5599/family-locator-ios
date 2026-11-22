import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    @State private var mapCommand: MapCommand?
    /// The friend whose card is showing above the friend bar (an inline card, not a sheet, so the bar stays usable).
    @State private var selectedFriendID: Data?
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable, Equatable {
        case addFriend
        case settings

        var id: Self { self }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            FriendMapView(friends: model.friends, command: mapCommand, onSelect: { id in
                if let friend = model.local.friends[id] { select(friend) }
            }, onBackgroundTap: {
                closeFriend()
            })
            .ignoresSafeArea()

            VStack(spacing: 10) {
                if !model.isConnected {
                    banner("Connecting to server…", systemImage: "wifi.exclamationmark")
                } else if !model.location.hasAnyPermission {
                    banner("Location access is off, so family can't see you.", systemImage: "location.slash")
                        .onTapGesture { model.location.requestPermission() }
                }
                if let id = selectedFriendID, model.local.friends[id] != nil {
                    FriendPanel(friendID: id, onClose: closeFriend)
                        .id(id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                friendsBar
            }
            .padding(.bottom, 8)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedFriendID)
        }
        .overlay(alignment: .topTrailing) { controls }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addFriend:
                AddFriendView().environmentObject(model)
            case .settings:
                SettingsView().environmentObject(model)
            }
        }
        // Close a friend's card if they're removed (by us or from another device).
        .compatOnChange(of: model.local.friends.keys.count) { _ in
            if let id = selectedFriendID, model.local.friends[id] == nil { selectedFriendID = nil }
        }
        .onAppear { model.location.requestPermission() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            circleButton("gearshape.fill", label: "Settings") { activeSheet = .settings }
            circleButton("location.fill", label: "My location") {
                mapCommand = MapCommand(kind: .followUser)
            }
        }
        .padding()
    }

    private func circleButton(_ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .foregroundStyle(Color.zoodNavy)
        }
        .accessibilityLabel(Text(label))
    }

    // MARK: Friends bar

    private var friendsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button {
                    activeSheet = .addFriend
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 52, height: 52)
                            .background(Color.zoodBlue, in: Circle())
                            .foregroundStyle(.white)
                        Text("Add").font(.caption)
                    }
                }
                .buttonStyle(.plain)

                ForEach(model.friends) { friend in
                    Button {
                        select(friend)
                    } label: {
                        VStack(spacing: 4) {
                            AvatarView(username: friend.user.username, imageData: friend.avatar, size: 52)
                                .opacity(friend.theyShare ? 1 : 0.5)
                            Text(friend.user.username)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: 64)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(friend.user.username)
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func banner(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
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
