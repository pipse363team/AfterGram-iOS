import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences

private struct AfterGramBubblePalette {
    let name: String
    let accent: UInt32
    let top: UInt32
    let bottom: UInt32

    static let all: [AfterGramBubblePalette] = [
        AfterGramBubblePalette(name: "Aurora", accent: 0xff6e72ed, top: 0xff383d98, bottom: 0xff202759),
        AfterGramBubblePalette(name: "Violet Pulse", accent: 0xffa276ff, top: 0xff7552db, bottom: 0xff4e3a9d),
        AfterGramBubblePalette(name: "Arctic", accent: 0xff50c9ed, top: 0xff287fae, bottom: 0xff23577e),
        AfterGramBubblePalette(name: "Sunset", accent: 0xffff8a79, top: 0xffce596e, bottom: 0xff82406e)
    ]
}

private enum AfterGramMessageAppearanceEntry: ItemListNodeEntry, Equatable {
    case intro(Bool)
    case palette(Int32, Bool)
    case intensity(Int32, Bool)
    case glow(Bool, Bool)
    case preview(Bool)

    var section: ItemListSectionId { 0 }
    var stableId: Int32 {
        switch self {
        case .intro: return 0
        case .palette: return 1
        case .intensity: return 2
        case .glow: return 3
        case .preview: return 4
        }
    }

    static func < (lhs: AfterGramMessageAppearanceEntry, rhs: AfterGramMessageAppearanceEntry) -> Bool {
        lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AfterGramMessageAppearanceArguments
        let isRussian: Bool
        switch self {
        case let .intro(value), let .glow(_, value), let .preview(value), let .palette(_, value), let .intensity(_, value):
            isRussian = value
        }
        switch self {
        case .intro:
            return ItemListInfoItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Локальное оформление" : "Local appearance", text: .plain(isRussian ? "Цвет и свечение применяются только на этом устройстве и не требуют API AfterGram." : "Color and glow are applied on this device and do not use the AfterGram API."), style: .blocks, sectionId: self.section)
        case let .palette(index, _):
            let safeIndex = max(0, min(AfterGramBubblePalette.all.count - 1, Int(index)))
            let title = isRussian ? "Цветовая гамма" : "Color palette"
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: AfterGramBubblePalette.all[safeIndex].name, labelStyle: .text, additionalDetailLabel: isRussian ? "Цвет исходящих пузырей Telegram." : "Color for Telegram’s outgoing bubbles.", sectionId: self.section, style: .blocks, action: {
                arguments.choosePalette()
            })
        case let .intensity(value, _):
            let namesRu = ["Мягкая", "Сбалансированная", "Яркая"]
            let namesEn = ["Soft", "Balanced", "Vivid"]
            let safeIndex = max(0, min(2, Int(value)))
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Насыщенность" : "Intensity", label: isRussian ? namesRu[safeIndex] : namesEn[safeIndex], labelStyle: .text, additionalDetailLabel: isRussian ? "Меняет яркость цвета в пузырях." : "Adjusts bubble color brightness.", sectionId: self.section, style: .blocks, action: {
                arguments.chooseIntensity()
            })
        case let .glow(enabled, _):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Мягкое свечение" : "Soft glow", text: isRussian ? "Добавляет цветной ореол исходящим сообщениям." : "Adds a colored halo to outgoing messages.", value: enabled, sectionId: self.section, style: .blocks, updated: { arguments.updateGlow($0) })
        case .preview:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: isRussian ? "Живой пример" : "Live example", label: "", labelStyle: .text, additionalDetailLabel: isRussian ? "Открой настоящий предпросмотр пузырей Telegram." : "Open a live preview using Telegram message bubbles.", sectionId: self.section, style: .blocks, action: {
                arguments.openPreview()
            })
        }
    }
}

private final class AfterGramMessageAppearanceArguments {
    let choosePalette: () -> Void
    let chooseIntensity: () -> Void
    let updateGlow: (Bool) -> Void
    let openPreview: () -> Void

    init(choosePalette: @escaping () -> Void, chooseIntensity: @escaping () -> Void, updateGlow: @escaping (Bool) -> Void, openPreview: @escaping () -> Void) {
        self.choosePalette = choosePalette
        self.chooseIntensity = chooseIntensity
        self.updateGlow = updateGlow
        self.openPreview = openPreview
    }
}

private func afterGramTint(_ color: UInt32, intensity: Int32) -> UInt32 {
    let factor: CGFloat = intensity == 0 ? 0.78 : (intensity == 2 ? 1.12 : 1.0)
    let uiColor = UIColor(rgb: color)
    var hue: CGFloat = 0.0
    var saturation: CGFloat = 0.0
    var brightness: CGFloat = 0.0
    var alpha: CGFloat = 1.0
    uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    return UIColor(hue: hue, saturation: min(1.0, saturation * (intensity == 2 ? 1.15 : 1.0)), brightness: min(1.0, brightness * factor), alpha: alpha).rgb
}

