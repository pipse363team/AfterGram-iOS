import Foundation
import UIKit
import UniformTypeIdentifiers
import AsyncDisplayKit
import AccountContext
import Display
import TelegramCore
import TelegramPresentationData

private final class AfterGramPluginsController: ViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private let context: AccountContext
    private let pluginId: String?
    private let settingsPath: [Int]
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var records: [[String: Any]] = []
    private let ru: Bool
    private var busy = false
    private var temporaryImport: URL?

    init(context: AccountContext, pluginId: String? = nil, title: String? = nil, settingsPath: [Int] = []) {
        self.context = context
        self.pluginId = pluginId
        self.settingsPath = settingsPath
        let presentation = context.sharedContext.currentPresentationData.with { $0 }
        self.ru = presentation.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentation))
        self.title = title ?? (self.ru ? "Плагины" : "Plugins")
        self.table.dataSource = self
        self.table.delegate = self
        self.table.backgroundColor = presentation.theme.list.blocksBackgroundColor
        self.table.rowHeight = UITableView.automaticDimension
        self.table.estimatedRowHeight = 62
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let path = self.temporaryImport { try? FileManager.default.removeItem(at: path) }
    }
    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.view.addSubview(self.table)
        self.displayNodeDidLoad()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: self.table, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top)))
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.context.account.afterGramPlugins.notice = { [weak self] text in self?.show(text) }
        self.reload()
    }
    private func show(_ text: String) {
        guard self.viewIfLoaded?.window != nil, self.presentedViewController == nil else { return }
        let alert = UIAlertController(title: self.ru ? "Плагины" : "Plugins", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.present(alert, animated: true)
    }
    private func reload() {
        var request: [String: Any] = ["op": "list"]
        if let pluginId = self.pluginId { request = ["op": "settings", "id": pluginId, "path": self.settingsPath] }
        self.context.account.afterGramPlugins.request(request) { [weak self] response in
            guard let self else { return }
            if let error = response["error"] as? String, !error.isEmpty { self.show(error) }
            self.records = response[self.pluginId == nil ? "plugins" : "rows"] as? [[String: Any]] ?? []
            self.table.reloadData()
        }
    }
    func numberOfSections(in tableView: UITableView) -> Int { return self.pluginId == nil ? 2 : 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.pluginId == nil && section == 0 ? 3 : self.records.count
    }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if self.pluginId == nil && section == 0 {
            return self.ru ? "Импортируй Python-плагин или исходный пакет Elyx. При необходимости появится кнопка «Подготовить для iOS»." : "Import a Python or Elyx source plugin. When supported adaptations are available, choose Prepare for iOS."
        }
        return nil
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let presentation = self.context.sharedContext.currentPresentationData.with { $0 }
        cell.backgroundColor = presentation.theme.list.itemBlocksBackgroundColor
        cell.textLabel?.textColor = presentation.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = presentation.theme.list.itemSecondaryTextColor
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 3
        if self.pluginId == nil {
            if indexPath.section == 0 {
                cell.textLabel?.text = (self.ru ? ["Импортировать плагин", "Добавить пример Hello", "Журнал плагинов"] : ["Import Plugin", "Add Hello Example", "Plugin Logs"])[indexPath.row]
                cell.accessoryType = .disclosureIndicator
            } else {
                let item = self.records[indexPath.row]
                cell.textLabel?.text = item["name"] as? String
                let enabled = item["enabled"] as? Bool == true
                let error = item["error"] as? String ?? ""
                cell.detailTextLabel?.text = error.isEmpty ? (enabled ? (self.ru ? "Включён" : "Enabled") : (self.ru ? "Выключен" : "Disabled")) : (self.ru ? "Ошибка — нажми для подробностей" : "Error — tap for details")
                cell.accessoryType = .disclosureIndicator
            }
        } else {
            let item = self.records[indexPath.row]
            cell.textLabel?.text = item["text"] as? String
            cell.detailTextLabel?.text = item["subtext"] as? String
            switch item["kind"] as? String {
            case "Switch":
                let toggle = UISwitch()
                toggle.isOn = item["value"] as? Bool ?? false
                toggle.addAction(UIAction { [weak self, weak toggle] _ in
                    self?.change(index: indexPath.row, value: toggle?.isOn ?? false)
                }, for: .valueChanged)
                cell.accessoryView = toggle
            case "Input", "EditText", "Selector":
                cell.accessoryType = .disclosureIndicator
                if let value = item["value"], !(value is NSNull) { cell.detailTextLabel?.text = String(describing: value) }
            case "Header", "Divider":
                cell.selectionStyle = .none
                cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
            default:
                break
            }
        }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let _ = self.pluginId {
            let item = self.records[indexPath.row]
            switch item["kind"] as? String {
            case "Input", "EditText":
                let alert = UIAlertController(title: item["text"] as? String, message: item["subtext"] as? String, preferredStyle: .alert)
                alert.addTextField { $0.text = item["value"] as? String }
                alert.addAction(UIAlertAction(title: self.ru ? "Отмена" : "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: self.ru ? "Сохранить" : "Save", style: .default) { [weak self, weak alert] _ in
                    self?.change(index: indexPath.row, value: alert?.textFields?.first?.text ?? "")
                })
                self.present(alert, animated: true)
            case "Selector":
                let alert = UIAlertController(title: item["text"] as? String, message: nil, preferredStyle: .alert)
                for (index, text) in (item["items"] as? [String] ?? []).enumerated() {
                    alert.addAction(UIAlertAction(title: text, style: .default) { [weak self] _ in self?.change(index: indexPath.row, value: index) })
                }
                alert.addAction(UIAlertAction(title: self.ru ? "Отмена" : "Cancel", style: .cancel))
                self.present(alert, animated: true)
            case "Text":
                if item["subpage"] as? Bool == true {
                    self.navigationController?.pushViewController(AfterGramPluginsController(context: self.context, pluginId: self.pluginId, title: item["text"] as? String, settingsPath: self.settingsPath + [indexPath.row]), animated: true)
                    return
                }
                self.change(index: indexPath.row, value: NSNull())
            default: break
            }
            return
        }
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                guard !self.busy else { return }
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pythonScript, .data], asCopy: true)
                picker.delegate = self
                picker.allowsMultipleSelection = false
                self.present(picker, animated: true)
            case 1:
                self.context.account.afterGramPlugins.request(["op": "sample"]) { [weak self] response in
                    if let error = response["error"] as? String { self?.show(error) }
                    self?.reload()
                }
            default:
                self.context.account.afterGramPlugins.request(["op": "logs"]) { [weak self] response in
                    let text = (response["logs"] as? [String] ?? []).joined(separator: "\n")
                    self?.show(text.isEmpty ? (self?.ru == true ? "Журнал пуст" : "No logs") : text)
                }
            }
            return
        }
        let item = self.records[indexPath.row]
        guard let id = item["id"] as? String else { return }
        let alert = UIAlertController(title: item["name"] as? String, message: item["error"] as? String, preferredStyle: .alert)
        let enabled = item["enabled"] as? Bool == true
        alert.addAction(UIAlertAction(title: enabled ? (self.ru ? "Выключить" : "Disable") : (self.ru ? "Включить" : "Enable"), style: .default) { [weak self] _ in
            self?.context.account.afterGramPlugins.request(["op": "enable", "id": id, "enabled": !enabled]) { response in
                if let error = response["error"] as? String, !error.isEmpty { self?.show(error) }
                self?.reload()
            }
        })
        if enabled {
            alert.addAction(UIAlertAction(title: self.ru ? "Настройки" : "Settings", style: .default) { [weak self] _ in
                guard let self else { return }
                self.navigationController?.pushViewController(AfterGramPluginsController(context: self.context, pluginId: id, title: item["name"] as? String), animated: true)
            })
            for menu in self.context.account.afterGramPlugins.menus where menu["plugin"] as? String == id && menu["type"] as? String == "main" {
                guard let menuId = menu["id"] as? String else { continue }
                alert.addAction(UIAlertAction(title: menu["text"] as? String, style: .default) { [weak self] _ in
                    self?.context.account.afterGramPlugins.request(["op": "menu", "id": id, "menu": menuId]) { _ in }
                })
            }
        }
        alert.addAction(UIAlertAction(title: self.ru ? "Удалить" : "Delete", style: .destructive) { [weak self] _ in
            self?.context.account.afterGramPlugins.request(["op": "delete", "id": id]) { _ in self?.reload() }
        })
        alert.addAction(UIAlertAction(title: self.ru ? "Отмена" : "Cancel", style: .cancel))
        self.present(alert, animated: true)
    }
    private func change(index: Int, value: Any) {
        guard let id = self.pluginId, index < self.records.count else { return }
        self.context.account.afterGramPlugins.request(["op": "setting", "id": id, "index": index, "value": value, "path": self.settingsPath]) { [weak self] response in
            if let error = response["error"] as? String { self?.show(error) }
            self?.records = response["rows"] as? [[String: Any]] ?? []
            self?.table.reloadData()
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + source.pathExtension)
            try FileManager.default.copyItem(at: source, to: temp)
            self.temporaryImport = temp
            self.busy = true
            self.context.account.afterGramPlugins.request(["op": "inspect", "path": temp.path]) { [weak self] response in
                guard let self else { return }
                let report = response["report"] as? [String: Any] ?? [:]
                let issues = report["issues"] as? [String] ?? []
                if let error = response["error"] as? String { self.finishImport();self.show(error);return }
                if !issues.isEmpty { self.finishImport();self.show(issues.joined(separator: "\n"));return }
                let changes = report["changes"] as? [String] ?? []
                if changes.isEmpty { self.install(temp, adapt: false);return }
                let alert = UIAlertController(title: self.ru ? "Подготовить для iOS" : "Prepare for iOS", message: changes.joined(separator: "\n"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: self.ru ? "Отмена" : "Cancel", style: .cancel) { [weak self] _ in self?.finishImport() })
                alert.addAction(UIAlertAction(title: self.ru ? "Подготовить" : "Prepare", style: .default) { [weak self] _ in self?.install(temp, adapt: true) })
                self.present(alert, animated: true)
            }
        } catch { self.show(error.localizedDescription) }
    }
    private func install(_ path: URL, adapt: Bool) {
        self.context.account.afterGramPlugins.request(["op": "install", "path": path.path, "adapt": adapt]) { [weak self] response in
            self?.finishImport()
            if let error = response["error"] as? String { self?.show(error) }
            self?.reload()
        }
    }
    private func finishImport() {
        self.busy = false
        if let path = self.temporaryImport { try? FileManager.default.removeItem(at: path) }
        self.temporaryImport = nil
    }
}

public func afterGramPluginsController(context: AccountContext) -> ViewController {
    return AfterGramPluginsController(context: context)
}
