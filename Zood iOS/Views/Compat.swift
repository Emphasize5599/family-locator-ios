import PhotosUI
import SwiftUI

// Small shims so the app can target iOS 15 while using newer SwiftUI APIs where available.

/// NavigationStack on iOS 16+, a stack-style NavigationView on iOS 15.
struct CompatNavigationStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content)
                .navigationViewStyle(.stack)
        }
    }
}

extension View {
    /// Background for controls that float over the map. Liquid Glass on iOS 26+, so it follows the person's chosen
    /// Liquid Glass look (Clear / Tinted), Reduce Transparency and Increase Contrast like system controls do.
    /// Earlier iOS versions get the standard blur material (which already honours Reduce Transparency).
    @ViewBuilder
    func floatingSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(interactive ? 0.08 : 0.12), radius: interactive ? 4 : 10, y: 2)
        }
    }

    /// Sheet that opens exactly `height` tall (still expandable to full) on iOS 16+; full height on iOS 15.
    /// If the height changes while it's open, the sheet follows it, unless the person dragged it to full height.
    @ViewBuilder
    func compatFittedDetent(height: CGFloat) -> some View {
        if #available(iOS 16, *) {
            modifier(FittedDetent(height: height))
        } else {
            self
        }
    }

    /// The panel's main action: prominent Liquid Glass on iOS 26+, filled bordered button before that.
    @ViewBuilder
    func prominentActionStyle(tint: Color) -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
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
private struct FittedDetent: ViewModifier {
    let height: CGFloat
    @State private var selection: PresentationDetent?

    func body(content: Content) -> some View {
        content
            .presentationDetents([.height(height), .large], selection: Binding(
                get: { selection ?? .height(height) },
                set: { selection = $0 }
            ))
            .compatOnChange(of: height) { newHeight in
                if selection != .large { selection = .height(newHeight) }
            }
    }
}

/// Compact sheets measure their content instead of assuming half the screen is enough.
/// ScrollView keeps large text and short screens usable; people can still expand to full height.
struct ContentFittedSheet<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 480

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        Button("Done") { dismiss() }.frame(minHeight: 44)
                    }
                    content()
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: FittedSheetHeightKey.self, value: geometry.size.height)
                })
            }
            .onPreferenceChange(FittedSheetHeightKey.self) { height in
                guard height > 0 else { return }
                let fitted = max(160, (height + outer.safeAreaInsets.bottom).rounded(.up))
                if abs(fitted - contentHeight) > 1 { contentHeight = fitted }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .compatFittedDetent(height: contentHeight)
    }
}

private struct FittedSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
