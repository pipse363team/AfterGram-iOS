import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences

private final class AfterGramVoiceEffectControllerArguments {
    let updateSelection: (AfterGramVoiceEffect) -> Void

    init(updateSelection: @escaping (AfterGramVoiceEffect) -> Void) {
        self.updateSelection = updateSelection
    }
}

private enum AfterGramVoiceEffectEntry: ItemListNodeEntry {
    case option(AfterGramVoiceEffect, String, Bool)
    case info(String)

    var section: ItemListSectionId { 0 }

    var stableId: Int32 {
        switch self {
        case let .option(effect, _, _):
            return Int32(effect.rawValue)
        case .info:
            return 10
        }
    }

    static func == (lhs: AfterGramVoiceEffectEntry, rhs: AfterGramVoiceEffectEntry) -> Bool {
        switch lhs {
        case let .option(lhsEffect, lhsTitle, lhsSelected):
            if case let .option(rhsEffect, rhsTitle, rhsSelected) = rhs {
                return lhsEffect == rhsEffect && lhsTitle == rhsTitle && lhsSelected == rhsSelected
            }
            return false
        case let .info(lhsText):
            if case let .info(rhsText) = rhs {
                return lhsText == rhsText
            }
            return false
        }
    }

    static func < (lhs: AfterGramVoiceEffectEntry, rhs: AfterGramVoiceEffectEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AfterGramVoiceEffectControllerArguments
        switch self {
        case let .option(effect, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.updateSelection(effect)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func afterGramVoiceEffectEntries(isRussian: Bool, selected: AfterGramVoiceEffect) -> [AfterGramVoiceEffectEntry] {
    let choices: [(AfterGramVoiceEffect, String)]
    let info: String
    if isRussian {
        choices = [
            (.off, "Выкл · исходный голос"),
            (.radio, "Радио · узкий радиодиапазон"),
            (.robot, "Робот · синтетическая модуляция"),
            (.bass, "Бас · более низкое и плотное звучание")
        ]
        info = "Эффект обрабатывает голосовое сообщение на устройстве. На звонки и видеокружки он не влияет."
    } else {
        choices = [
            (.off, "Off · original voice"),
            (.radio, "Radio · narrow radio tone"),
            (.robot, "Robot · synthetic modulation"),
            (.bass, "Bass · warmer, fuller sound")
        ]
        info = "Voice messages are processed on this device. Calls and round videos are unchanged."
    }

    let optionEntries: [AfterGramVoiceEffectEntry] = choices.map { choice in
        return .option(choice.0, choice.1, choice.0 == selected)
    }
    return optionEntries + [.info(info)]
}

/// The shared AfterGram settings entry can route here. The stored choice is consumed by the
/// TelegramUI voice-message recorder; effects never route audio through a network service.
public func afterGramVoiceEffectController(context: AccountContext) -> ViewController {
    let selectedPromise = ValuePromise<AfterGramVoiceEffect>(AfterGramVoiceEffect.selected, ignoreRepeated: true)
    let arguments = AfterGramVoiceEffectControllerArguments(updateSelection: { effect in
        AfterGramVoiceEffect.updateSelection(effect)
        selectedPromise.set(effect)
    })

    let signal = combineLatest(context.sharedContext.presentationData, selectedPromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, selected -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let isRussian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let title = isRussian ? "Голосовой эффект" : "Voice Effect"
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: afterGramVoiceEffectEntries(isRussian: isRussian, selected: selected), style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
