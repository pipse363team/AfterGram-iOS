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
    private let openButton = UIButton(type: .system)
    private let webPushURL = URL(string: "https://pipse363team.github.io/AfterGram-iOS/webpush/")!

    init(context: AccountContext) {
        self.context = context
        let presentation = context.sharedContext.currentPresentationData.with { $0 }
        self.russian = presentation.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentation))
        self.title = "Web Push"
        self.descriptionLabel.text = self.russian
            ? "Установи AfterGram Web Push на экран «Домой», затем открой страницу и подключи свой сервер. VAPID-ключи и доставка уведомлений управляются сервером; копировать подписку в приложение не нужно."
            : "Add AfterGram Web Push to your Home Screen, then open the setup page and connect your server. Your server manages VAPID keys and push delivery; you do not need to import a subscription into this app."
        self.descriptionLabel.numberOfLines = 0
        self.descriptionLabel.font = UIFont.systemFont(ofSize: 16)
        self.statusLabel.numberOfLines = 0
        self.statusLabel.font = UIFont.systemFont(ofSize: 14)
        self.openButton.setTitle(self.russian ? "Открыть страницу Web Push" : "Open Web Push setup", for: .normal)
        self.openButton.addTarget(self, action: #selector(self.openPage), for: .touchUpInside)
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
        for button in [self.openButton] {
            button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
            button.contentHorizontalAlignment = .left
            button.tintColor = theme.list.itemAccentColor
        }
        self.displayNode.view.addSubview(self.descriptionLabel)
        self.displayNode.view.addSubview(self.openButton)
        self.displayNode.view.addSubview(self.statusLabel)
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY + 20
        let width = layout.size.width - 36
        self.descriptionLabel.frame = CGRect(x: 18, y: top, width: width, height: 150)
        self.openButton.frame = CGRect(x: 18, y: top + 160, width: width, height: 48)
        self.statusLabel.frame = CGRect(x: 18, y: top + 220, width: width, height: 90)
    }

    @objc private func openPage() {
        UIApplication.shared.open(self.webPushURL)
    }

    private func refreshStatus() {
        self.statusLabel.text = self.russian
            ? "Push доставляется установленной PWA через твой сервер. Нажатие на уведомление откроет AfterGram."
            : "Push is delivered to the installed PWA by your server. Tapping a notification opens AfterGram."
    }
}

public func afterGramWebPushController(context: AccountContext) -> ViewController {
    return AfterGramWebPushController(context: context)
}
