import SwiftUI

extension Color {
    /// Zood brand colors, taken from george's `colors.xml`.
    static let zoodBlue = Color(red: 0x5c / 255, green: 0xd1 / 255, blue: 0xff / 255)
    static let zoodBlueDark = Color(red: 0x09 / 255, green: 0xa8 / 255, blue: 0xe6 / 255)
    static let zoodNavy = Color(red: 0x3c / 255, green: 0x44 / 255, blue: 0x66 / 255)
    static let zoodRed = Color(red: 0xe4 / 255, green: 0x1c / 255, blue: 0x16 / 255)
    static let zoodGreen = Color(red: 0x3c / 255, green: 0xdd / 255, blue: 0x56 / 255)
    static let zoodOrange = Color(red: 0xf6 / 255, green: 0x92 / 255, blue: 0x1e / 255)

    /// Icons and titles on controls floating over the map: Zood navy in Light Mode, and the app's light blue
    /// (the Add / Refresh color) in Dark Mode, where navy all but disappears against the dark material.
    static let floatingAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x5c / 255, green: 0xd1 / 255, blue: 0xff / 255, alpha: 1)
            : UIColor(red: 0x3c / 255, green: 0x44 / 255, blue: 0x66 / 255, alpha: 1)
    })
}

/// Round avatar: the friend's photo if they've sent one, otherwise their initial on a stable color.
struct AvatarView: View {
    let username: String
    let imageData: Data?
    var size: CGFloat = 44

    private static let palette: [Color] = [.zoodBlue, .zoodNavy, .zoodOrange, .zoodGreen, .zoodRed, .zoodBlueDark]

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    background
                    Text(username.prefix(1).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: size > 30 ? 2 : 1))
        .accessibilityLabel(username)
    }

    private var background: Color { Self.color(for: username) }

    /// Stable per-person color, shared with the map pins.
    static func color(for username: String) -> Color {
        let hash = username.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

/// Photo framing shared by profile photos, contact photos and map pins, so a face is never squashed.
enum AvatarImage {
    /// The largest centered square of `image`, as a rectangle to draw the whole image into so that square
    /// exactly fills `target` (fill-and-crop, never stretch).
    static func fillRect(for image: UIImage, in target: CGRect) -> CGRect {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return target }
        let scale = target.width / side
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: target.midX - width / 2, y: target.midY - height / 2, width: width, height: height)
    }

    /// Center-crops to a square and downsizes to `side`×`side` JPEG, roughly what Android's avatar cropper
    /// produces. Used for your own photo. (Linked contacts keep their Contacts framing and aren't re-cropped.)
    static func squareJPEG(from data: Data, side: CGFloat = 256) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let target = CGRect(x: 0, y: 0, width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let squared = UIGraphicsImageRenderer(size: target.size, format: format).image { _ in
            image.draw(in: fillRect(for: image, in: target))
        }
        return squared.jpegData(compressionQuality: 0.8)
    }
}

extension Date {
    /// "just now", "5 min ago", etc.
    var relativeDescription: String {
        if abs(timeIntervalSinceNow) < 60 { return String(localized: "just now") }
        return formatted(.relative(presentation: .named))
    }
}

/// One spacing scale for the whole app, so the gaps between related things look the same everywhere.
enum Spacing {
    /// A title and its subtitle in a list row.
    static let hairline: CGFloat = 2
    /// Lines of text that belong together (a card's name, battery, address and status); an icon and its label.
    static let tight: CGFloat = 4
    /// Items inside one group.
    static let small: CGFloat = 8
    /// Between groups, and between the controls floating over the map.
    static let medium: CGFloat = 12
    /// Card and sheet padding, and between sections.
    static let large: CGFloat = 16
    /// Separating major blocks.
    static let xLarge: CGFloat = 24
    /// Side margins of bottom sheets, matching the system's sheet and inset-grouped list margins.
    static let sheetMargin: CGFloat = 20
}

/// Shared by every icon in the friend card's header (platform logo, ✎, ⋯, ✕) so they're exactly the same size.
/// A fixed point size rather than a text style: with a text style, the UIKit buttons grew with the person's text
/// size while the SwiftUI pencil didn't, so on a phone with larger text the pencil looked smaller than ⋯ and ✕.
let panelIconConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)

/// Height of the circled header symbols at `panelIconConfig`. The platform logo is drawn at this size too.
let panelIconSide: CGFloat = UIImage(systemName: "ellipsis.circle", withConfiguration: panelIconConfig)?.size.height ?? 26

