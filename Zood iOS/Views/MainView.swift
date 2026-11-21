import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    @State private var mapCommand: MapCommand?
    @State private var selectedFriendID: Data?
    @State private var showingAddFriend = false
    @State private var showingSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            FriendMapView(friends: model.friends, command: mapCommand) { id in
                if let friend = model.local.friends[id] { select(friend) }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                if !model.isConnected {
                    banner("Connecting to server…", systemImage: "wifi.exclamationmark")
                } else if !model.location.hasAnyPermission {
                    banner("Location access is off, so family can't see you.", systemImage: "location.slash")
                        .onTapGesture { model.location.requestPermission() }
                }
                friendsBar
            }
            .padding(.bottom, 8)
        }
        .overlay(alignment: .topTrailing) { controls }
        .sheet(item: selectedFriendBinding) { friend in
            FriendPanel(friendID: friend.id)
                .environmentObject(model)
                .friendSheetPresentation()
        }
        .sheet(isPresented: $showingAddFriend) { AddFriendView().environmentObject(model) }
        .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(model) }
        .onAppear { model.location.requestPermission() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            circleButton("gearshape.fill", label: "Settings") { showingSettings = true }
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
                    showingAddFriend = true
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

    private func select(_ friend: Friend) {
        selectedFriendID = friend.id
        if let loc = friend.location {
            mapCommand = MapCommand(kind: .focus(latitude: loc.latitude, longitude: loc.longitude))
        }
    }

    private var selectedFriendBinding: Binding<Friend?> {
        Binding(
            get: { selectedFriendID.flatMap { model.local.friends[$0] } },
            set: { selectedFriendID = $0?.id }
        )
    }
}
