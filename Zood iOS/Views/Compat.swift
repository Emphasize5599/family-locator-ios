import PhotosUI
import SwiftUI

// Small shims so the app can target iOS 15 while using newer SwiftUI APIs where available.

/// NavigationStack on iOS 16+, a stack-style NavigationView on iOS 15.
struct CompatNavigationStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16, *), !LegacyStyle.isForced {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content)
                .navigationViewStyle(.stack)
        }
    }
}

/// Debug only: `ZOOD_LEGACY_STYLE=1` draws the pre-iOS 26 look (blur material, bordered buttons) on a
/// newer simulator, so the iOS 15–17 path can be checked without an older runtime.
enum LegacyStyle {
    static var isForced: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZOOD_LEGACY_STYLE"] == "1"
        #else
        false
        #endif
    }
}

extension Color {
    /// Secondary text and icons on floating cards. SwiftUI's `.secondary` turns vibrant on a blur material
    /// before iOS 26, and over a dark map in Dark Mode that vibrant gray all but disappears (battery, update
    /// time, "Share my location" and the platform logo were invisible on an iOS 17 iPhone). UIKit's
    /// `secondaryLabel` is a plain color, so it stays readable on any material.
    static let cardSecondary = Color(uiColor: .secondaryLabel)
}

extension View {
    /// Background for controls that float over the map. Liquid Glass on iOS 26+, so it follows the person's chosen
    /// Liquid Glass look (Clear / Tinted), Reduce Transparency and Increase Contrast like system controls do.
    /// Earlier iOS versions get the standard blur material (which already honours Reduce Transparency).
    @ViewBuilder
    func floatingSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *), !LegacyStyle.isForced {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(interactive ? 0.08 : 0.12), radius: interactive ? 4 : 10, y: 2)
        }
    }

    /// Sheet that opens exactly `height` tall (still expandable to full) on iOS 16+; full height on iOS 15.
    /// If the height changes while it's open, the sheet follows it, unless the person dragged it to full height.
    /// While typing (`allowsFullHeight` false) the sheet stays at `height`, so iOS doesn't jump it to full height.
    @ViewBuilder
    func compatFittedDetent(height: CGFloat, allowsFullHeight: Bool = true) -> some View {
        if #available(iOS 16, *) {
            modifier(FittedDetent(height: height, allowsFullHeight: allowsFullHeight))
        } else {
            self
        }
    }

    /// Full-height sheet that leaves the map behind it alone (see `PresentationDetent.fullHeight`). iOS 16+.
    @ViewBuilder
    func compatFullHeightSheet() -> some View {
        if #available(iOS 16, *) {
            presentationDetents([.fullHeight])
        } else {
            self
        }
    }

    /// The panel's main action: prominent Liquid Glass on iOS 26+, filled bordered button before that.
    @ViewBuilder
    /// `circle: true` makes a round button, for icon-only actions (this design uses circles for those).
    func prominentActionStyle(tint: Color, circle: Bool = false) -> some View {
        if #available(iOS 26, *), !LegacyStyle.isForced {
            if circle {
                buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(tint)
            } else {
                buttonStyle(.glassProminent).tint(tint)
            }
        } else {
            buttonStyle(LegacyProminentButtonStyle(tint: tint, circle: circle))
        }
    }

    /// `onChange` without the iOS 17 deprecation warning, back to iOS 15.
    @ViewBuilder
    func compatOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

/// Share sheet (ShareLink is iOS 16+).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Single-image picker (PhotosPicker is iOS 16+). Returns the image's data, or nil if cancelled.
struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (Data?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Data?) -> Void
        init(onPick: @escaping (Data?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                onPick(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [onPick] object, _ in
                let data = (object as? UIImage)?.jpegData(compressionQuality: 0.9)
                DispatchQueue.main.async { onPick(data) }
            }
        }
    }
}