private func updateAfterGramBubblePalette(context: AccountContext, paletteIndex: Int32, intensity: Int32) {
    let safeIndex = max(0, min(AfterGramBubblePalette.all.count - 1, Int(paletteIndex)))
    let palette = AfterGramBubblePalette.all[safeIndex]
    let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
        var current = current
        current.afterGramMessagePalette = Int32(safeIndex)
        current.afterGramMessageIntensity = max(0, min(2, intensity))
        return current
    }).start()

    let _ = updatePresentationThemeSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
        var accents = current.themeSpecificAccentColors
        let themeIndex = current.theme.index
        let effectiveIntensity = max(0, min(2, intensity))
        accents[themeIndex] = PresentationThemeAccentColor(index: Int32(120 + safeIndex), baseColor: .preset, accentColor: afterGramTint(palette.accent, intensity: effectiveIntensity), bubbleColors: [afterGramTint(palette.top, intensity: effectiveIntensity), afterGramTint(palette.bottom, intensity: effectiveIntensity)], wallpaper: nil)
        return PresentationThemeSettings(theme: current.theme, themePreferredBaseTheme: current.themePreferredBaseTheme, themeSpecificAccentColors: accents, themeSpecificChatWallpapers: current.themeSpecificChatWallpapers, useSystemFont: current.useSystemFont, fontSize: current.fontSize, listsFontSize: current.listsFontSize, chatBubbleSettings: current.chatBubbleSettings, automaticThemeSwitchSetting: current.automaticThemeSwitchSetting, largeEmoji: current.largeEmoji, reduceMotion: current.reduceMotion)
    }).start()
}

public func afterGramMessageAppearanceController(context: AccountContext) -> ViewController {
    let controllerReference = Atomic<ViewController?>(value: nil)
    let currentSettings = Atomic<ExperimentalUISettings>(value: .defaultSettings)
    let choosePalette: () -> Void = {
        guard let controller = controllerReference.with({ $0 }) else { return }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let sheet = ActionSheetController(presentationData: presentationData)
        let options = AfterGramBubblePalette.all.enumerated().map { index, palette in
            ActionSheetButtonItem(title: palette.name, color: .accent, action: { [weak sheet] in
                sheet?.dismissAnimated()
                let settings = currentSettings.with { $0 }
                updateAfterGramBubblePalette(context: context, paletteIndex: Int32(index), intensity: settings.afterGramMessageIntensity)
            })
        }
        sheet.setItemGroups([ActionSheetItemGroup(items: options), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in sheet?.dismissAnimated() })
        ])])
        controller.present(sheet, in: .window(.root))
    }
    let chooseIntensity: () -> Void = {
        guard let controller = controllerReference.with({ $0 }) else { return }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let isRussian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let labels = isRussian ? ["Мягкая", "Сбалансированная", "Яркая"] : ["Soft", "Balanced", "Vivid"]
        let sheet = ActionSheetController(presentationData: presentationData)
        let options = labels.enumerated().map { index, title in
            ActionSheetButtonItem(title: title, color: .accent, action: { [weak sheet] in
                sheet?.dismissAnimated()
                let settings = currentSettings.with { $0 }
                updateAfterGramBubblePalette(context: context, paletteIndex: settings.afterGramMessagePalette, intensity: Int32(index))
            })
        }
        sheet.setItemGroups([ActionSheetItemGroup(items: options), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in sheet?.dismissAnimated() })
        ])])
        controller.present(sheet, in: .window(.root))
    }
    let arguments = AfterGramMessageAppearanceArguments(choosePalette: choosePalette, chooseIntensity: chooseIntensity, updateGlow: { value in
        let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
            var current = current
            current.afterGramMessageGlow = value
            return current
        }).start()
    }, openPreview: {
        guard let controller = controllerReference.with({ $0 }) else { return }
        let _ = (context.sharedContext.accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.presentationThemeSettings]))
        |> take(1)
        |> deliverOnMainQueue).start(next: { sharedData in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) ?? PresentationThemeSettings.defaultSettings
            controller.navigationController?.pushViewController(BubbleSettingsController(context: context, presentationThemeSettings: settings), animated: true)
        })
    })

    let signal = combineLatest(context.sharedContext.presentationData, context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.experimentalUISettings]))
    |> deliverOnMainQueue
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? .defaultSettings
        let _ = currentSettings.swap(settings)
        let isRussian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(isRussian ? "Оформление сообщений" : "Message appearance"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let entries: [AfterGramMessageAppearanceEntry] = [
            .intro(isRussian),
            .palette(settings.afterGramMessagePalette, isRussian),
            .intensity(settings.afterGramMessageIntensity, isRussian),
            .glow(settings.afterGramMessageGlow, isRussian),
            .preview(isRussian)
        ]
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (state, (list, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    let _ = controllerReference.swap(controller)
    return controller
}
