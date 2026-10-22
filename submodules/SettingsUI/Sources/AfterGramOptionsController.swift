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

private struct AfterGramAppIcon: Equatable {
    let identifier: String?
    let title: String

    static let choices: [AfterGramAppIcon] = [
        AfterGramAppIcon(identifier: nil, title: "Default"),
        AfterGramAppIcon(identifier: "AfterGramClassic", title: "AfterGram Classic"),
        AfterGramAppIcon(identifier: "AfterGramMidnight", title: "AfterGram Midnight"),
        AfterGramAppIcon(identifier: "AfterGramSunset", title: "AfterGram Sunset"),
        AfterGramAppIcon(identifier: "AfterGramAurora", title: "AfterGram Aurora")
    ]
}

private final class AfterGramOptionsControllerArguments {
    let update: (AfterGramOption, Bool) -> Void
    let openVoiceEffect: () -> Void
    let openMessageHistory: () -> Void
    let openMessageAppearance: () -> Void
    let openAppIcons: () -> Void
    let openBotAccount: () -> Void

    init(update: @escaping (AfterGramOption, Bool) -> Void, openVoiceEffect: @escaping () -> Void, openMessageHistory: @escaping () -> Void, openMessageAppearance: @escaping () -> Void, openAppIcons: @escaping () -> Void, openBotAccount: @escaping () -> Void) {
        self.update = update
        self.openVoiceEffect = openVoiceEffect
        self.openMessageHistory = openMessageHistory
        self.openMessageAppearance = openMessageAppearance
        self.openAppIcons = openAppIcons
        self.openBotAccount = openBotAccount
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
    case appIcon(String, Bool)
    case botAccount(Bool)

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
        case .appIcon: return 7
        case .botAccount: return 8
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
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Оформление сообщений" : "Message appearance", label: "", labelStyle: .text, additionalDetailLabel: isRussian ? "Цвет, насыщенность, свечение и живой пример." : "Color, intensity, glow, and a live example.", sectionId: self.section, style: .blocks, action: {
                arguments.openMessageAppearance()
            })
        case let .messageHistory(isRussian):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "История сообщений" : "Message history", label: "", labelStyle: .text, additionalDetailLabel: isRussian ? "Удалённые сообщения и сохранённые версии правок." : "Deleted messages and saved edit history.", sectionId: self.section, style: .blocks, action: {
                arguments.openMessageHistory()
            })
        case let .appIcon(value, isRussian):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Иконка AfterGram" : "AfterGram icon", label: value, labelStyle: .text, additionalDetailLabel: isRussian ? "Выбери вариант — iOS заменит иконку приложения." : "Choose a style to change the app icon in iOS.", sectionId: self.section, style: .blocks, action: {
                arguments.openAppIcons()
            })
        case let .botAccount(isRussian):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Войти как бот" : "Add bot account", label: "", labelStyle: .text, additionalDetailLabel: isRussian ? "Добавляет бота отдельным аккаунтом. Токен отправляется только Telegram." : "Adds a bot as a separate account. The token is sent only to Telegram.", sectionId: self.section, style: .blocks, action: {
                arguments.openBotAccount()
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
    let selectedAppIconName = ValuePromise(UIApplication.shared.alternateIconName, ignoreRepeated: true)
    let openAppIcons: () -> Void = {
        guard let controller = controllerReference.with({ $0 }) else { return }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let isRussian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let currentIcon = UIApplication.shared.alternateIconName
        let actionSheet = ActionSheetController(presentationData: presentationData)
        let iconItems: [ActionSheetItem] = AfterGramAppIcon.choices.map { choice in
            let selected = choice.identifier == currentIcon
            let choiceTitle = choice.identifier == nil ? (isRussian ? "По умолчанию" : "Default") : choice.title
            let title = selected ? "✓  \(choiceTitle)" : "    \(choiceTitle)"
            return ActionSheetButtonItem(title: title, color: .accent, action: { [weak actionSheet, weak controller] in
                actionSheet?.dismissAnimated()
                guard UIApplication.shared.supportsAlternateIcons else {
                    let data = context.sharedContext.currentPresentationData.with { $0 }
                    controller?.present(textAlertController(context: context, title: isRussian ? "Иконки недоступны" : "Icons unavailable", text: isRussian ? "Эта сборка iOS не поддерживает смену иконок." : "This iOS build does not support alternate app icons.", actions: [TextAlertAction(type: .defaultAction, title: data.strings.Common_OK, action: {})]), in: .window(.root))
                    return
                }
                UIApplication.shared.setAlternateIconName(choice.identifier) { error in
                    DispatchQueue.main.async {
                        guard let error else {
                            selectedAppIconName.set(choice.identifier)
                            return
                        }
                        let data = context.sharedContext.currentPresentationData.with { $0 }
                        controller?.present(textAlertController(context: context, title: isRussian ? "Не удалось сменить иконку" : "Could not change icon", text: error.localizedDescription, actions: [TextAlertAction(type: .defaultAction, title: data.strings.Common_OK, action: {})]), in: .window(.root))
                    }
                }
            })
        }
        actionSheet.setItemGroups([ActionSheetItemGroup(items: iconItems), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        controller.present(actionSheet, in: .window(.root))
    }
    let arguments = AfterGramOptionsControllerArguments(update: update, openVoiceEffect: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        controller.navigationController?.pushViewController(afterGramVoiceEffectController(context: context), animated: true)
    }, openMessageHistory: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        controller.navigationController?.pushViewController(deletedMessageArchiveController(context: context), animated: true)
    }, openMessageAppearance: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        controller.navigationController?.pushViewController(afterGramMessageAppearanceController(context: context), animated: true)
    }, openAppIcons: openAppIcons, openBotAccount: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let isRussian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let alert = UIAlertController(title: isRussian ? "Войти как бот" : "Add bot account", message: isRussian ? "Вставь токен из BotFather. Он отправится Telegram по MTProto и не сохранится в настройках." : "Paste the token from BotFather. It is sent to Telegram over MTProto and is not stored in settings.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "123456789:..."
            field.isSecureTextEntry = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: isRussian ? "Добавить" : "Add", style: .default, handler: { _ in
            guard let token = alert.textFields?.first?.text else { return }
            context.sharedContext.addBotAccount(token: token) { success, message in
                if !success, let message {
                    let errorAlert = UIAlertController(title: isRussian ? "Не удалось войти" : "Sign-in failed", message: message, preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
                    controller.present(errorAlert, animated: true)
                }
            }
        }))
        controller.present(alert, animated: true)
    })

    let signal = combineLatest(context.sharedContext.presentationData, context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings]), AfterGramVoiceEffect.selection, selectedAppIconName.get())
    |> deliverOnMainQueue
    |> map { presentationData, sharedData, selectedVoiceEffect, selectedIconName -> (ItemListControllerState, (ItemListNodeState, Any)) in
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
            .messageHistory(isRussian),
            .appIcon(AfterGramAppIcon.choices.first(where: { $0.identifier == selectedIconName })?.title ?? (isRussian ? "По умолчанию" : "Default"), isRussian),
            .botAccount(isRussian)
        ]
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (state, (list, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    let _ = controllerReference.swap(controller)
    return controller
}
