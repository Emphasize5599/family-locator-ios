import SwiftUI

/// Timed sharing, like george's TimedShareFragment: switch it on to get a link anyone can open in a browser to
/// follow your location until the timer runs out. Adjust the time with − / +, copy or share the link.
struct TimedShareView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingShareSheet = false
    @State private var copied = false
    @State private var errorMessage: String?

    private var isRunning: Bool { model.timedShare != nil }

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 6) {
                        Text("Temporarily share your location with someone that doesn't have the app by sending them a link.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Toggle(isOn: runningBinding) {
                        Label("Share my location", systemImage: "location.fill")
                            .font(.headline)
                    }
                    .tint(.zoodBlue)
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    countdown

                    HStack(spacing: 12) {
                        Button {
                            copyLink()
                        } label: {
                            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.zoodBlueDark)

                        Button {
                            showingShareSheet = true
                        } label: {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .prominentActionStyle(tint: .zoodBlue)
                    }
                    .controlSize(.large)
                    .disabled(!isRunning)

                    footer
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Timed Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = model.timedShareURL { ActivityView(items: [url]) }
            }
        }
    }

    // MARK: Countdown

    /// − / ring with time left / +. The ring empties as time runs out and refills when the time is changed.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let share = model.timedShare
            let remaining = share?.remaining(at: context.date) ?? 0
            let fraction = share?.fractionRemaining(at: context.date) ?? 0
            HStack(spacing: 28) {
                adjustButton("minus", label: "Less time") { model.adjustTimedShare(longer: false) }
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Color.zoodBlue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: fraction)
                    VStack(spacing: 2) {
                        Text(TimedShare.shortLabel(remaining))
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        if let share {
                            Text("Ends \(share.expiresAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 150, height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(share == nil ? Text("Timed sharing is off")
                                                 : Text("\(TimedShare.shortLabel(remaining)) left"))
                adjustButton("plus", label: "More time") { model.adjustTimedShare(longer: true) }
            }
            .opacity(isRunning ? 1 : 0.45)
        }
    }

    private func adjustButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 52, height: 52)
                .floatingSurface(in: Circle(), interactive: true)
                .foregroundStyle(Color.zoodNavy)
        }
        .buttonStyle(.plain)
        .disabled(!isRunning)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private var footer: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color.zoodRed)
        } else if !model.location.hasAnyPermission {
            Label("Timed sharing needs location access.", systemImage: "location.slash")
                .font(.footnote)
                .foregroundStyle(Color.zoodOrange)
        } else {
            Text("Anyone with the link can see where you are until the timer runs out. Your location is end-to-end encrypted; the key is in the link itself.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Actions

    private var runningBinding: Binding<Bool> {
        Binding(
            get: { model.timedShare != nil },
            set: { on in
                errorMessage = nil
                if on {
                    guard model.location.hasAnyPermission else {
                        model.location.requestPermission()
                        errorMessage = String(localized: "Allow location access to start timed sharing.")
                        return
                    }
                    do {
                        try model.startTimedShare()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } else {
                    model.stopTimedShare()
                }
            }
        )
    }

    private func copyLink() {
        guard let url = model.timedShareURL else { return }
        UIPasteboard.general.url = url
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { copied = false }
        }
    }
}

/// Shown above the friend bar while a timed share runs (Android's "peeking" sheet). Tap to open the controls.
struct TimedSharePeekBar: View {
    @EnvironmentObject private var model: AppModel
    let onTap: () -> Void

    var body: some View {
        if let share = model.timedShare {
            Button(action: onTap) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: share.fractionRemaining(at: context.date))
                                .stroke(Color.zoodBlue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Timed sharing is on").font(.subheadline.weight(.semibold))
                            Text("\(TimedShare.shortLabel(share.remaining(at: context.date))) left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .floatingSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityLabel(Text("Timed sharing is on. Open timed sharing controls."))
        }
    }
}
