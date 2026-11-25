import SwiftUI
import UniformTypeIdentifiers

/// The main screen: the map of friends, the friend bar along the bottom (people, folders, Requests and Add) and
/// the friend card for whoever is selected.
struct MainView: View {
    @EnvironmentObject private var model: AppModel

    @State private var mapCommand: MapCommand?
    @State private var mapHeading = 0.0
    /// The friend whose card is showing above the friend bar (an inline card, not a sheet, so the bar stays usable).
    @State private var selectedFriendID: Data?
    @State private var nicknameDraft: FriendNicknameDraft?
    @State private var activeSheet: ActiveSheet?
    /// A username to fill in when Add Friend opens from a friend link.
    @State private var addFriendPrefill: String?
    /// The friend or folder being dragged around the bar (see FriendBarFolders.swift).
    @State private var dragging: BarItemID?
    /// The item a dragged friend is held over, showing "let go to make a folder".
    @State private var folderTarget: BarItemID?
    /// The folder open above the bar.
    @State private var openFolderID: UUID?
    @AppStorage(FolderGrid.columnsKey) private var folderColumns = FolderGrid.defaultColumns
    @AppStorage(FolderGrid.rowsKey) private var folderRows = FolderGrid.defaultRows
    @State private var renamingFolderID: UUID?
    @State private var confirmingUngroup: FriendFolder?
    /// Where the open folder's tile sits horizontally on screen, so its card can open centered above it.
    @State private var openFolderTileMidX: CGFloat?
    /// The friend bar's height, so an open folder can float just above it.
    @State private var barHeight: CGFloat = 100
    @State private var folderName = ""