@available(iOS 16, *)
extension PresentationDetent {
    /// Full height without `.large`: on iOS 16–18 a sheet at `.large` shrinks the screen behind it into a receding
    /// card, which makes the full-screen map look like it zooms out while the sheet is dragged up. A custom detent
    /// just short of the maximum preserves the map's visual position while the person moves the panel.
    static let fullHeight = PresentationDetent.fraction(0.999)
}

@available(iOS 16, *)
private struct FittedDetent: ViewModifier {
    let height: CGFloat
    let allowsFullHeight: Bool
    @State private var isExpanded = false

    func body(content: Content) -> some View {
        content
            .presentationDetents(allowsFullHeight ? [.height(height), .fullHeight] : [.height(height)], selection: Binding(
                get: { allowsFullHeight && isExpanded ? .fullHeight : .height(height) },
                set: { isExpanded = $0 == .fullHeight }
            ))
            .compatOnChange(of: allowsFullHeight) { allowed in
                if !allowed { isExpanded = false }
            }
    }
}

/// Compact sheets measure their content instead of assuming half the screen is enough.
/// ScrollView keeps large text and short screens usable; people can still expand to full height.
struct ContentFittedSheet<Content: View>: View {
    let title: LocalizedStringKey
    var showsCloseButton = false
    var backAction: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    /// Measured content height, without any bottom inset.
    @State private var contentHeight: CGFloat = 450
    /// On-screen keyboard height, 0 when hidden.
    @State private var keyboardHeight: CGFloat = 0

    // Detent heights exclude the safe area: iOS adds the home-indicator/keyboard inset itself.
    // Adding that inset again can accidentally save the keyboard's height as empty sheet space.
    private var sheetHeight: CGFloat {
        max(160, contentHeight.rounded(.up))
    }

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.large) {
                    HStack {
                        if let backAction {
                            Button(action: backAction) {
                                Image(systemName: "chevron.backward")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Back")
                        }
                        Text(title).font(.headline)
                        Spacer()
                        if showsCloseButton {
                            CloseButton { dismiss() }.frame(minWidth: 44, minHeight: 44)
                        } else {
                            Button("Done") { dismiss() }.frame(minHeight: 44)
                        }
                    }
                    content()
                }
                // System sheet spacing: the header sits just below the drag indicator (whose own area is
                // about 15 pt), content uses the standard 20 pt sheet margins, and the bottom matches the sides.
                .padding(.horizontal, Spacing.sheetMargin)
                .padding(.top, Spacing.medium)
                .padding(.bottom, keyboardHeight > 0 ? Spacing.small : Spacing.sheetMargin)
                .frame(maxWidth: .infinity)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: FittedSheetHeightKey.self, value: geometry.size.height)
                })
            }
            .onPreferenceChange(FittedSheetHeightKey.self) { height in
                guard height > 0, abs(height - contentHeight) > 1 else { return }
                contentHeight = height
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .compatFittedDetent(height: sheetHeight, allowsFullHeight: keyboardHeight == 0)
        .task {
            for await note in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) {
                keyboardHeight = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillHideNotification) {
                keyboardHeight = 0
            }
        }
    }
}

private struct FittedSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The filled button used before iOS 26. The system `.borderedProminent` turns a disabled button into a gray
/// box with a gray icon, which read as a blank square in Dark Mode; this keeps the tint and icon and simply
/// dims the whole button, so it's clear what the button is and that it's unavailable.
/// It also follows `.controlSize(.large)` like the system bordered styles, so it matches a neighbouring
/// `.bordered` button (Timed Sharing's Copy Link / Share Link were different heights without this).
private struct LegacyProminentButtonStyle: ButtonStyle {
    let tint: Color
    var circle = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        return Group {
            if circle {
                configuration.label
                    .padding(large ? 10 : 7)
                    .background(tint, in: Circle())
            } else {
                configuration.label
                    .padding(.horizontal, large ? 20 : 14)
                    .padding(.vertical, large ? 14 : 7)
                    .background(tint, in: RoundedRectangle(cornerRadius: large ? 14 : 12, style: .continuous))
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
        .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
