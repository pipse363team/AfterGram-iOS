import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences

private enum AfterGramOption {
    case profileTab
    case onlineMarkers
    case clearGlass
    case giftGlow
}

private final class AfterGramOptionsControllerArguments {
    let update: (AfterGramOption, Bool) -> Void
    let openVoiceEffect: () -> Void
    let openMessageHistory: () -> Void
    let openMessageAppearance: () -> Void

    init(update: @escaping (AfterGramOption, Bool) -> Void, openVoiceEffect: @escaping () -> Void, openMessageHistory: @escaping () -> Void, openMessageAppearance: @escaping () -> Void) {
        self.update = update
        self.openVoiceEffect = openVoiceEffect
        self.openMessageHistory = openMessageHistory
        self.openMessageAppearance = openMessageAppearance
    }
}

private enum AfterGramOptionsEntry: ItemListNodeEntry, Equatable {
    case profileTab(Bool, Bool)
    case onlineMarkers(Bool, Bool)
    case clearGlass(Bool, Bool)
    case giftGlow(Bool, Bool)
    case voiceEffect(String, Bool)
    case messageAppearance(Bool)
    case messageHistory(Bool)

    var section: ItemListSectionId { 0 }

    var stableId: Int32 {
        switch self {
        case .profileTab: return 0
        case .onlineMarkers: return 1
        case .clearGlass: return 2
        case .giftGlow: return 3
        case .voiceEffect: return 4
        case .messageAppearance: return 5
        case .messageHistory: return 6
        }
    }

    static func < (lhs: AfterGramOptionsEntry, rhs: AfterGramOptionsEntry) -> Bool {
        lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AfterGramOptionsControllerArguments
        switch self {
        case let .profileTab(enabled, isRussian):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Вкладка профиля" : "Profile tab", text: isRussian ? "Добавляет ваш профиль в нижнюю панель." : "Adds your profile to the bottom tab bar.", value: enabled, sectionId: self.section, style: .blocks, updated: { arguments.update(.profileTab, $0) })
        case let .onlineMarkers(enabled, isRussian):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Индикатор онлайн" : "Online indicators", text: isRussian ? "Показывает онлайн у личных чатов и активный голосовой чат. Состав группы онлайн не раскрывается." : "Shows online contacts and active group calls. Telegram does not expose which group members are online.", value: enabled, sectionId: self.section, style: .blocks, updated: { arguments.update(.onlineMarkers, $0) })
        case let .clearGlass(enabled, isRussian):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Прозрачное стекло" : "Clear glass", text: isRussian ? "Вкл — прозрачный вариант. Выкл — штатный выбор эффекта по фону." : "On uses the clear variant. Off restores Telegram’s wallpaper-based choice.", value: enabled, sectionId: self.section, style: .blocks, updated: { arguments.update(.clearGlass, $0) })
        case let .giftGlow(enabled, isRussian):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Свечение подарков" : "Gift glow", text: isRussian ? "Добавляет мягкое свечение подаркам в профиле." : "Adds a soft glow to gifts on profile covers.", value: enabled, sectionId: self.section, style: .blocks, updated: { arguments.update(.giftGlow, $0) })
        case let .voiceEffect(value, isRussian):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Голосовой эффект" : "Voice effect", label: value, labelStyle: .text, additionalDetailLabel: isRussian ? "Меняет новые голосовые сообщения на устройстве." : "Changes new voice messages on this device.", sectionId: self.section, style: .blocks, action: {
                arguments.openVoiceEffect()
            })
        case let .messageAppearance(isRussian):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Пузыри сообщений" : "Message bubbles", label: "", labelStyle: .text, additionalDetailLabel: isRussian ? "Настрой форму сообщений с живым предпросмотром." : "Adjust bubble shape with a live preview.", sectionId: self.section, style: .blocks, action: {
                arguments.openMessageAppearance()
            })
        case let .messageHistory(isRussian):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "История сообщений" : "Message history", label: "", labelStyle: .text, additionalDetailLabel: isRussian ? "Удалённые сообщения и сохранённые версии правок." : "Deleted messages and saved edit history.", sectionId: self.section, style: .blocks, action: {
                arguments.openMessageHistory()
            })
        }
    }
}

public func afterGramOptionsController(context: AccountContext) -> ViewController {
    let update: (AfterGramOption, Bool) -> Void = { option, value in
        let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
            var settings = current
            switch option {
            case .profileTab:
                settings.afterGramShowProfileTab = value
            case .onlineMarkers:
                settings.afterGramShowOnlineMarkers = value
            case .clearGlass:
                settings.forceClearGlass = value
            case .giftGlow:
                settings.afterGramGiftGlow = value
            }
            return settings
        }).start()
    }

    let controllerReference = Atomic<ViewController?>(value: nil)
    let arguments = AfterGramOptionsControllerArguments(update: update, openVoiceEffect: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        controller.navigationController?.pushViewController(afterGramVoiceEffectController(context: context), animated: true)
    }, openMessageHistory: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        controller.navigationController?.pushViewController(deletedMessageArchiveController(context: context), animated: true)
    }, openMessageAppearance: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        let _ = (context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.presentationThemeSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) ?? PresentationThemeSettings.defaultSettings
            controller.navigationController?.pushViewController(BubbleSettingsController(context: context, presentationThemeSettings: settings), animated: true)
        })
    })

    let signal = combineLatest(context.sharedContext.presentationData, context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings]), AfterGramVoiceEffect.selection)
    |> deliverOnMainQueue
    |> map { presentationData, sharedData, selectedVoiceEffect -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? .defaultSettings
        let isRussian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let title = isRussian ? "Настройки AfterGram" : "AfterGram Settings"
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let voiceEffectTitle: String
        if isRussian {
            switch selectedVoiceEffect {
            case .off: voiceEffectTitle = "Выкл."
            case .radio: voiceEffectTitle = "Радио"
            case .robot: voiceEffectTitle = "Робот"
            case .bass: voiceEffectTitle = "Бас"
            }
        } else {
            switch selectedVoiceEffect {
            case .off: voiceEffectTitle = "Off"
            case .radio: voiceEffectTitle = "Radio"
            case .robot: voiceEffectTitle = "Robot"
            case .bass: voiceEffectTitle = "Bass"
            }
        }
        let entries: [AfterGramOptionsEntry] = [
            .profileTab(settings.afterGramShowProfileTab, isRussian),
            .onlineMarkers(settings.afterGramShowOnlineMarkers, isRussian),
            .clearGlass(settings.forceClearGlass, isRussian),
            .giftGlow(settings.afterGramGiftGlow, isRussian),
            .voiceEffect(voiceEffectTitle, isRussian),
            .messageAppearance(isRussian),
            .messageHistory(isRussian)
        ]
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (state, (list, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controllerReference.modify { $0 = controller }
    return controller
}
