import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private enum RetentionSettingsEntry: ItemListNodeEntry {
    case deletedMessages(Bool, Bool)
    case editHistory(Bool, Bool)
    case info(Bool)

    var section: ItemListSectionId { return 0 }
    var stableId: Int32 {
        switch self {
        case .deletedMessages: return 0
        case .editHistory: return 1
        case .info: return 2
        }
    }
    static func <(lhs: RetentionSettingsEntry, rhs: RetentionSettingsEntry) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let updates = arguments as! (deletedMessages: (Bool) -> Void, editHistory: (Bool) -> Void)
        switch self {
        case let .deletedMessages(value, ru):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: ru ? "Сохранять удалённые" : "Keep deleted messages", text: ru ? "Оставляет загруженную копию в чате." : "Keeps a downloaded copy in the chat.", value: value, sectionId: self.section, style: .blocks, updated: updates.deletedMessages)
        case let .editHistory(value, ru):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: ru ? "История правок" : "Edit history", text: ru ? "Сохраняет прежний текст на устройстве." : "Keeps previous message text on this device.", value: value, sectionId: self.section, style: .blocks, updated: updates.editHistory)
        case let .info(ru):
            return ItemListTextItem(presentationData: presentationData, text: .plain(ru ? "Сохраняются только сообщения, которые приложение успело получить. История правок открывается из меню сообщения." : "Only messages received by the app can be kept. Open edit history from a message menu."), sectionId: self.section)
        }
    }
}

public func deletedMessageArchiveController(context: AccountContext) -> ViewController {
    let updateDeletedMessages: (Bool) -> Void = { value in
        let _ = updateDeletedMessageRetentionSettings(postbox: context.account.postbox, enabled: value).start()
    }
    let updateEditHistory: (Bool) -> Void = { value in
        let _ = updateAfterGramEditHistorySettings(postbox: context.account.postbox, enabled: value).start()
    }
    let signal = combineLatest(context.sharedContext.presentationData, deletedMessageRetentionSettings(postbox: context.account.postbox), afterGramEditHistorySettings(postbox: context.account.postbox))
    |> deliverOnMainQueue
    |> map { presentationData, deletedSettings, editSettings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let ru = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(ru ? "История сообщений" : "Message history"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let entries: [RetentionSettingsEntry] = [
            .deletedMessages(deletedSettings.enabled, ru),
            .editHistory(editSettings.enabled, ru),
            .info(ru)
        ]
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        let updates = (deletedMessages: updateDeletedMessages, editHistory: updateEditHistory)
        return (state, (list, updates))
    }
    return ItemListController(context: context, state: signal)
}
