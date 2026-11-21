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
