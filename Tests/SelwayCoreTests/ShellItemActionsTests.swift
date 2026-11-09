import Foundation
import Testing
@testable import SelwayCore

@Suite struct ShellCopyPathTests {
    let folder = URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true)
    let a = URL(fileURLWithPath: "/Users/me/Projects/a.txt")
    let app = URL(fileURLWithPath: "/Users/me/Projects/App", isDirectory: true)

    /// Regression: ⌥⌘C copied the folder being viewed even with items selected.
    @Test func copiesTheSelectedItemsOnePerLine() {
        #expect(ShellCopyPath.text(selected: [a, app], folder: folder)
                == "/Users/me/Projects/a.txt\n/Users/me/Projects/App")
    }

    @Test func copiesTheFolderWhenNothingIsSelected() {
        #expect(ShellCopyPath.text(selected: [], folder: folder) == "/Users/me/Projects")
    }

    @Test func nothingToCopyWithoutSelectionOrFolder() {
        #expect(ShellCopyPath.text(selected: [], folder: nil) == nil)
    }

    @Test func keepsTheSelectionsOrder() {
        #expect(ShellCopyPath.text(selected: [app, a], folder: nil)
                == "/Users/me/Projects/App\n/Users/me/Projects/a.txt")
    }
}

@Suite struct ShellNewItemTargetTests {
    let here = URL(fileURLWithPath: "/Users/me/Projects", isDirectory: true)
    let app = URL(fileURLWithPath: "/Users/me/Projects/App", isDirectory: true)

    /// Regression: with one folder selected, New Folder (toolbar, ⌥⌘N) created the
    /// new folder inside it and then navigated there. Finder puts it beside the
    /// selection, in the folder being shown.
    @Test func newFolderGoesIntoTheFolderShownWhateverIsSelected() {
        #expect(ShellNewItemTarget.destination(showing: here) == here)
    }

    @Test func anExplicitFolderIsUsedAsIs() {
        #expect(ShellNewItemTarget.destination(showing: here, inside: app) == app)
    }

    @Test func theCreatedItemIsSelectedWhenItLandsInTheFolderShown() {
        #expect(ShellNewItemTarget.selectsCreated(here.appendingPathComponent("New Folder"), showing: here))
        // Compared by path: the folder shown may carry a trailing slash or not.
        #expect(ShellNewItemTarget.selectsCreated(URL(fileURLWithPath: "/Users/me/Projects/x"),
                                                  showing: URL(fileURLWithPath: "/Users/me/Projects")))
    }

    /// Creating somewhere else never takes the window there.
    @Test func elsewhereItIsNotSelected() {
        #expect(!ShellNewItemTarget.selectsCreated(app.appendingPathComponent("New Folder"), showing: here))
    }
}

/// Regression: the Share picker opened at the window's bottom-left corner instead
/// of where the item was right-clicked.
@Suite struct ShellPopoverAnchorTests {
    let content = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 800, height: 600))
    let window = 7

    /// CGPoint's `==` comes from CoreGraphics, which the Linux build doesn't have.
    private func same(_ p: CGPoint, _ x: CGFloat, _ y: CGFloat) -> Bool { p.x == x && p.y == y }

    private func click(_ x: CGFloat, _ y: CGFloat, window: Int = 7, at time: TimeInterval = 100)
        -> ShellPopoverAnchor.Click {
        ShellPopoverAnchor.Click(window: window, point: CGPoint(x: x, y: y), time: time)
    }

    @Test func opensWhereTheMenuWasOpened() {
        let p = ShellPopoverAnchor.point(lastClick: click(120, 340), window: window, now: 103,
                                         mouse: CGPoint(x: 500, y: 500), content: content)
        #expect(same(p, 120, 340))
    }

    @Test func aClickInAnotherWindowIsIgnored() {
        let p = ShellPopoverAnchor.point(lastClick: click(120, 340, window: 3), window: window, now: 103,
                                         mouse: CGPoint(x: 500, y: 500), content: content)
        #expect(same(p, 500, 500))
    }

    /// A menu opened from the keyboard long after the last right-click.
    @Test func anOldClickIsIgnored() {
        let p = ShellPopoverAnchor.point(lastClick: click(120, 340, at: 100),
                                         window: window, now: 100 + ShellPopoverAnchor.maxAge + 1,
                                         mouse: CGPoint(x: 500, y: 500), content: content)
        #expect(same(p, 500, 500))
    }

    @Test func aClickOutsideTheContentIsIgnored() {
        // The title bar or toolbar, above the content.
        let p = ShellPopoverAnchor.point(lastClick: click(120, 640), window: window, now: 103,
                                         mouse: nil, content: content)
        #expect(same(p, 400, 300))
    }

    @Test func withNoClickOrPointerInsideItOpensInTheMiddle() {
        let p = ShellPopoverAnchor.point(lastClick: nil, window: window, now: 103,
                                         mouse: CGPoint(x: -20, y: 900), content: content)
        #expect(same(p, 400, 300))
        let offset = CGRect(origin: CGPoint(x: 100, y: 50), size: CGSize(width: 200, height: 100))
        #expect(same(ShellPopoverAnchor.point(lastClick: nil, window: window, now: 0, mouse: nil, content: offset),
                     200, 100))
    }
}

/// Regression: Open (a double-click, Return in the lists, the context menu) acted
/// only on the first selected item.
@Suite struct ShellOpenPlanTests {
    private func plan(_ items: [String], folders: ShellFolderDestination = .here) -> ShellOpenPlan<String> {
        ShellOpenPlan(items, isFolder: { $0.hasSuffix("/") }, folders: folders)
    }

