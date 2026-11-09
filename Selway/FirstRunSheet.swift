import SwiftUI
import AppKit

/// Shown once after a successful first launch (Gatekeeper already passed).
struct FirstRunSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.textScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .scaledFont(size: 28)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're all set")
                        .scaledFont(.title2, weight: .semibold)
                    Text("Selway \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("If macOS asked you to allow Selway once under System Settings → Privacy & Security, that was expected. This is a free open-source app without a paid Apple Developer certificate — the one-time Open Anyway step is safe.")
                .scaledFont(size: 13)
                .fixedSize(horizontal: false, vertical: true)

            Text("When you browse Desktop, Documents, or Downloads, macOS may ask for folder access — click Allow. You can enable the optional Finder right-click menu later under Login Items & Extensions.")
                .scaledFont(size: 13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("GitHub") {
                    NSWorkspace.shared.open(SelwayLinks.repository)
                }
                .buttonStyle(.link)

                Spacer()

                Button("Continue") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460 * textScale)
    }
}