/// A circled SF Symbol button for the friend card's header, drawn by UIKit with `panelIconConfig` exactly like
/// the ⋯ menu, so ✎, ⋯ and ✕ always match.
struct PanelIconButton: UIViewRepresentable {
    let systemName: String
    let tint: UIColor
    let accessibilityLabel: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName, withConfiguration: panelIconConfig), for: .normal)
        button.tintColor = tint
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func tapped() { action?() }
    }
}

/// One item in a `PanelMenuButton` menu.
struct PanelMenuAction: Equatable {
    let title: String
    let systemImage: String
    var destructive = false
    let handler: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.systemImage == rhs.systemImage && lhs.destructive == rhs.destructive
    }
}

/// A ⋯ button that opens a menu, drawn by UIKit exactly like the friend card's ⋯ (same symbol size and tint),
/// so every card's ⋯ matches. Items appear top to bottom in the order given.
struct PanelMenuButton: UIViewRepresentable {
    let accessibilityLabel: String
    let actions: [PanelMenuAction]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: panelIconConfig), for: .normal)
        button.tintColor = UIColor(Color.zoodBlueDark)
        button.showsMenuAsPrimaryAction = true
        if #available(iOS 16, *) { button.preferredMenuElementOrder = .fixed }
        button.accessibilityLabel = accessibilityLabel
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.actions = actions
        // Rebuild only when the items change, so an open menu never flashes.
        guard context.coordinator.builtFor != actions else { return }
        context.coordinator.builtFor = actions
        var items: [UIMenuElement] = actions.enumerated().map { index, action in
            UIAction(title: action.title, image: UIImage(systemName: action.systemImage),
                     attributes: action.destructive ? .destructive : []) { [weak coordinator = context.coordinator] _ in
                coordinator?.actions[index].handler()
            }
        }
        if #unavailable(iOS 16) { items.reverse() }
        button.menu = UIMenu(children: items)
    }

    final class Coordinator {
        var actions: [PanelMenuAction] = []
        var builtFor: [PanelMenuAction]?
    }
}

/// Closes a card without applying its draft changes.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        PanelIconButton(systemName: "xmark.circle", tint: .secondaryLabel,
                        accessibilityLabel: String(localized: "Close"), action: action)
    }
}

/// Which kind of phone a friend uses, shown at the same size as the header buttons (no circle around it).
/// Neutral gray keeps it secondary to the person's name. See Settings › About › Notices for trademarks.
struct PlatformBadge: View {
    let platform: Platform

    var body: some View {
        logo
            .foregroundStyle(Color.cardSecondary)
            .frame(width: panelIconSide, height: panelIconSide)
            // Not a button, so it only needs its own width; that leaves more room for a name beside the avatar.
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(platform == .ios ? "Apple device" : "Android device")
    }

    @ViewBuilder private var logo: some View {
        if platform == .ios {
            // Apple's own SF Symbol for referring to Apple products, used unmodified.
            Image(systemName: "apple.logo")
                .resizable()
                .scaledToFit()
        } else if UIImage(named: "AndroidLogo") != nil {
            // The official Android robot artwork (Google, CC BY 3.0), once it's added to the asset catalog
            // as a template image named "AndroidLogo".
            Image("AndroidLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            // Until then, an original robot-style placeholder.
            PlatformSilhouette()
                .fill(style: FillStyle(eoFill: true))
                .aspectRatio(20 / 22, contentMode: .fit)
        }
    }
}

/// An original, simplified robot shape used for Android until the official artwork is added.
private struct PlatformSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        return Path { p in
            p.addRoundedRect(in: CGRect(x: w * 0.08, y: h * 0.25, width: w * 0.84, height: h * 0.6), cornerSize: CGSize(width: w * 0.22, height: h * 0.22))
            for x in [0.27, 0.67] {
                p.addEllipse(in: CGRect(x: w * x, y: h * 0.42, width: w * 0.1, height: w * 0.1))
            }
            for x in [0.24, 0.68] {
                p.addRoundedRect(in: CGRect(x: w * x, y: h * 0.79, width: w * 0.1, height: h * 0.2), cornerSize: CGSize(width: 2, height: 2))
            }
            p.move(to: CGPoint(x: w * 0.23, y: h * 0.31))
            p.addLine(to: CGPoint(x: w * 0.14, y: h * 0.12))
            p.addLine(to: CGPoint(x: w * 0.2, y: h * 0.1))
            p.addLine(to: CGPoint(x: w * 0.31, y: h * 0.3))
            p.closeSubpath()
            p.move(to: CGPoint(x: w * 0.7, y: h * 0.3))
            p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.1))
            p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.12))
            p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.31))
            p.closeSubpath()
        }
    }
}