    @Test func oneFolderIsShownInThisWindow() {
        let p = plan(["Docs/"])
        #expect(p.navigate == "Docs/")
        #expect(p.newWindows.isEmpty && p.files.isEmpty)
        #expect(!p.needsConfirmation)
    }

    @Test func oneFolderOpensInANewWindowWhenSettingsSaySo() {
        let p = plan(["Docs/"], folders: .newWindows)
        #expect(p.navigate == nil)
        #expect(p.newWindows == ["Docs/"])
        #expect(p.newTabs.isEmpty)
    }

    @Test func oneFolderOpensInANewTabWhenSettingsSaySo() {
        let p = plan(["Docs/"], folders: .newTabs)
        #expect(p.navigate == nil)
        #expect(p.newWindows.isEmpty)
        #expect(p.newTabs == ["Docs/"])
        #expect(p.openCount == 1)
    }

    /// Opening folders in tabs opens them all as tabs, in order, and files still
    /// open in their apps.
    @Test func severalFoldersEachOpenInANewTabWhenSettingsSaySo() {
        let p = plan(["A/", "a.txt", "B/", "C/"], folders: .newTabs)
        #expect(p.navigate == nil)
        #expect(p.newWindows.isEmpty)
        #expect(p.newTabs == ["A/", "B/", "C/"])
        #expect(p.files == ["a.txt"])
        #expect(p.openCount == 4)
    }

    /// Tabs count towards asking first, as windows do.
    @Test func manyTabsAskFirst() {
        let limit = ShellOpenPlanLimit.confirmAbove
        #expect(!plan((0..<limit).map { "D\($0)/" }, folders: .newTabs).needsConfirmation)
        #expect(plan((0...limit).map { "D\($0)/" }, folders: .newTabs).needsConfirmation)
    }

    @Test func severalFoldersEachOpenInANewWindow() {
        let p = plan(["A/", "B/", "C/"])
        #expect(p.navigate == nil)
        #expect(p.newWindows == ["A/", "B/", "C/"])
        #expect(p.newTabs.isEmpty)
        #expect(plan(["A/", "B/"], folders: .newWindows).newWindows == ["A/", "B/"])
    }

    @Test func everyFileIsOpenedInOrder() {
        let p = plan(["a.txt", "b.png", "c.md"])
        #expect(p.files == ["a.txt", "b.png", "c.md"])
        #expect(p.navigate == nil && p.newWindows.isEmpty && p.newTabs.isEmpty)
        #expect(plan(["a.txt"], folders: .newTabs).files == ["a.txt"])
    }

    /// The window goes to the folder and the files open as well.
    @Test func oneFolderWithFilesShowsTheFolderAndOpensTheFiles() {
        let p = plan(["a.txt", "Docs/", "b.txt"])
        #expect(p.navigate == "Docs/")
        #expect(p.files == ["a.txt", "b.txt"])
        #expect(p.openCount == 2)
    }

    @Test func nothingSelectedOpensNothing() {
        let p = plan([])
        #expect(p.isEmpty)
        #expect(!p.needsConfirmation)
    }

    /// Before a link the listing didn't follow is followed, Open counts the
    /// most it could open: as a file it's one app; as a folder, one window,
    /// and the folder that would be shown here gets a window of its own.
    @Test func theMostOpenedCountsUnfollowedLinksAtWorst() {
        func most(_ items: [String], folders: ShellFolderDestination = .here) -> Int {
            ShellOpenPlan.mostOpened(items, isFolder: { $0.hasSuffix("/") }, isUnknown: { $0.hasPrefix("?") },
                                     folders: folders)
        }
        #expect(most(["a.txt", "Docs/"]) == plan(["a.txt", "Docs/"]).openCount)
        #expect(most(["?l"]) == 1)
        #expect(most(["Docs/", "?l"]) == 2)                 // both folders: two windows
        #expect(plan(["Docs/", "?l/"]).openCount == 2)
        #expect(most(["Docs/", "?l"], folders: .newWindows) == 2)
        #expect(most(["Docs/", "?l"], folders: .newTabs) == 2)
        #expect(most(["a.txt", "?l"]) == 2)
        // The worst case is never under what the links turn out to be.
        for resolved in [["Docs/", "?l/", "a.txt"], ["Docs/", "?l", "a.txt"]] {
            #expect(most(["Docs/", "?l", "a.txt"]) >= plan(resolved).openCount)
        }
    }

    @Test func asksFirstAboveTheThreshold() {
        let limit = ShellOpenPlanLimit.confirmAbove
        let files = (0..<limit).map { "f\($0).txt" }
        #expect(!plan(files).needsConfirmation)
        #expect(plan(files + ["one more.txt"]).needsConfirmation)
        #expect(plan((0...limit).map { "D\($0)/" }).needsConfirmation)
    }

    /// The folder shown in this window opens no window, so it doesn't count.
    @Test func theFolderShownHereDoesntCountTowardsAsking() {
        let files = (0..<ShellOpenPlanLimit.confirmAbove).map { "f\($0).txt" }
        let p = plan(files + ["Docs/"])
        #expect(p.navigate == "Docs/")
        #expect(!p.needsConfirmation)
    }

    @Test func theQuestionNamesTheCount() {
        #expect(ShellOpenPlanLimit.question(count: 25) == "Are you sure you want to open 25 items?")
    }
}
