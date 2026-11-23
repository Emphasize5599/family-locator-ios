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

/// Folders are kept on this iPhone, per signed-in account, alongside the other local-only bar settings.
nonisolated enum FriendFolderStore {
    private static func key(for account: Data) -> String {
        "friend-folders." + account.base64EncodedString()
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
        var next = foldersWithout(dragged)
        next.removeAll { $0.members == [target] }
        next.append(FriendFolder(members: [target, dragged]))
        setFolders(next)
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

    /// Every folder minus `friendID`, dropping folders that are left with fewer than two people.
    private func foldersWithout(_ friendID: Data) -> [FriendFolder] {
        folders.compactMap { folder in
            var folder = folder
            folder.members.removeAll { $0 == friendID }
            return folder.members.count >= 2 ? folder : nil
        }
    }
}
