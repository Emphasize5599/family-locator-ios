import SwiftUI

extension Color {
    /// Zood brand colors, taken from george's `colors.xml`.
    static let zoodBlue = Color(red: 0x5c / 255, green: 0xd1 / 255, blue: 0xff / 255)
    static let zoodBlueDark = Color(red: 0x09 / 255, green: 0xa8 / 255, blue: 0xe6 / 255)
    static let zoodNavy = Color(red: 0x3c / 255, green: 0x44 / 255, blue: 0x66 / 255)
    static let zoodRed = Color(red: 0xe4 / 255, green: 0x1c / 255, blue: 0x16 / 255)
    static let zoodGreen = Color(red: 0x3c / 255, green: 0xdd / 255, blue: 0x56 / 255)
    static let zoodOrange = Color(red: 0xf6 / 255, green: 0x92 / 255, blue: 0x1e / 255)
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

extension Date {
    /// "just now", "5 min ago", etc.
    var relativeDescription: String {
        if abs(timeIntervalSinceNow) < 60 { return String(localized: "just now") }
        return formatted(.relative(presentation: .named))
    }
}

/// Shared by the ⋯ and ✕ buttons so they're always exactly the same size.
let panelIconConfig = UIImage.SymbolConfiguration(textStyle: .title2)

/// Closes a card without applying its draft changes. UIKit like `FriendMenu`, with the same symbol configuration, so the two match.
struct CloseButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark.circle", withConfiguration: panelIconConfig), for: .normal)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = String(localized: "Close")
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

/// Original, simple platform silhouettes; neutral tint keeps them secondary to the person's name.
struct PlatformBadge: View {
    let platform: Platform
    var body: some View {
        PlatformSilhouette(platform: platform)
            .fill(Color.secondary, style: FillStyle(eoFill: true))
            .frame(width: 20, height: 22)
            .accessibilityLabel(platform == .ios ? "Apple device" : "Android device")
    }
}

private struct PlatformSilhouette: Shape {
    let platform: Platform
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        return Path { p in
            if platform == .android {
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
            } else {
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.3))
                p.addCurve(to: CGPoint(x: w * 0.16, y: h * 0.85), control1: CGPoint(x: -w * 0.2, y: -h * 0.1), control2: CGPoint(x: -w * 0.04, y: h * 0.65))
                p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.94), control1: CGPoint(x: w * 0.33, y: h * 1.12), control2: CGPoint(x: w * 0.35, y: h * 0.87))
                p.addCurve(to: CGPoint(x: w * 0.9, y: h * 0.42), control1: CGPoint(x: w * 0.87, y: h * 1.15), control2: CGPoint(x: w * 1.16, y: h * 0.53))
                p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.3), control1: CGPoint(x: w * 0.83, y: h * 0.18), control2: CGPoint(x: w * 0.64, y: h * 0.2))
                p.closeSubpath()
                p.addEllipse(in: CGRect(x: w * 0.8, y: h * 0.35, width: w * 0.35, height: h * 0.3))
                p.addEllipse(in: CGRect(x: w * 0.51, y: 0, width: w * 0.23, height: h * 0.21))
            }
        }
    }
}
