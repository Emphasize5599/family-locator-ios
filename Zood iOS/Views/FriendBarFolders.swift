import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Arranging the friend bar works like the iPhone Home Screen:
// • long-press someone to lift them; drag sideways and the others slide out of the way, so you can put
//   anyone anywhere (your order is saved),
// • hold over the middle of someone else to make a folder of the two of you (or over a folder to join it),
// • folders open above the bar as a grid (3×3 by default, like Home Screen folders; adjustable in Settings),
//   where you can rearrange people or drag them back out onto the bar.
// Folders and order only tidy the bar; they never change who sees your location.

/// Haptics for arranging the bar: a firm tap when something lifts, a tick each time things shuffle, a light
/// tap when a folder is about to form, and a confirmation on drop.
enum BarHaptics {
    static func lift() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func shuffle() { UISelectionFeedbackGenerator().selectionChanged() }
    static func folderTarget() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func drop() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func folderChanged() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

/// Every bar item (friend or folder) is laid out this wide, so drop zones line up with what you see.
let barItemWidth: CGFloat = 64

/// What's being dragged lives in view state (SwiftUI drops carry an item provider, not our IDs), so the
/// provider itself is just a token that only this app understands.
func barDragProvider() -> NSItemProvider {
    NSItemProvider(object: "family-locator-bar-item" as NSString)
}

/// Drop handling for one item in the bar, or for the empty part of the bar (`target == nil`).
struct BarItemDropDelegate: DropDelegate {
    let target: BarItemID?
    let model: AppModel
    @Binding var dragging: BarItemID?
    /// The item currently showing "let go to make a folder".
    @Binding var folderTarget: BarItemID?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let dragging, let target, dragging != target else { return DropProposal(operation: .move) }
        let x = info.location.x
        // The middle of an item makes a folder (people only; folders don't go inside folders). The sides move
        // the dragged item before or after it, sliding everything else out of the way.
        let overMiddle = x > barItemWidth * 0.3 && x < barItemWidth * 0.7
        let canGroup: Bool = { if case .friend = dragging { return true } else { return false } }()
        if overMiddle && canGroup {
            if folderTarget != target {
                folderTarget = target
                BarHaptics.folderTarget()
            }
        } else {
            if folderTarget == target { folderTarget = nil }
            if !overMiddle {
                let moved = withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    model.moveBarItem(dragging, beside: target, after: x >= barItemWidth / 2)
                }
                if moved { BarHaptics.shuffle() }
            }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if folderTarget == target { folderTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragging = nil
            folderTarget = nil
        }
        guard let dragging else { return false }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if let target, folderTarget == target, case .friend(let friendID) = dragging {
                switch target {
                case .friend(let other): model.groupFriend(friendID, with: other)
                case .folder(let folderID): model.moveFriend(friendID, toFolder: folderID)
                }
                BarHaptics.folderChanged()
            } else if target == nil, case .friend(let friendID) = dragging, model.folder(containing: friendID) != nil {
                // Dropped on an empty part of the bar: out of the folder, at the end of the bar.
                model.removeFromFolder(friendID)
                BarHaptics.folderChanged()
            } else {
                BarHaptics.drop()
            }
        }
        return true
    }
}

/// Drop handling inside an open folder: drag across members to rearrange them, or drop anyone on the folder
/// to add them.
struct FolderGridDropDelegate: DropDelegate {
    let folderID: UUID
    /// The member under the finger, or nil for the folder's empty space.
    let member: Data?
    let model: AppModel
    @Binding var dragging: BarItemID?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let member, case .friend(let friendID)? = dragging,
           model.folder(containing: friendID)?.id == folderID {
            let moved = withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                model.moveWithinFolder(friendID, beside: member, after: info.location.x >= barItemWidth / 2)
            }
            if moved { BarHaptics.shuffle() }
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        guard case .friend(let friendID)? = dragging else { return false }
        if model.folder(containing: friendID)?.id != folderID {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.moveFriend(friendID, toFolder: folderID) }
            BarHaptics.folderChanged()
        } else {
            BarHaptics.drop()
        }
        return true
    }
}

/// What you see under your finger while dragging: bigger than the bar's circles, with the name on a pill,
/// so it stays visible around a thumb.
struct BarDragPreview<Icon: View>: View {
    let title: String
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: Spacing.tight) {
            icon()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, Spacing.small)
                .padding(.vertical, Spacing.hairline)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(Spacing.small)
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
                AvatarView(username: friend.avatarName, imageData: friend.displayAvatar, size: mini)
            }
        }
        .frame(width: size, height: size)
        .background(Color.zoodBlue.opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Folder grid size, set in Settings › Friend Bar. 3×3 matches Home Screen folders on iPhone.
enum FolderGrid {
    static let columnsKey = "folderGridColumns"
    static let rowsKey = "folderGridRows"
    static let defaultColumns = 3
    static let defaultRows = 3
    static let columnRange = 2...4
    static let rowRange = 2...5
}
