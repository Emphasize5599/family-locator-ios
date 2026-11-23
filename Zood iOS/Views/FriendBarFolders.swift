import SwiftUI
import UniformTypeIdentifiers

// Drag and drop in the friend bar, like Discord's server folders:
// • drop a friend on another friend to put them in a folder together (or join that friend's folder),
// • drop a friend on a folder to add them to it,
// • drop a folder member on an empty part of the bar to take them back out.
// A folder that's left with one person dissolves. Folders never change who you share your location with.

/// Where a dragged friend was dropped in the friend bar.
enum FriendBarDropTarget: Hashable {
    case friend(Data)
    case folder(UUID)
    case bar
}

/// The drag payload is the friend's user ID as text; it only means something inside this app.
enum FriendDrag {
    static func provider(for id: Data) -> NSItemProvider {
        NSItemProvider(object: id.base64EncodedString() as NSString)
    }
}

/// Highlights the item under the finger and reports which friend landed where.
struct FriendDropDelegate: DropDelegate {
    let target: FriendBarDropTarget
    @Binding var hovered: FriendBarDropTarget?
    let onDrop: (Data, FriendBarDropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        if target != .bar { hovered = target }
    }

    func dropExited(info: DropInfo) {
        if hovered == target { hovered = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        hovered = nil
        guard let item = info.itemProviders(for: [.plainText]).first else { return false }
        let target = target
        let onDrop = onDrop
        _ = item.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let id = Data(base64Encoded: text as String) else { return }
            DispatchQueue.main.async { onDrop(id, target) }
        }
        return true
    }
}

/// A closed folder: up to four of its members in a 2×2 grid on a rounded tile, the same size as an avatar.
struct FolderTile: View {
    let members: [Friend]
    var size: CGFloat = 52

    var body: some View {
        let mini = (size - 3 * 4) / 2
        LazyVGrid(columns: [GridItem(.fixed(mini), spacing: 4), GridItem(.fixed(mini), spacing: 4)], spacing: 4) {
            ForEach(members.prefix(4)) { friend in
                AvatarView(username: friend.avatarName, imageData: friend.avatar, size: mini)
            }
        }
        .frame(width: size, height: size)
        .background(Color.zoodBlue.opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
