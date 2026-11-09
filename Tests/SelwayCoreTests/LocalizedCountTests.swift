import Testing
@testable import SelwayCore

struct LocalizedCountTests {
    @Test func missingCatalogKeepsEnglishSingularAndPluralForms() {
        let items = { (n: Int) in LocalizedCount.string(n, "%lld items", one: "%lld item", other: "%lld items") }
        #expect(items(0) == "0 items")
        #expect(items(1) == "1 item")
        #expect(items(3) == "3 items")
        // A catalog's plural format is used as it is.
        #expect(LocalizedCount.string(1, "%lld Stück", one: "%lld item", other: "%lld items") == "1 Stück")
    }

    @Test func quarantineFailureKeepsItsEnglishSentence() {
        #expect(FileOpsError.quarantineFailed(0).errorDescription
                == "Couldn’t mark 0 extracted items as downloaded, so the extraction was stopped to keep Gatekeeper checks in place.")
        #expect(FileOpsError.quarantineFailed(1).errorDescription
                == "Couldn’t mark 1 extracted item as downloaded, so the extraction was stopped to keep Gatekeeper checks in place.")
        #expect(FileOpsError.quarantineFailed(3).errorDescription
                == "Couldn’t mark 3 extracted items as downloaded, so the extraction was stopped to keep Gatekeeper checks in place.")
    }

    @Test func countSelectedAlertSentencesKeepTheirEnglishForms() {
        #expect(FileOpsDeleteText.permanentDetail(count: 0)
                == "These items will be deleted immediately. You can’t undo this action, and they won’t be in the Trash.")
        #expect(FileOpsDeleteText.permanentDetail(count: 1)
                == "This item will be deleted immediately. You can’t undo this action, and it won’t be in the Trash.")
        #expect(FileOpsDeleteText.permanentDetail(count: 3)
                == "These items will be deleted immediately. You can’t undo this action, and they won’t be in the Trash.")
        #expect(FileOpsDeleteText.noTrashDetail(count: 1)
                == "The volume it’s on doesn’t have a Trash. Deleting permanently can’t be undone.")
        #expect(FileOpsDeleteText.noTrashDetail(count: 3)
                == "The volume they’re on doesn’t have a Trash. Deleting permanently can’t be undone.")
        #expect(ShellOpenTarget.unreachableAlert(names: ["A"]).detail
                == "The item it links to can’t be found, or its server isn’t answering.")
        #expect(ShellOpenTarget.unreachableAlert(names: ["A", "B", "C"]).detail
                == "The items they link to can’t be found, or their servers aren’t answering.")
    }
}
