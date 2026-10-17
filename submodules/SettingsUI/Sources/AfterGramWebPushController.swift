import Foundation
import UIKit
import AsyncDisplayKit
import AccountContext
import Display
import TelegramPresentationData

private final class AfterGramWebPushController: ViewController {
    private let context: AccountContext
    private let russian: Bool
    private let descriptionLabel = UILabel()
    private let statusLabel = UILabel()
    private let pasteButton = UIButton(type: .system)
    private let disableButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private let webPushURL = URL(string: "https://pipse363team.github.io/AfterGram-iOS/webpush/")!

    init(context: AccountContext) {
        self.context = context
        let presentation = context.sharedContext.currentPresentationData.with { $0 }
        self.russian = presentation.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentation))
        self.title = "Web Push"
        self.descriptionLabel.text = self.russian
            ? "Установи AfterGram Web Push на экран «Домой», открой его и разреши уведомления. Затем скопируй подписку и вставь её здесь. Подписка хранится только на устройстве и передаётся Telegram для доставки уведомлений."
            : "Add AfterGram Web Push to your Home Screen, open it and allow notifications. Copy the subscription and paste it here. The subscription stays on this device and is sent to Telegram to deliver notifications."
        self.descriptionLabel.numberOfLines = 0
        self.descriptionLabel.font = UIFont.systemFont(ofSize: 16)
        self.statusLabel.numberOfLines = 0
        self.statusLabel.font = UIFont.systemFont(ofSize: 14)
        self.openButton.setTitle(self.russian ? "Открыть страницу Web Push" : "Open Web Push setup", for: .normal)
        self.pasteButton.setTitle(self.russian ? "Импортировать из буфера" : "Import from Clipboard", for: .normal)
        self.disableButton.setTitle(self.russian ? "Отключить Web Push" : "Disable Web Push", for: .normal)
        self.openButton.addTarget(self, action: #selector(self.openPage), for: .touchUpInside)
        self.pasteButton.addTarget(self, action: #selector(self.importSubscription), for: .touchUpInside)
        self.disableButton.addTarget(self, action: #selector(self.disable), for: .touchUpInside)
        self.refreshStatus()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        let theme = self.context.sharedContext.currentPresentationData.with { $0 }.theme
        self.displayNode.backgroundColor = theme.list.blocksBackgroundColor
        for view in [self.descriptionLabel, self.statusLabel] {
            view.textColor = theme.list.itemPrimaryTextColor
        }
        for button in [self.openButton, self.pasteButton, self.disableButton] {
            button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            button.contentHorizontalAlignment = .left
            button.tintColor = theme.list.itemAccentColor
        }
        self.disableButton.tintColor = theme.list.itemDestructiveColor
        self.displayNode.view.addSubview(self.descriptionLabel)
        self.displayNode.view.addSubview(self.openButton)
        self.displayNode.view.addSubview(self.pasteButton)
        self.displayNode.view.addSubview(self.statusLabel)
        self.displayNode.view.addSubview(self.disableButton)
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY + 20
        let width = layout.size.width - 36
        self.descriptionLabel.frame = CGRect(x: 18, y: top, width: width, height: 150)
        self.openButton.frame = CGRect(x: 18, y: top + 160, width: width, height: 48)
        self.pasteButton.frame = CGRect(x: 18, y: top + 214, width: width, height: 48)
        self.statusLabel.frame = CGRect(x: 18, y: top + 274, width: width, height: 70)
        self.disableButton.frame = CGRect(x: 18, y: top + 350, width: width, height: 48)
    }

    @objc private func openPage() {
        UIApplication.shared.open(self.webPushURL)
    }

    @objc private func importSubscription() {
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoint = object["endpoint"] as? String,
              let endpointURL = URL(string: endpoint), endpointURL.scheme == "https",
              let keys = object["keys"] as? [String: String],
              let p256dh = keys["p256dh"], !p256dh.isEmpty,
              let auth = keys["auth"], !auth.isEmpty else {
            self.showMessage(self.russian ? "В буфере нет корректной Web Push-подписки. Скопируй её на странице настройки." : "No valid Web Push subscription found in the clipboard. Copy it from the setup page.")
            return
        }
        self.context.sharedContext.setAfterGramWebPushSubscription(text)
        self.showMessage(self.russian ? "Подписка сохранена. Telegram зарегистрирует её для этого аккаунта." : "Subscription saved. Telegram will register it for this account.")
        self.refreshStatus()
    }

    @objc private func disable() {
        self.context.sharedContext.setAfterGramWebPushSubscription(nil)
        self.showMessage(self.russian ? "Web Push отключён на этом устройстве." : "Web Push disabled on this device.")
        self.refreshStatus()
    }

    private func refreshStatus() {
        let installed = UserDefaults.standard.string(forKey: "AfterGramWebPushSubscription") != nil
        self.statusLabel.text = installed
            ? (self.russian ? "Подписка сохранена на устройстве." : "A subscription is saved on this device.")
            : (self.russian ? "Подписка не настроена." : "No subscription configured.")
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: "Web Push", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }
}

public func afterGramWebPushController(context: AccountContext) -> ViewController {
    return AfterGramWebPushController(context: context)
}
