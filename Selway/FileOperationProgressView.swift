import SwiftUI
import AppKit

// MARK: - Progress for long file operations
//
// FileOperationsService publishes `activeOperation` when a paste, duplicate,
// trash, delete, compress, extract or tag operation has been running for a
// moment. ContentView shows it with:
//
//     .overlay(alignment: .bottom) { FileOperationProgressStrip(fileOps: fileOps) }
//
// placed so it sits above the status bar, like the toast (bottom padding ~42).

/// Shows the running operation, if any. Renders nothing visible while idle.
/// It also tells the service which window it lives in, so errors from an
/// operation that outlives its window still reach the user.
struct FileOperationProgressStrip: View {
    @ObservedObject var fileOps: FileOperationsService
    @Environment(\.textScale) private var textScale

    var body: some View {
        ZStack(alignment: .bottom) {
            HostWindowReader { [weak fileOps] window in fileOps?.attach(to: window) }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            if let operation = fileOps.activeOperation {
                FileOperationProgressView(operation: operation)
                    .padding(.bottom, 42 * textScale)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(operation.id)
            }
        }
    }
}

/// Reports the NSWindow it is placed in.
private struct HostWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One operation: what it is doing, a bar (determinate when the item count is
/// known), and Cancel.
struct FileOperationProgressView: View {
    @ObservedObject var operation: FileOperationProgress
    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(headline)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = operation.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .frame(minWidth: 220 * textScale, maxWidth: 340 * textScale)

            Button(operation.isCancelling ? "Cancelling…" : "Cancel") { operation.cancel() }
                .controlSize(.small)
                .disabled(operation.isCancelling)
                .help("Stop after the current item")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    private var headline: String {
        var text = operation.title
        if operation.total > 1 {
            text += " " + String(localized: "\(min(operation.completed + 1, operation.total)) of \(operation.total)",
                                   comment: "Current item number and total in a file operation.")
        }
        if !operation.currentName.isEmpty {
            text = String(localized: "\(text): “\(operation.currentName)”", comment: "File operation progress headline with the current item name")
        }
        return text
    }
}
