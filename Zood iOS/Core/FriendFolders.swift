import Foundation

/// A group of friends in the friend bar, like a folder of servers in Discord. Created by dragging one friend
/// onto another; purely a way to tidy the bar, so it never changes who you share with.
nonisolated struct FriendFolder: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// Optional; the bar shows "Folder" when there's no name.
    var name: String?
    /// Friend user IDs, in the order they were added.
    var members: [Data]
}

/// One spot in the friend bar after Add and Requests: a friend who isn't in a folder, or a folder.
nonisolated enum BarItemID: Hashable, Codable, Sendable {
    case friend(Data)
    case folder(UUID)
}

extension BarItemID {
    /// The backup's text form: "friend:<base64 user id>" or "folder:<folder id>".
    var backupValue: String {
        switch self {
        case .friend(let id): return "friend:" + id.base64EncodedString()
        case .folder(let id): return "folder:" + id.uuidString
        }
    }

    init?(backupValue: String) {
        if backupValue.hasPrefix("friend:"), let id = Data(base64Encoded: String(backupValue.dropFirst(7))) {
            self = .friend(id)
        } else if backupValue.hasPrefix("folder:"), let id = UUID(uuidString: String(backupValue.dropFirst(7))) {
            self = .folder(id)
        } else {
            return nil
        }
    }
}

enum BarItem: Identifiable {
    case friend(Friend)
    case folder(FriendFolder)

    var id: BarItemID {
        switch self {
        case .friend(let friend): return .friend(friend.id)
        case .folder(let folder): return .folder(folder.id)
        }
    }
}

/// Folders and the bar's order are kept on this iPhone, per signed-in account.
nonisolated enum FriendFolderStore {
    private static func key(for account: Data) -> String {
        "friend-folders." + account.base64EncodedString()
    }

    private static func orderKey(for account: Data) -> String {
        "friend-bar-order." + account.base64EncodedString()
    }

    static func loadOrder(for account: Data) -> [BarItemID] {
        guard let data = UserDefaults.standard.data(forKey: orderKey(for: account)) else { return [] }
        return (try? JSONDecoder().decode([BarItemID].self, from: data)) ?? []
    }

    static func saveOrder(_ order: [BarItemID], for account: Data) {
        guard let data = try? JSONEncoder().encode(order) else { return }
        UserDefaults.standard.set(data, forKey: orderKey(for: account))
    }

    static func load(for account: Data) -> [FriendFolder] {
        guard let data = UserDefaults.standard.data(forKey: key(for: account)) else { return [] }
        return (try? JSONDecoder().decode([FriendFolder].self, from: data)) ?? []
    }

    static func save(_ folders: [FriendFolder], for account: Data) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: key(for: account))
    }

    static func delete(for account: Data) {
        UserDefaults.standard.removeObject(forKey: key(for: account))
        UserDefaults.standard.removeObject(forKey: orderKey(for: account))
    }
}

extension AppModel {
    /// Folders that still have at least two current friends, members in their saved order. A folder whose
    /// other members were removed or blocked simply stops showing, and its last member returns to the bar.
    var friendFolders: [FriendFolder] {
        folders.compactMap { folder in
            let members = folder.members.filter { local.friends[$0] != nil }
            guard members.count >= 2 else { return nil }
            var visible = folder
            visible.members = members
            return visible
        }
    }

    /// Friends that aren't in any folder, in the bar's usual name order.
    var ungroupedFriends: [Friend] {
        let grouped = Set(friendFolders.flatMap(\.members))
        return friends.filter { !grouped.contains($0.id) }
    }

    /// The bar after Add and Requests, in the order the person arranged it. Anyone or any folder not placed
    /// yet (a new friend, say) goes at the end: folders first, then friends by name.
    var barItems: [BarItem] {
        let visibleFolders = friendFolders
        let ungrouped = ungroupedFriends
        let folderByID = Dictionary(uniqueKeysWithValues: visibleFolders.map { ($0.id, $0) })
        let friendByID = Dictionary(uniqueKeysWithValues: ungrouped.map { ($0.id, $0) })
        var placed = Set<BarItemID>()
        var items: [BarItem] = []
        for id in barOrder where !placed.contains(id) {
            switch id {
            case .friend(let friendID):
                if let friend = friendByID[friendID] { items.append(.friend(friend)); placed.insert(id) }
            case .folder(let folderID):
                if let folder = folderByID[folderID] { items.append(.folder(folder)); placed.insert(id) }
            }
        }
        for folder in visibleFolders where !placed.contains(.folder(folder.id)) { items.append(.folder(folder)) }
        for friend in ungrouped where !placed.contains(.friend(friend.id)) { items.append(.friend(friend)) }
        return items
    }

