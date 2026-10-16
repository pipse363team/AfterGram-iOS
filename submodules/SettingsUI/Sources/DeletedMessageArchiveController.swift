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
    case editHistory(Bool, Bool)
    case downloadLatest(Bool)
    case info(Bool)

    var section: ItemListSectionId { return 0 }
    var stableId: Int32 {
        switch self {
        case .enabled: return 0
        case .editHistory: return 1
        case .downloadLatest: return 2
        case .info: return 3
        }
    }
    static func <(lhs: RetentionSettingsEntry, rhs: RetentionSettingsEntry) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .enabled(value, ru):
            let update = (arguments as! ((Bool) -> Void, (Bool) -> Void, () -> Void)).0
            return ItemListSwitchItem(presentationData: presentationData, title: ru ? "Сохранять удалённые" : "Keep deleted messages", value: value, sectionId: self.section, style: .blocks, updated: update)
        case let .editHistory(value, ru):
            let update = (arguments as! ((Bool) -> Void, (Bool) -> Void, () -> Void)).1
            return ItemListSwitchItem(presentationData: presentationData, title: ru ? "Сохранять историю правок" : "Keep edit history", value: value, sectionId: self.section, style: .blocks, updated: update)
        case let .downloadLatest(ru):
            let download = (arguments as! ((Bool) -> Void, (Bool) -> Void, () -> Void)).2
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: ru ? "Скачать последнюю сборку AfterGram" : "Download the latest AfterGram build", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: download)
        case let .info(ru):
            return ItemListTextItem(presentationData: presentationData, text: .plain(ru ? "Удалённые сообщения остаются в чате с отметкой и прозрачностью 50%. Чтобы сохранить медиа, оно должно успеть загрузиться. Сохранённые сообщения можно удалить вручную." : "Deleted messages stay in the chat at 50% opacity with a deleted mark. Media must finish loading to be retained. Saved messages can be removed manually."), sectionId: self.section)
        }
    }
}

public func deletedMessageArchiveController(context: AccountContext) -> ViewController {
    weak var weakController: ViewController?
    let downloadLatest: () -> Void = {
        let releaseUrl = URL(string: "https://api.github.com/repos/pipse363team/AfterGram-iOS/releases/tags/latest")!
        var request = URLRequest(url: releaseUrl)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AfterGram-iOS", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = release["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }),
                  let assetUrl = asset["browser_download_url"] as? String,
                  let url = URL(string: assetUrl) else {
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: "AfterGram", message: "Не удалось найти последнюю сборку. Попробуйте позже.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    weakController?.present(alert, animated: true)
                }
                return
            }
            URLSession.shared.downloadTask(with: url) { location, _, error in
                DispatchQueue.main.async {
                    guard error == nil, let location else {
                        let alert = UIAlertController(title: "AfterGram", message: "Не удалось скачать IPA. Проверьте подключение и повторите попытку.", preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        weakController?.present(alert, animated: true)
                        return
                    }
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("AfterGram-latest.ipa")
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        let activity = UIActivityViewController(activityItems: [destination], applicationActivities: nil)
                        if let popover = activity.popoverPresentationController {
                            popover.sourceView = weakController?.view
                            popover.sourceRect = CGRect(x: (weakController?.view.bounds.midX ?? 0), y: (weakController?.view.bounds.midY ?? 0), width: 0, height: 0)
                        }
                        weakController?.present(activity, animated: true)
                    } catch {
                        let alert = UIAlertController(title: "AfterGram", message: "Не удалось подготовить файл IPA для сохранения.", preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        weakController?.present(alert, animated: true)
                    }
                }
            }.resume()
        }.resume()
    }
    let update: (Bool) -> Void = { value in
        let _ = updateDeletedMessageRetentionSettings(postbox: context.account.postbox, enabled: value).start()
    }
    let updateEdits: (Bool) -> Void = { value in
        let _ = updateAfterGramEditedMessageHistorySettings(postbox: context.account.postbox, enabled: value).start()
    }
    let signal = combineLatest(context.sharedContext.presentationData, combineLatest(deletedMessageRetentionSettings(postbox: context.account.postbox), afterGramEditedMessageHistorySettings(postbox: context.account.postbox)))
    |> deliverOnMainQueue
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let ru = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(ru ? "Удалённые сообщения" : "Deleted Messages"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: [RetentionSettingsEntry.enabled(settings.0.enabled, ru), .editHistory(settings.1.enabled, ru), .downloadLatest(ru), .info(ru)], style: .blocks, animateChanges: false)
        return (state, (list, (update, updateEdits, downloadLatest)))
    }
    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
