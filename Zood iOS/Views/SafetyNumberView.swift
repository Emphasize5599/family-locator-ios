import SwiftUI

/// Same safety number george shows (`SafetyNumber.toSafetyNumber` + `SafetyNumberFragment`): both public keys
/// concatenated, the alphabetically-first username's key first, read as big-endian 16-bit values, each printed
/// as five digits, four per row. Both people see identical digits on Android and iOS.
enum SafetyNumber {
    static func make(myUsername: String, myPublicKey: Data, theirUsername: String, theirPublicKey: Data) -> String {
        let theirsFirst = theirUsername.lowercased() < myUsername.lowercased()
        let bytes = [UInt8](theirsFirst ? theirPublicKey + myPublicKey : myPublicKey + theirPublicKey)
        var groups: [String] = []
        var index = 0
        while index + 1 < bytes.count {
            let value = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
            groups.append(String(format: "%05d", value))
            index += 2
        }
        return stride(from: 0, to: groups.count, by: 4)
            .map { groups[$0..<min($0 + 4, groups.count)].joined(separator: "  ") }
            .joined(separator: "\n")
    }
}

struct SafetyNumberView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let friend: Friend

    @State private var showingShare = false

    private var safetyNumber: String? {
        guard let me = model.credentials else { return nil }
        return SafetyNumber.make(myUsername: me.username, myPublicKey: me.keyPair.publicKey,
                                 theirUsername: friend.user.username, theirPublicKey: friend.user.publicKey)
    }

    var body: some View {
        CompatNavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.zoodBlue)
                    Text("If you want to verify the security of your encryption with \(friend.user.username), compare the number below with the number on their device.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if let safetyNumber {
                        Text(safetyNumber)
                            .font(.system(.title3, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.zoodBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel("Safety number")
                            .accessibilityValue(safetyNumber.replacingOccurrences(of: "\n", with: " "))
                    }
                    Text("It's the same on both phones, iPhone or Android. If the numbers don't match, someone may be intercepting your messages.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("Safety Number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share safety number")
                    .disabled(safetyNumber == nil)
                }
            }
            .sheet(isPresented: $showingShare) {
                // Same wording as Android's share_safety_number_msg.
                ActivityView(items: ["Our Zood Location safety number:\n\(safetyNumber ?? "")"])
            }
        }
    }
}
