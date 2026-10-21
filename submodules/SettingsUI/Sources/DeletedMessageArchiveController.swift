import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private enum RetentionSettingsEntry: ItemListNodeEntry {
    case enabled(Bool, Bool)

    var section: ItemListSectionId { return 0 }
    var stableId: Int32 {
        switch self {
        case .enabled: return 0
        }
    }
    static func <(lhs: RetentionSettingsEntry, rhs: RetentionSettingsEntry) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let update = arguments as! (Bool) -> Void
        switch self {
        case let .enabled(value, ru):
            let title = ru ? "Сохранять удалённые" : "Keep Deleted Messages"
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, maximumNumberOfLines: 1, sectionId: self.section, style: .blocks, updated: update)
        }
    }
}

public func deletedMessageArchiveController(context: AccountContext) -> ViewController {
    let update: (Bool) -> Void = { value in
        let _ = updateDeletedMessageRetentionSettings(postbox: context.account.postbox, enabled: value).start()
    }
    let signal = combineLatest(context.sharedContext.presentationData, deletedMessageRetentionSettings(postbox: context.account.postbox))
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let ru = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(ru ? "Удалённые сообщения" : "Deleted Messages"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: [.enabled(settings.enabled, ru)], style: .blocks, animateChanges: false)
        return (state, (list, update))
    }
    return ItemListController(context: context, state: signal)
}
