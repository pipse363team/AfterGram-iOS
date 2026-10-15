import Foundation
import UIKit

final class AfterGramPluginUI {
    private struct Pending {
        var value: [String: Any]
        let event: ([String: Any]) -> Void
    }
    private var pending: [Pending] = []
    private var current: UIAlertController?
    private var currentId: String?
    private var disposed = false

    private func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }), var controller = window.rootViewController else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }
    func handle(_ value: [String: Any], event: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed else { return }
            switch value["type"] as? String {
            case "open_url":
                if let raw = value["url"] as? String, let url = URL(string: raw), ["https","http","tg","mailto"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
            case "share":
                guard let text = value["text"] as? String, let presenter = self.presenter() else { return }
                let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = presenter.view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                presenter.present(sheet, animated: true)
            case "notice": self.toast(value["text"] as? String ?? "")
            case "dialog":
                guard let id = value["dialog"] as? String else { return }
                if self.currentId == id { self.update(value);return }
                self.pending.removeAll { $0.value["dialog"] as? String == id }
                self.pending.append(Pending(value: value, event: event));self.pump()
            case "dialog_update":
                self.update(value)
                if let index = self.pending.firstIndex(where: { $0.value["dialog"] as? String == value["dialog"] as? String }) { self.pending[index].value = value }
            case "dialog_dismiss":
                guard let id = value["dialog"] as? String else { return }
                self.pending.removeAll { $0.value["dialog"] as? String == id }
                if self.currentId == id { self.current?.dismiss(animated: true);self.current = nil;self.currentId = nil;self.pump() }
            default: break
            }
        }
    }
    func synchronize(_ dialogs: Set<String>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll { !dialogs.contains($0.value["dialog"] as? String ?? "") }
            if let id = self.currentId, !dialogs.contains(id) {
                self.current?.dismiss(animated: true);self.current = nil;self.currentId = nil;self.pump()
            }
        }
    }
    func dispose() {
        DispatchQueue.main.async { [self] in
            self.disposed = true;self.pending.removeAll();self.current?.dismiss(animated: false);self.current = nil
        }
    }
    private func message(_ value: [String: Any]) -> String {
        var parts = [value["message"] as? String ?? ""]
        for control in value["controls"] as? [[String: Any]] ?? [] where control["kind"] as? String == "text" { parts.append(control["text"] as? String ?? "") }
        if value["progress_style"] as? Int == 1 { parts.append("\(value["progress"] as? Int ?? 0)%") }
        if value["progress_style"] as? Int == 2 { parts.append("…") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private func update(_ value: [String: Any]) {
        guard self.currentId == value["dialog"] as? String else { return }
        self.current?.title = value["title"] as? String
        self.current?.message = self.message(value)
    }
    private func pump() {
        guard !self.disposed, self.current == nil, !self.pending.isEmpty else { return }
        guard let presenter = self.presenter(), !(presenter is UIAlertController), presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pump() };return
        }
        let entry = self.pending.removeFirst(), value = entry.value
        guard let id = value["dialog"] as? String else { self.pump();return }
        let alert = UIAlertController(title: value["title"] as? String, message: self.message(value), preferredStyle: .alert)
        self.current = alert;self.currentId = id
        let controls = value["controls"] as? [[String: Any]] ?? []
        for control in controls where control["kind"] as? String == "input" {
            alert.addTextField { field in
                field.text = control["text"] as? String
                field.placeholder = control["hint"] as? String
                field.isEnabled = control["enabled"] as? Bool ?? true
                field.isSecureTextEntry = control["secure"] as? Bool ?? false
                field.font = UIFont.systemFont(ofSize: CGFloat(control["font_size"] as? Double ?? 16))
                if control["input_type"] as? Int == 2 { field.keyboardType = .numbersAndPunctuation }
                if control["input_type"] as? Int == 3 { field.keyboardType = .phonePad }
            }
        }
        let finish: (String, Int) -> Void = { [weak self, weak alert] kind, which in
            let values = alert?.textFields?.map { $0.text ?? "" } ?? []
            self?.current = nil;self?.currentId = nil
            entry.event(["op":"dialog_event", "dialog":id, "event":kind, "which":which, "values":values])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.pump() }
        }
        for (index, text) in (value["items"] as? [String] ?? []).prefix(100).enumerated() {
            alert.addAction(UIAlertAction(title: text, style: .default) { _ in finish("item",index) })
        }
        for (index, control) in controls.enumerated() where control["kind"] as? String == "button" {
            let action = UIAlertAction(title: control["text"] as? String, style: .default) { _ in finish("control",index) }
            action.isEnabled = control["enabled"] as? Bool ?? true;alert.addAction(action)
        }
        let buttons = value["buttons"] as? [[String: Any]] ?? []
        for button in buttons {
            guard let which = button["which"] as? Int else { continue }
            let style: UIAlertAction.Style = button["red"] as? Bool == true ? .destructive : (which == -2 ? .cancel : .default)
            alert.addAction(UIAlertAction(title: button["text"] as? String, style: style) { _ in finish("button",which) })
        }
        if value["cancelable"] as? Bool != false && !buttons.contains(where: { $0["which"] as? Int == -2 }) {
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in finish("cancel",-2) })
        }
        presenter.present(alert, animated: true)
    }
    private func toast(_ text: String) {
        guard !text.isEmpty, let presenter = self.presenter() else { return }
        let label = UILabel()
        label.text = text;label.numberOfLines = 5;label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.textColor = .white;label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        label.layer.cornerRadius = 12;label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        presenter.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: presenter.view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            label.widthAnchor.constraint(equalTo: presenter.view.widthAnchor, constant: -48),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        UIView.animate(withDuration: 0.3, delay: 3, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}
