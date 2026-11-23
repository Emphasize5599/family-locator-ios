import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    @State private var mapCommand: MapCommand?
    /// The friend whose card is showing above the friend bar (an inline card, not a sheet, so the bar stays usable).
    @State private var selectedFriendID: Data?
    @State private var activeSheet: ActiveSheet?
    /// Friend-bar folders that are open (showing their members inline).
    @State private var expandedFolders: Set<UUID> = []
    /// The friend or folder a dragged friend is hovering over, highlighted until it's dropped.
    @State private var dropTarget: FriendBarDropTarget?
    @State private var renamingFolder: FriendFolder?
    @State private var folderName = ""

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
                FriendMapView(friends: model.friends, selectedID: selectedFriendID, command: mapCommand, onSelect: { id in
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
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } }),
               presenting: renamingFolder) { folder in
            TextField("Folder name", text: $folderName)
            Button("Save") { model.renameFolder(folder.id, to: folderName) }
            Button("Cancel", role: .cancel) {}
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
            if ["friend", "friend-short-name", "friend-long-name", "friend-updated", "friend-unsupported"].contains(ScreenshotTour.scene ?? ""), let friend = model.friends.first { select(friend) }
            if ScreenshotTour.scene == "map-folders-open" { expandedFolders = Set(model.friendFolders.map(\.id)) }
            // Overlapping pins: open a friend from the middle of the stack; their pin should come to the front.
            if ScreenshotTour.scene == "friend-overlap", let friend = model.friends.first(where: { $0.nickname == "Devon" }) { select(friend) }
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

                // Folders first, then everyone who isn't in one.
                ForEach(model.friendFolders) { folder in
                    folderItem(folder)
                }
                ForEach(model.ungroupedFriends) { friend in
                    friendItem(friend, inFolder: false)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
            // Dropping a folder member on an empty part of the bar takes them out of the folder.
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], delegate: FriendDropDelegate(target: .bar, hovered: $dropTarget, onDrop: handleDrop))
        }
        // A ScrollView clips to a plain rectangle, so the Add button and avatars slid over the bar's
        // rounded corners while scrolling. Clipping to the bar's own shape keeps them inside it.
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

    // MARK: Friend bar items and folders

    /// A friend in the bar. Long-press and drag to put them in a folder (see FriendBarFolders.swift).
    @ViewBuilder
    private func friendItem(_ friend: Friend, inFolder: Bool) -> some View {
        let hovered = dropTarget == .friend(friend.id)
        let item = Button {
            select(friend)
        } label: {
            VStack(spacing: Spacing.tight) {
                AvatarView(username: friend.avatarName, imageData: friend.avatar, size: 52)
                    .opacity(friend.theyShare ? 1 : 0.5)
                    // Ring and a little lift while another friend hovers here: dropping makes a folder.
                    .overlay(Circle().stroke(Color.zoodBlue, lineWidth: 3).opacity(hovered ? 1 : 0))
                    .scaleEffect(hovered ? 1.1 : 1)
                    .animation(.easeOut(duration: 0.15), value: hovered)
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
        .onDrag { FriendDrag.provider(for: friend.id) }
        .onDrop(of: [.plainText], delegate: FriendDropDelegate(target: .friend(friend.id), hovered: $dropTarget, onDrop: handleDrop))
        .id(friend.id)

        if inFolder {
            // Also reachable without dragging (and by VoiceOver).
            item
                .contextMenu {
                    Button {
                        model.removeFromFolder(friend.id)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                }
                .accessibilityAction(named: Text("Remove from Folder")) { model.removeFromFolder(friend.id) }
        } else {
            item
        }
    }

    /// A folder: a tile of its members' avatars. Tap to open it and show the members inline, inside a tinted group.
    private func folderItem(_ folder: FriendFolder) -> some View {
        let members = folder.members.compactMap { model.local.friends[$0] }
        let expanded = expandedFolders.contains(folder.id)
        let hovered = dropTarget == .folder(folder.id)
        let title = folder.name ?? String(localized: "Folder")
        return HStack(spacing: Spacing.large) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if expanded { expandedFolders.remove(folder.id) } else { expandedFolders.insert(folder.id) }
                }
            } label: {
                VStack(spacing: Spacing.tight) {
                    Group {
                        if expanded {
                            Image(systemName: "folder.fill")
                                .font(.title2)
                                .foregroundStyle(Color.zoodBlueDark)
                                .frame(width: 52, height: 52)
                                .background(Color.zoodBlue.opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            FolderTile(members: members)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.zoodBlue, lineWidth: 3).opacity(hovered ? 1 : 0))
                    .scaleEffect(hovered ? 1.1 : 1)
                    .animation(.easeOut(duration: 0.15), value: hovered)
                    Text(title)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 64)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(title), folder of \(members.count)"))
            .accessibilityHint(expanded ? Text("Closes the folder") : Text("Shows who's in it"))
            .onDrop(of: [.plainText], delegate: FriendDropDelegate(target: .folder(folder.id), hovered: $dropTarget, onDrop: handleDrop))
            .contextMenu {
                if #available(iOS 16, *) {
                    Button {
                        folderName = folder.name ?? ""
                        renamingFolder = folder
                    } label: {
                        Label("Rename Folder", systemImage: "pencil")
                    }
                }
                Button(role: .destructive) {
                    expandedFolders.remove(folder.id)
                    model.ungroupFolder(folder.id)
                } label: {
                    Label("Ungroup", systemImage: "folder.badge.minus")
                }
            }

            if expanded {
                ForEach(members) { friend in
                    friendItem(friend, inFolder: true)
                }
            }
        }
        // The open folder's members sit on a tinted group that reaches just past them, without moving the layout.
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.zoodBlue.opacity(expanded ? 0.15 : 0))
                .padding(.horizontal, -Spacing.small)
                .padding(.vertical, -Spacing.tight)
        )
    }

    private func handleDrop(_ friendID: Data, on target: FriendBarDropTarget) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            switch target {
            case .friend(let other):
                model.groupFriend(friendID, with: other)
            case .folder(let folderID):
                model.moveFriend(friendID, toFolder: folderID)
            case .bar:
                if model.folder(containing: friendID) != nil { model.removeFromFolder(friendID) }
            }
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
