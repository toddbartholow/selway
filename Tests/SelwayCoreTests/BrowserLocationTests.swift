import Foundation
import Testing
@testable import SelwayCore

@Suite struct BrowserLocationTests {
    @Test func folderIdentityUsesShellPathKeys() {
        let plain = BrowserLocation.folder(URL(fileURLWithPath: "/tmp/location/folder"))
        let trailingSlash = BrowserLocation.folder(URL(fileURLWithPath: "/tmp/location/folder/"))
        #expect(plain == trailingSlash)
        #expect(BrowserLocation.folder(URL(fileURLWithPath: "/tmp/location/./folder")) == plain)
        #expect(BrowserLocation.folder(URL(fileURLWithPath: "/tmp/location/link"))
                != .folder(URL(fileURLWithPath: "/tmp/location/target")))
        #expect(Set([plain, trailingSlash]).count == 1)
        #expect(plain != .computer)
        #expect(BrowserLocation.computer == .computer)
        #expect(plain.folder?.path == "/tmp/location/folder")
        #expect(BrowserLocation.computer.folder == nil)
    }

    @Test func policyAllowsCopyPathAtComputerForASelectedVolume() {
        let folder = BrowserLocation.folder(URL(fileURLWithPath: "/tmp"))
        for command in LocationCommand.allCases {
            #expect(folder.allows(command))
            #expect(BrowserLocation.computer.allows(command) == (command == .copyPath))
        }
    }

    @Test func readOnlyFoldersAllowOnlyNonMutatingBrowserCommands() {
        let folder = BrowserLocation.folder(URL(fileURLWithPath: "/Volumes/Backup Disk"))
        for command in LocationCommand.allCases {
            let allowed = [.copyPath, .openInTool, .refresh, .find].contains(command)
            #expect(folder.allows(command, readOnly: true) == allowed)
        }
    }
}
