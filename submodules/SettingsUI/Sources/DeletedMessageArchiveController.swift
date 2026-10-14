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
    case info(Bool)

    var section: ItemListSectionId { return 0 }
    var stableId: Int32 {
        switch self {
        case .enabled: return 0
        case .info: return 1
        }
    }
    static func <(lhs: RetentionSettingsEntry, rhs: RetentionSettingsEntry) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let update = arguments as! (Bool) -> Void
        switch self {
        case let .enabled(value, ru):
            return ItemListSwitchItem(presentationData: presentationData, title: ru ? "Сохранять удалённые сообщения" : "Keep Deleted Messages", value: value, sectionId: self.section, style: .blocks, updated: update)
        case let .info(ru):
            return ItemListTextItem(presentationData: presentationData, text: .plain(ru ? "Удалённые сообщения остаются в чате с прозрачностью 50% и значком корзины. Медиа из открытого чата заранее скачиваются и сохраняются отдельно от обычного кэша — это расходует трафик и память устройства. Для просмотра после удаления файл должен успеть загрузиться. Уже сохранённые сообщения можно удалить вручную. Отключение не удаляет накопленные копии." : "Deleted messages remain in the chat at 50% opacity with a trash icon. Media in an opened chat are downloaded ahead of time and stored outside the normal cache, using network data and device storage. Playback after deletion requires the file to finish downloading. You can manually delete retained messages. Disabling keeps existing copies."), sectionId: self.section)
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
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: [RetentionSettingsEntry.enabled(settings.enabled, ru), .info(ru)], style: .blocks, animateChanges: false)
        return (state, (list, update))
    }
    return ItemListController(context: context, state: signal)
}