    private static let screenSpace = "main-screen"

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
                    if let friend = model.local.friends[id] { select(friend, fromPin: true) }
                }, onBackgroundTap: {
                    closeFriend()
                    closeFolder()
                }, onHeadingChanged: { mapHeading = $0 })
                .ignoresSafeArea()

                controls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                VStack(spacing: Spacing.medium) {
                    if !model.isConnected {
                        banner("Connecting to server…", systemImage: "wifi.exclamationmark")
                    } else if !model.location.hasAnyPermission && !ScreenshotTour.isStoreScene {
                        banner("Location access is off, so family can't see you.", systemImage: "location.slash")
                            .onTapGesture { model.location.requestPermission() }
                    }
                    BackgroundRefreshView()
                        .padding(.horizontal, Spacing.medium)
                    if let id = selectedFriendID, model.local.friends[id] != nil {
                        FriendPanel(friendID: id, nicknameDraft: $nicknameDraft,
                                    maxHeight: geometry.size.height * 0.65, onClose: closeFriend)
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
                        .zIndex(1)  // the open folder below draws above the friend card
                        // An open folder floats over the map just above the bar, layered on top like the
                        // friend card, so nothing else on screen moves when it opens.
                        .background(GeometryReader { bar in
                            Color.clear
                                .onAppear { barHeight = bar.size.height }
                                .compatOnChange(of: bar.size.height) { barHeight = $0 }
                        })
                        .overlay(alignment: .bottom) {
                            if let folder = model.friendFolders.first(where: { $0.id == openFolderID }) {
                                folderPopup(folder, screenWidth: geometry.size.width, availableHeight: geometry.size.height)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, barHeight + Spacing.medium)
                                    // Grows out of (and shrinks back into) the folder's tile in the bar.
                                    .transition(.scale(scale: 0.2, anchor: folderAnchor(folder, screenWidth: geometry.size.width))
                                        .combined(with: .opacity))
                            }
                        }
                }
                .padding(.bottom, Spacing.small)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: openFolderID)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedFriendID)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.timedShare != nil)
            }
            .coordinateSpace(name: Self.screenSpace)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addFriend:
                AddFriendView(prefill: addFriendPrefill).environmentObject(model)
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
            if let id = selectedFriendID, model.local.friends[id] == nil { closeFriend() }
        }
        .alert(Text("Ungroup \u{201C}\(confirmingUngroup?.name ?? String(localized: "Folder"))\u{201D}?"),
                            isPresented: Binding(get: { confirmingUngroup != nil }, set: { if !$0 { confirmingUngroup = nil } }),
                            presenting: confirmingUngroup) { folder in
            Button("Cancel", role: .cancel) {}
            Button("Ungroup", role: .destructive) {
                closeFolder()
                withAnimation { model.ungroupFolder(folder.id) }
            }
        } message: { _ in
            Text("Everyone in it goes back to the bar. Nobody is removed as a friend.")
        }
        .alert("Could Not Save Request", isPresented: Binding(get: { model.safetyError != nil }, set: { if !$0 { model.safetyError = nil } })) {
            Button("OK") { model.safetyError = nil }
        } message: { Text(model.safetyError ?? "") }
        .onAppear { showPendingFriendLink() }
        .compatOnChange(of: model.pendingFriendLink) { _ in showPendingFriendLink() }
        .compatOnChange(of: activeSheet) { sheet in if sheet == nil { addFriendPrefill = nil } }
        .onAppear {
            if !ScreenshotTour.isEnabled { model.location.requestPermission() }
            #if DEBUG
            if ScreenshotTour.isEnabled, let loc = model.friends.first?.location {
                mapCommand = MapCommand(kind: .focus(latitude: loc.latitude, longitude: loc.longitude))
            }
            if let scenario = ScreenshotTour.scene.flatMap(StoreTourScene.init(rawValue:)) {
                if scenario.opensFriend, let friend = model.friends.first { select(friend) }
                if scenario == .westminster { openFolderID = model.friendFolders.first?.id }
            }
            if ["friend", "friend-short-name", "friend-two-line-name", "friend-long-name", "friend-updated", "friend-unsupported", "friend-contact-photo", "friend-nickname"].contains(ScreenshotTour.scene ?? ""), let friend = model.friends.first { select(friend) }
            if ScreenshotTour.scene == "friend-nickname-scroll", let friend = model.friends.last { select(friend) }
            if ScreenshotTour.scene?.hasPrefix("map-folders-open") == true { openFolderID = model.friendFolders.first?.id }
            if ScreenshotTour.scene == "map-folders-open-rename", let folder = model.friendFolders.first {
                beginRename(folder)
                folderName = "Grandparents and cousins visiting this weekend"
            }
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
        #if DEBUG
        .task(id: selectedFriendID) {
            guard ScreenshotTour.scene == "friend-nickname-scroll" else { return }
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            nicknameDraft?.text = "River"
        }
        #endif
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: Spacing.medium) {
            HStack(spacing: Spacing.medium) {
                if abs(mapHeading.remainder(dividingBy: 360)) > 1 {
                    circleButton(label: "Reset map orientation to north") {
                        mapCommand = MapCommand(kind: .northUp)
                    } content: {
                        ZStack {
                            Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                                .padding(4)
                            VStack(spacing: 1) {
                                Image(systemName: "triangle.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.red)
                                Text("N")
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.primary)
                            }
                            .offset(y: -2)
                            .rotationEffect(.degrees(-mapHeading))
                        }
                    }
                }
                circleButton("gearshape.fill", label: "Settings") { activeSheet = .settings }
            }
            circleButton("location.fill", label: "My location") {
                mapCommand = MapCommand(kind: .followUser)
            }
        }
        .padding(Spacing.large)
    }

    private func circleButton(_ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        circleButton(label: label, action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.floatingAccent)
        }
    }

    private func circleButton<Content: View>(label: LocalizedStringKey, action: @escaping () -> Void,
                                             @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(width: 48, height: 48)
                .floatingSurface(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .accessibilityLabel(Text(label))
    }

    // MARK: Friends bar

    private var friendsBar: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.large) {
                // People come first, then the divider, Requests and Add.
                // People and folders, in the order you've arranged them.
                ForEach(model.barItems) { item in
                    switch item {
                    case .friend(let friend): friendItem(friend)
                    case .folder(let folder): folderItem(folder)
                    }
                }

                // A thin line between your people and the app's own buttons. Everything still scrolls together.
                Capsule()
                    .fill(Color.cardSecondary.opacity(0.4))
                    .frame(width: 1, height: 44)
                    .padding(.bottom, Spacing.large)
                    .accessibilityHidden(true)

                Button {
                    activeSheet = .requests
                } label: {
                    VStack(spacing: Spacing.tight) {
                        // A red dot on the bell (like Android's) says a request is waiting; the label stays short.
                        Group {
                            if model.safety.visibleRequests.isEmpty {
                                Image(systemName: "bell").foregroundStyle(.white)
                            } else {
                                // The badge layer comes first: a red dot on a white bell.
                                Image(systemName: "bell.badge.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.zoodRed, Color.white)
                            }
                        }
                        .font(.title2.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(Color.zoodBlue, in: Circle())
                        Text("Requests").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.safety.visibleRequests.isEmpty ? Text("Requests") : Text("Requests, \(model.safety.visibleRequests.count) waiting"))

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
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.medium)
            // Dropping a folder member on an empty part of the bar takes them out of the folder.
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], delegate: BarItemDropDelegate(target: nil, model: model,
                                                                    dragging: $dragging, folderTarget: $folderTarget))
        }
        // A ScrollView clips to a plain rectangle, so the Add button and avatars slid over the bar's
        // rounded corners while scrolling. Clipping to the bar's own shape keeps them inside it.
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .compatOnChange(of: renamingFolderID) { id in
            if let id { proxy.scrollTo(id) }
        }
        .compatOnChange(of: nicknameDraft != nil) { editing in
            guard editing, let id = selectedFriendID,
                  model.barItems.contains(where: { $0.id == .friend(id) }) else { return }
            withAnimation { proxy.scrollTo(id) }
        }
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

    /// Tap a person to open or close their card; long-press to move them or make a folder.
    private func friendItem(_ friend: Friend) -> some View {
        let id = BarItemID.friend(friend.id)
        let isFolderTarget = folderTarget == id
        let preview = selectedFriendID == friend.id ? nicknameDraft?.preview(for: friend) ?? friend : friend
        return Button {
            toggleFriend(friend)
        } label: {
            VStack(spacing: Spacing.tight) {
                AvatarView(username: preview.avatarName, imageData: preview.displayAvatar, size: 52)
                    .opacity(friend.theyShare ? 1 : 0.5)
                    // While someone is held over the middle, a ring and a little growth say "let go to make a folder".
                    .overlay(Circle().stroke(Color.zoodBlue, lineWidth: 3).opacity(isFolderTarget ? 1 : 0))
                    .scaleEffect(isFolderTarget ? 1.12 : 1)
                    .animation(.easeOut(duration: 0.15), value: isFolderTarget)
                Text(preview.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: barItemWidth)
            // Like the Home Screen: the lifted item's spot is empty, and everything else jiggles.
            .opacity(dragging == id ? 0 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Move Left")) { model.nudgeBarItem(id, by: -1) }
        .accessibilityAction(named: Text("Move Right")) { model.nudgeBarItem(id, by: 1) }
        .contentShape(.dragPreview, Circle())
        .onDrag({
            dragging = id
            closeFolder()
            BarHaptics.lift()
            return barDragProvider { if dragging == id { dragging = nil; folderTarget = nil } }
        }, preview: {
            BarDragPreview(shape: Circle()) {
                AvatarView(username: friend.avatarName, imageData: friend.displayAvatar, size: 64)
            }
        })
        .onDrop(of: [.plainText], delegate: BarItemDropDelegate(target: id, model: model,
                                                                dragging: $dragging, folderTarget: $folderTarget))
        .id(friend.id)
    }

    /// A folder in the bar: a tile of its members. Tap to open it above the bar; drag it to move it.
    private func folderItem(_ folder: FriendFolder) -> some View {
        let id = BarItemID.folder(folder.id)
        let members = folder.members.compactMap { model.local.friends[$0] }
        let title = (renamingFolderID == folder.id ? Nickname.normalized(folderName) : folder.name)
            ?? String(localized: "Folder")
        let isFolderTarget = folderTarget == id
        return Button {
            if openFolderID == folder.id { closeFolder() } else { openFolder(folder.id) }
        } label: {
            VStack(spacing: Spacing.tight) {
                FolderTile(members: members)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.zoodBlue, lineWidth: 3).opacity(isFolderTarget || openFolderID == folder.id ? 1 : 0))
                    .scaleEffect(isFolderTarget ? 1.12 : 1)
                    .animation(.easeOut(duration: 0.15), value: isFolderTarget)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: barItemWidth)
            .opacity(dragging == id ? 0 : 1)
            // The tile's position is read once, when the folder opens, to place its card; the card then stays
            // put. If the tile moves while the folder is open, the bar is being scrolled, so the folder closes.
            .background(GeometryReader { tile in
                let midX = tile.frame(in: .named(Self.screenSpace)).midX
                Color.clear
                    .onAppear { if openFolderID == folder.id { openFolderTileMidX = midX } }
                    .compatOnChange(of: openFolderID) { open in if open == folder.id { openFolderTileMidX = midX } }
                    .compatOnChange(of: midX) { x in
                        guard openFolderID == folder.id else { return }
                        if renamingFolderID == folder.id { openFolderTileMidX = x }
                        else if let opened = openFolderTileMidX, abs(x - opened) > 2 { closeFolder() }
                    }
            })
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title), folder of \(members.count)"))
        .accessibilityHint(Text("Opens the folder"))
        .accessibilityAction(named: Text("Move Left")) { model.nudgeBarItem(id, by: -1) }
        .accessibilityAction(named: Text("Move Right")) { model.nudgeBarItem(id, by: 1) }
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrag({
            dragging = id
            closeFolder()
            BarHaptics.lift()
            return barDragProvider { if dragging == id { dragging = nil; folderTarget = nil } }
        }, preview: {
            BarDragPreview(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) { FolderTile(members: members, size: 64) }
        })
        .onDrop(of: [.plainText], delegate: BarItemDropDelegate(target: id, model: model,
                                                                dragging: $dragging, folderTarget: $folderTarget))
        .contextMenu { folderActions(folder) }
        .id(folder.id)
    }

    /// Ungroup first, then Rename Folder: the same order as the friend card's ⋯ menu, which leads with its
    /// destructive actions. Ungroup always asks for confirmation.
    @ViewBuilder
    private func folderActions(_ folder: FriendFolder) -> some View {
        Button(role: .destructive) {
            confirmingUngroup = folder
        } label: {
            Label("Ungroup", systemImage: "folder.badge.minus")
        }
        Button { beginRename(folder) } label: {
            Label("Rename Folder", systemImage: "pencil")
        }
    }

    private func folderMenuActions(_ folder: FriendFolder) -> [PanelMenuAction] {
        [
            PanelMenuAction(title: String(localized: "Ungroup"), systemImage: "folder.badge.minus", destructive: true) {
                confirmingUngroup = folder
            },
            PanelMenuAction(title: String(localized: "Rename Folder"), systemImage: "pencil") {
                beginRename(folder)
            }
        ]
    }

    private func beginRename(_ folder: FriendFolder) {
        openFolder(folder.id)
        renamingFolderID = folder.id
        folderName = folder.name ?? ""
    }

    private func saveFolderName(_ folder: FriendFolder) {
        model.renameFolder(folder.id, to: folderName)
        renamingFolderID = nil
    }

    /// An open folder, floating above the bar like the ⋯ menu: its members in a grid (3×3 by default, set in
    /// Settings). Bigger folders scroll. Tap someone to open their card; drag to rearrange or to take them out.
    ///
    /// The card is as wide as its grid needs, and opens centered above the folder's tile; near either edge it
    /// stops at the screen margin instead.
    /// Centered over the folder's tile, or pinned to the screen margin when the tile is near an edge.
    private func folderCenterX(width: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let margin = Spacing.medium
        let tileX = openFolderTileMidX ?? screenWidth / 2
        return min(max(tileX, margin + width / 2), screenWidth - margin - width / 2)
    }

    /// The folder tile's position in the card's own (unshifted) frame, as the point the card grows from.
    private func folderAnchor(_ folder: FriendFolder, screenWidth: CGFloat) -> UnitPoint {
        let width = folderCardWidth(folder, screenWidth: screenWidth)
        let tileX = openFolderTileMidX ?? screenWidth / 2
        // The card is laid out centered on screen, then shifted by an offset; the scale's anchor is in the
        // unshifted frame, so subtract the frame's left edge.
        let frameLeft = (screenWidth - width) / 2
        return UnitPoint(x: (tileX - frameLeft) / width, y: 1)
    }

    private func folderCardWidth(_ folder: FriendFolder, screenWidth: CGFloat) -> CGFloat {
        let members = folder.members.compactMap { model.local.friends[$0] }
        let columns = min(max(folderColumns, FolderGrid.columnRange.lowerBound), FolderGrid.columnRange.upperBound)
        let usedColumns = max(1, min(columns, members.count))
        let gridWidth = CGFloat(usedColumns) * barItemWidth + CGFloat(usedColumns - 1) * Spacing.large
        let editing = renamingFolderID == folder.id
        let title = editing
            ? (folderName.isEmpty ? String(localized: "Folder name") : folderName)
            : folder.name ?? String(localized: "Folder")
        let font = UIFont.preferredFont(forTextStyle: .headline)
        let titleWidth = title.components(separatedBy: .newlines)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let headerWidth = ceil(titleWidth) + 2 + 3 * Spacing.tight + Spacing.small + 2 * 44
        return min(max(gridWidth, headerWidth, 140) + 2 * Spacing.large, screenWidth - 2 * Spacing.medium)
    }

    private func folderPopup(_ folder: FriendFolder, screenWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let members = folder.members.compactMap { model.local.friends[$0] }
        let columns = min(max(folderColumns, FolderGrid.columnRange.lowerBound), FolderGrid.columnRange.upperBound)
        let rows = min(max(folderRows, FolderGrid.rowRange.lowerBound), FolderGrid.rowRange.upperBound)
        let usedColumns = max(1, min(columns, members.count))
        let cellHeight: CGFloat = 76
        let visibleRows = min(rows, max(1, Int(ceil(Double(members.count) / Double(columns)))))
        // Room above and below each row so the avatars' rings are never clipped by the scrolling area.
        let gridInset = Spacing.tight
        let gridHeight = CGFloat(visibleRows) * cellHeight + CGFloat(visibleRows - 1) * Spacing.large + 2 * gridInset
        let gridWidth = CGFloat(usedColumns) * barItemWidth + CGFloat(usedColumns - 1) * Spacing.large
        let editing = renamingFolderID == folder.id
        let title = folder.name ?? String(localized: "Folder")
        let width = folderCardWidth(folder, screenWidth: screenWidth)
        let centerX = folderCenterX(width: width, screenWidth: screenWidth)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .center, spacing: Spacing.tight) {
                if editing {
                    InlineNameField(label: String(localized: "Folder name"), text: $folderName,
                                    style: .headline, onSave: { saveFolderName(folder) }, onCancel: { renamingFolderID = nil })
                } else {
                    Button { beginRename(folder) } label: {
                        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Rename Folder")
                }
                Spacer(minLength: Spacing.small)
                PanelMenuButton(accessibilityLabel: String(localized: "Folder options"), actions: folderMenuActions(folder))
                    .frame(width: 44, height: 44)
                CloseButton { closeFolder() }.frame(width: 44, height: 44)
            }
            if editing {
                InlineNameActions(onSave: { saveFolderName(folder) }, onCancel: { renamingFolderID = nil })
            }
            ScrollView(.vertical, showsIndicators: members.count > columns * rows) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(barItemWidth), spacing: Spacing.large), count: usedColumns),
                          spacing: Spacing.large) {
                    ForEach(members) { friend in
                        folderMember(friend, in: folder)
                    }
                }
                .padding(.vertical, gridInset)
                .frame(width: gridWidth)  // a grid offered more room centers its columns; keep it to its own width
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: editing ? min(gridHeight, max(60, availableHeight * 0.38)) : gridHeight)
        }
        .padding(Spacing.large)
        .frame(width: width)
        .floatingSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        // Drop anyone onto the open folder to add them.
        .onDrop(of: [.plainText], delegate: FolderGridDropDelegate(folderID: folder.id, member: nil, model: model, dragging: $dragging))
        .offset(x: centerX - screenWidth / 2)
    }

    private func folderMember(_ friend: Friend, in folder: FriendFolder) -> some View {
        Button {
            toggleFriend(friend)
        } label: {
            VStack(spacing: Spacing.tight) {
                AvatarView(username: friend.avatarName, imageData: friend.displayAvatar, size: 52)
                    .opacity(friend.theyShare ? 1 : 0.5)
                Text(friend.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: barItemWidth)
            .opacity(dragging == .friend(friend.id) ? 0 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(friend.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Remove from Folder")) { model.removeFromFolder(friend.id) }
        .contextMenu {
            Button {
                model.removeFromFolder(friend.id)
            } label: {
                Label("Remove from Folder", systemImage: "folder.badge.minus")
            }
        }
        // The folder stays open while you rearrange inside it; drag onto the bar to take someone out.
        .contentShape(.dragPreview, Circle())
        .onDrag({
            dragging = .friend(friend.id)
            BarHaptics.lift()
            return barDragProvider { if dragging == .friend(friend.id) { dragging = nil } }
        }, preview: {
            BarDragPreview(shape: Circle()) {
                AvatarView(username: friend.avatarName, imageData: friend.displayAvatar, size: 64)
            }
        })
        .onDrop(of: [.plainText], delegate: FolderGridDropDelegate(folderID: folder.id, member: friend.id, model: model, dragging: $dragging))
    }

    /// Opens a folder on top of everything else; an open friend card stays open underneath.
    private func openFolder(_ id: UUID) {
        if openFolderID != id { renamingFolderID = nil }
        openFolderID = id
    }

    private func closeFolder() {
        renamingFolderID = nil
        openFolderID = nil
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
        nicknameDraft = nil
        selectedFriendID = nil
    }

    private func toggleFriend(_ friend: Friend) {
        if selectedFriendID == friend.id {
            closeFolder()
            closeFriend()
        } else {
            select(friend)
        }
    }


    /// Shows the person a friend link points to: their card if they're already a friend, otherwise Add Friend with
    /// their username filled in (the user still confirms before anything is sent). A link to yourself is ignored.
    private func showPendingFriendLink() {
        guard let username = model.pendingFriendLink else { return }
        model.pendingFriendLink = nil
        guard username != model.credentials.map({ Username.forLookup($0.username) }) else { return }
        if let friend = model.friends.first(where: { $0.user.username == username }) {
            activeSheet = nil
            select(friend)
            return
        }
        addFriendPrefill = username
        activeSheet = .addFriend
    }
    private func select(_ friend: Friend, fromPin: Bool = false) {
        closeFolder()
        let alreadySelected = selectedFriendID == friend.id
        if !alreadySelected { nicknameDraft = nil }
        selectedFriendID = friend.id
        if let loc = friend.location {
            let kind: MapCommand.Kind = alreadySelected || fromPin
                ? .recenter(latitude: loc.latitude, longitude: loc.longitude)
                : .focus(latitude: loc.latitude, longitude: loc.longitude)
            mapCommand = MapCommand(kind: kind)
        } else {
            mapCommand = nil
        }
    }
}
