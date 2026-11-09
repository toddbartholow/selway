import SwiftUI
import AppKit

struct PathBarView: View {
    @Binding var location: BrowserLocation
    /// Bumped by Go → Go to Folder… (⇧⌘G) to open the path editor.
    var editRequest = 0
    /// Set when Go to Folder… showed a hidden path bar: open the editor on appear.
    @Binding var editPending: Bool
    /// The window's, which copies the path with its toast.
    @Environment(\.fileOperations) private var fileOps
    /// The editor closed (a folder gone to, Escape, a click elsewhere). A bar shown
    /// only for Go to Folder… hides again then.
    var onEditingEnded: () -> Void = {}
    /// In a window with two panes, whether this bar's pane is the active one
    /// (its header is highlighted); nil in a window with one.
    var isActivePane: Bool?
    @State private var isEditing = false
    /// Bumped by every edit start, so a stale focus check can't end a newer edit.
    @State private var editAttempt = 0
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: location == .computer ? "desktopcomputer" : "folder.fill")
                .foregroundStyle(.secondary)
                .scaledFont(.caption)

            if isEditing {
                TextField("Path", text: $editText)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 12, design: .monospaced)
                    .resetsCursorOnExit()
                    .focused($editFocused)
                    .browserTextInput()
                    .onSubmit { commitEdit() }
                    .onExitCommand { isEditing = false }
                    // Clicking elsewhere ends editing instead of leaving a dead field.
                    .onChange(of: editFocused) { _, focused in
                        if !focused { isEditing = false }
                    }
            } else {
                if let currentPath = location.folder {
                    breadcrumbs(currentPath)
                } else {
                    Text(location.displayName)
                        .scaledFont(size: 12)
                }
            }

            Spacer()

            Button { copyPathToClipboard() } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Copy full path")
            .accessibilityLabel("Copy Path")
            .disabled(!location.allows(.copyPath))
        }
        .onChange(of: editRequest) { _, _ in startEditing() }
        .onChange(of: isEditing) { _, editing in if !editing { onEditingEnded() } }
        .onAppear {
            if editPending { editPending = false; startEditing() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { PaneHeaderBackground(isActive: isActivePane) }
        .overlay(alignment: .bottom) { PaneHeaderEdge(isActive: isActivePane) }
        // One group VoiceOver calls "Path", holding the folder buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
        .accessibilityIdentifier("pathBar")
    }

    private func breadcrumbs(_ currentPath: URL) -> some View {
        ScrollViewReader { proxy in
        // Inside a Time Machine backup, the segments run from its disk rather
        // than through /Volumes/.timemachine (TimeMachineBackups).
        let components = TimeMachineBackups.live.breadcrumbs(for: currentPath)
            ?? ShellPath.ancestorChain(currentPath).map { ($0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent, $0) }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(components.indices, id: \.self) { index in
                    let (name, component) = components[index]
                    Button {
                        location = .folder(component)
                    } label: {
                        let isCurrent = ShellPath.same(component, currentPath)
                        Text(name)
                            // The active pane's folder in semibold: which pane
                            // is active, told by more than colour.
                            .scaledFont(size: 12, weight: isCurrent && isActivePane == true ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .id(component.path)

                    if index + 1 < components.count {
                        Image(systemName: "chevron.forward")
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        // A deep path keeps the folder shown in view, not the top of the disk.
        .onAppear { scrollToCurrent(proxy, path: currentPath) }
        .onChange(of: location) { _, _ in scrollToCurrent(proxy, path: currentPath) }
        }
        .onTapGesture(count: 2) { startEditing() }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, path: URL) {
        guard let last = ShellPath.ancestorChain(path).last else { return }
        DispatchQueue.main.async { proxy.scrollTo(last.path, anchor: .trailing) }
    }

    private func startEditing() {
        editText = location.folder?.path ?? ""
        isEditing = true
        editAttempt += 1
        let attempt = editAttempt
        DispatchQueue.main.async { editFocused = true }
        // A field that never got focus (the window wasn't key) would sit open, and
        // a bar shown just for Go to Folder… would stay: losing focus is what ends
        // an edit, and it never had any.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if editAttempt == attempt, isEditing, !editFocused { isEditing = false }
        }
    }

    private func commitEdit() {
        let expanded = NSString(string: editText.trimmingCharacters(in: .whitespacesAndNewlines))
            .expandingTildeInPath
        // Relative paths are relative to the folder being shown, not the
        // process's working directory (or its parent, for a symlinked folder).
        let url = ShellPath.resolveTyped(expanded, relativeTo: location.folder ?? URL(fileURLWithPath: "/", isDirectory: true))
        guard FileItem.isBrowsableFolder(url) else {
            NSSound.beep()          // keep the field open so the typo can be fixed
            return
        }
        location = .folder(url)
        isEditing = false
    }

    /// As the toolbar's and context menu's Copy Path copy it, with the same
    /// "Path copied" toast.
    private func copyPathToClipboard() {
        guard let currentPath = location.folder else { return }
        if let fileOps {
            fileOps.copyPath(currentPath.path)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(currentPath.path, forType: .string)
        }
    }
}
