import Foundation
import Testing
@testable import SelwayCore

@Suite struct ShellFileDragURLsTests {
    let a = FileItem.fixture("a.txt")
    let b = FileItem.fixture("b.md")
    let c = FileItem.fixture("c.zip")
    var files: [FileItem] { [a, b, c] }

    @Test func anUnselectedItemDragsAlone() {
        #expect(ShellFileDrag.urls(dragging: b, in: files, selection: [a.id, c.id]) == [b.url])
    }

    @Test func aSelectedItemDragsTheSelectionClickedItemFirst() {
        #expect(ShellFileDrag.urls(dragging: c, in: files, selection: [a.id, b.id, c.id])
                == [c.url, a.url, b.url])
    }

    @Test func theOnlySelectedItemDragsAlone() {
        #expect(ShellFileDrag.urls(dragging: a, in: files, selection: [a.id]) == [a.url])
    }

    /// Regression: an icon pressed and moved by a point or two while the
    /// button was down started a drag, and the click was lost: it didn't select.
    @Test func aPressMovedByAFewPointsIsStillAClick() {
        #expect(!ShellFileDrag.startsDrag(dx: 0, dy: 0))
        #expect(!ShellFileDrag.startsDrag(dx: 1, dy: 0))
        #expect(!ShellFileDrag.startsDrag(dx: 3, dy: 0))
        #expect(!ShellFileDrag.startsDrag(dx: -2, dy: 2))
        #expect(!ShellFileDrag.startsDrag(dx: 0, dy: -4))
    }

    @Test func aPressMovedFurtherIsADrag() {
        #expect(ShellFileDrag.startsDrag(dx: 5, dy: 0))
        #expect(ShellFileDrag.startsDrag(dx: 0, dy: -5))
        #expect(ShellFileDrag.startsDrag(dx: 3, dy: 3))
    }

    @Test func dedupeKeepsTheFirstOfEachPath() {
        #expect(ShellFileDrag.dedupe([a.url, b.url, a.url]) == [a.url, b.url])
    }
}

#if canImport(Darwin)
/// Regression: a .md file dragged to the Desktop arrived as "Markdown
/// Document.md". The provider offered the file's contents typed as Markdown
/// (NSItemProvider(contentsOf:)), which Finder wrote to a new file named after
/// the type. It must offer the file's URL only, named after the file.
@Suite struct ShellFileDragProviderTests {
    let url = URL(fileURLWithPath: "/private/tmp/Selway Fixture/systems-audit-2026-10-09.md")

    @Test func offersTheFileURLAndNoContents() {
        let types = ShellFileDrag.itemProvider(for: url).registeredTypeIdentifiers
        #expect(types.contains("public.file-url"))
        #expect(!types.contains("net.daringfireball.markdown"))
        // URL types only: nothing a receiver could write out as a new file.
        #expect(types.allSatisfy { $0 == "public.file-url" || $0 == "public.url" })
    }

    @Test func isNamedAfterTheFileWithItsExtension() {
        #expect(ShellFileDrag.itemProvider(for: url).suggestedName == "systems-audit-2026-10-09.md")
    }

    @Test func aFolderIsNamedAfterTheFolder() {
        let folder = URL(fileURLWithPath: "/private/tmp/Selway Fixture/Reports", isDirectory: true)
        #expect(ShellFileDrag.itemProvider(for: folder).suggestedName == "Reports")
    }

    @Test func handsOverTheSameURL() async throws {
        let provider = ShellFileDrag.itemProvider(for: url)
        let loaded: URL? = try await withCheckedThrowingContinuation { cont in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: object as? URL) }
            }
        }
        #expect(loaded == url)
    }

    /// One provider is one drag item: given several files it carries the
    /// first (the clicked one), by URL and name.
    @Test func severalURLsGiveTheFirstFile() {
        let other = URL(fileURLWithPath: "/private/tmp/Selway Fixture/other.zip")
        let provider = ShellFileDrag.itemProvider(for: [url, other, url])
        #expect(provider.suggestedName == "systems-audit-2026-10-09.md")
        #expect(provider.registeredTypeIdentifiers.contains("public.file-url"))
    }

    @Test func noURLsGiveAnEmptyProvider() {
        #expect(ShellFileDrag.itemProvider(for: [URL]()).registeredTypeIdentifiers.isEmpty)
    }
}
#endif