    /// Moves `moving` just before or after `target` while a drag passes over it. A friend dragged out of a
    /// folder leaves the folder here. Returns whether anything moved (for haptics).
    @discardableResult
    func moveBarItem(_ moving: BarItemID, beside target: BarItemID, after: Bool) -> Bool {
        guard moving != target else { return false }
        if case .friend(let friendID) = moving, folder(containing: friendID) != nil {
            setFolders(foldersWithout(friendID))
        }
        var ids = barItems.map(\.id)
        let before = ids
        ids.removeAll { $0 == moving }
        guard let index = ids.firstIndex(of: target) else { return false }
        ids.insert(moving, at: after ? index + 1 : index)
        guard ids != before else { return false }
        setBarOrder(ids)
        return true
    }

    /// One step left or right, for VoiceOver's Move Left / Move Right actions.
    func nudgeBarItem(_ id: BarItemID, by offset: Int) {
        var ids = barItems.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let destination = min(max(index + offset, 0), ids.count - 1)
        guard destination != index else { return }
        ids.remove(at: index)
        ids.insert(id, at: destination)
        setBarOrder(ids)
    }

    /// Reorders people inside an open folder while a drag passes over them.
    @discardableResult
    func moveWithinFolder(_ friendID: Data, beside target: Data, after: Bool) -> Bool {
        guard friendID != target, let folder = folder(containing: target),
              let index = folders.firstIndex(where: { $0.id == folder.id }),
              folders[index].members.contains(friendID) else { return false }
        var members = folders[index].members
        let before = members
        members.removeAll { $0 == friendID }
        guard let targetIndex = members.firstIndex(of: target) else { return false }
        members.insert(friendID, at: after ? targetIndex + 1 : targetIndex)
        guard members != before else { return false }
        var next = folders
        next[index].members = members
        setFolders(next)
        return true
    }

    func folder(containing friendID: Data) -> FriendFolder? {
        friendFolders.first { $0.members.contains(friendID) }
    }

    /// Dropping one friend onto another: join the target's folder, or start a new folder with the two of them.
    func groupFriend(_ dragged: Data, with target: Data) {
        guard dragged != target, local.friends[dragged] != nil, local.friends[target] != nil else { return }
        if let existing = folder(containing: target) {
            moveFriend(dragged, toFolder: existing.id)
            return
        }
        // The new folder takes the target's place in the bar.
        var order = barItems.map(\.id)
        var next = foldersWithout(dragged)
        next.removeAll { $0.members == [target] }
        let folder = FriendFolder(members: [target, dragged])
        next.append(folder)
        setFolders(next)
        order.removeAll { $0 == .friend(dragged) }
        if let index = order.firstIndex(of: .friend(target)) { order[index] = .folder(folder.id) }
        setBarOrder(order)
    }

    /// Dropping a friend onto a folder adds them at the end.
    func moveFriend(_ friendID: Data, toFolder folderID: UUID) {
        var next = foldersWithout(friendID)
        guard let index = next.firstIndex(where: { $0.id == folderID }) else { return }
        next[index].members.append(friendID)
        setFolders(next)
    }

    /// Dropping a folder member back onto the bar takes them out of the folder.
    func removeFromFolder(_ friendID: Data) {
        setFolders(foldersWithout(friendID))
    }

    func renameFolder(_ folderID: UUID, to name: String) {
        var next = folders
        guard let index = next.firstIndex(where: { $0.id == folderID }) else { return }
        next[index].name = Nickname.normalized(name)
        setFolders(next)
    }

    func ungroupFolder(_ folderID: UUID) {
        setFolders(folders.filter { $0.id != folderID })
    }

    /// Forgets a removed (or blocked) friend's place in folders and the bar, so adding them again starts fresh.
    func dropFromBar(_ friendID: Data) {
        let kept = foldersWithout(friendID)
        let keptIDs = Set(kept.map(\.id))
        let dissolved = Set(folders.map(\.id)).subtracting(keptIDs)
        setFolders(kept)
        setBarOrder(barOrder.filter { item in
            switch item {
            case .friend(let id): return id != friendID
            case .folder(let id): return !dissolved.contains(id)
            }
        })
    }

    /// Every folder minus `friendID`, dropping folders that are left with fewer than two people.
    private func foldersWithout(_ friendID: Data) -> [FriendFolder] {
        folders.compactMap { folder in
            var folder = folder
            folder.members.removeAll { $0 == friendID }
            return folder.members.count >= 2 ? folder : nil
        }
    }
}
