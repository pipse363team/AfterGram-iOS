import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import AfterGramPython

public func afterGramDialogId(_ peerId: PeerId) -> Int64 {
    let id = peerId.id._internalGetInt64Value()
    return peerId.namespace == Namespaces.Peer.CloudUser ? id : -id
}

public final class AfterGramPluginManager {
    private static let queue = DispatchQueue(label: "AfterGram-Python")
    private weak var account: Account?
    private let root: String
    private let accountId: Int64
    private let lock = NSLock()
    private var active: Bool
    private var initialized = false
    private var menuSnapshot: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var incomingDisposable: Disposable?
    public var notice: ((String) -> Void)?

    public init(account: Account) {
        self.account = account
        self.accountId = account.id.int64
        self.root = account.basePath + "/aftergram-plugins"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: self.root + "/registry.json")), let registry = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] {
            self.active = registry.values.contains { $0["enabled"] as? Bool == true }
        } else {
            self.active = false
        }
    }
    deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        self.timer?.cancel()
        self.incomingDisposable?.dispose()
        let root = self.root
        let accountId = self.accountId
        if self.initialized {
            Self.queue.async {
                let request: [String: Any] = ["op": "close", "root": root, "account": accountId]
                if let data = try? JSONSerialization.data(withJSONObject: request), let text = String(data: data, encoding: .utf8) {
                    _ = AGPythonRuntime.dispatchJSON(text)
                }
            }
        }
    }
    private var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active
    }
    public var menus: [[String: Any]] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.menuSnapshot
    }
    public func start() {
        guard let account = self.account, !account.supplementary else { return }
        self.incomingDisposable = account.stateManager.pluginIncomingMessages.start(next: { [weak self] messages in
            guard let self, self.isActive else { return }
            for message in messages where message.id.namespace == Namespaces.Message.Cloud {
                let peer = afterGramDialogId(message.id.peerId)
                let name = message.id.peerId.namespace == Namespaces.Peer.CloudChannel ? "TL_updateNewChannelMessage" : "TL_updateNewMessage"
                self.request(["op": "update", "name": name, "peer": String(peer), "native_peer": String(message.id.peerId.toInt64()), "update": ["message": ["id": message.id.id, "message": message.text, "dialog_id": peer, "out": false]]]) { _ in }
            }
        })
        for (name, event) in [(UIApplication.didEnterBackgroundNotification, "PAUSE"), (UIApplication.willEnterForegroundNotification, "RESUME")] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self, self.isActive else { return }
                self.request(["op": "app_event", "event": event]) { _ in }
            })
        }
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.execute(["op": "tick"])
        }
        timer.resume()
        self.timer = timer
        if self.isActive { self.request(["op": "list"]) { _ in } }
    }
    private func raw(_ parameters: [String: Any]) -> [String: Any] {
        self.initialized = true
        var request = parameters
        request["root"] = self.root
        request["account"] = self.accountId
        if request["locale"] == nil { request["locale"] = Locale.preferredLanguages.first ?? "en" }
        guard let data = try? JSONSerialization.data(withJSONObject: request), let text = String(data: data, encoding: .utf8) else { return ["error": "Cannot encode plugin request"] }
        let response = AGPythonRuntime.dispatchJSON(text)
        guard let responseData = response.data(using: .utf8), let result = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else { return ["error": "Cannot decode plugin response"] }
        return result
    }
    @discardableResult private func execute(_ parameters: [String: Any]) -> [String: Any] {
        let result = self.raw(parameters)
        for action in result["actions"] as? [[String: Any]] ?? [] { self.perform(action) }
        let status = self.raw(["op": "list"])
        let menuStatus = self.raw(["op": "menus"])
        self.lock.lock()
        self.active = (status["plugins"] as? [[String: Any]] ?? []).contains { $0["enabled"] as? Bool == true }
        self.menuSnapshot = menuStatus["menus"] as? [[String: Any]] ?? []
        self.lock.unlock()
        return result
    }
    public func request(_ parameters: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        Self.queue.async { [weak self] in
            guard let self else { return }
            let result = self.execute(parameters)
            DispatchQueue.main.async { completion(result) }
        }
    }
    public func transform(peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[EnqueueMessage?], NoError> {
        if !self.isActive || peerId.namespace == Namespaces.Peer.SecretChat { return .single(messages.map { Optional($0) }) }
        return Signal { subscriber in
            let cancelled = Atomic(value: false)
            Self.queue.async { [weak self] in
                guard let self, !cancelled.with({ $0 }) else { subscriber.putCompletion(); return }
                var transformed: [EnqueueMessage?] = []
                for message in messages {
                    if cancelled.with({ $0 }) { return }
                    switch message {
                    case let .message(text, attributes, inlineStickers, media, threadId, reply, story, grouping, correlation, bubble):
                        let response = self.execute(["op": "outgoing", "text": text, "peer": String(afterGramDialogId(peerId)), "native_peer": String(peerId.toInt64())])
                        if response["cancel"] as? Bool == true {
                            transformed.append(nil)
                        } else {
                            let updated = response["text"] as? String ?? text
                            // Old entity ranges and inline stickers cannot describe rewritten text.
                            let updatedAttributes = updated == text ? attributes : attributes.filter { !($0 is TextEntitiesMessageAttribute) }
                            transformed.append(.message(text: updated, attributes: updatedAttributes, inlineStickers: updated == text ? inlineStickers : [:], mediaReference: media, threadId: threadId, replyToMessageId: reply, replyToStoryId: story, localGroupingKey: grouping, correlationId: correlation, bubbleUpEmojiOrStickersets: bubble))
                        }
                    case .forward:
                        transformed.append(message)
                    }
                }
                if !cancelled.with({ $0 }) { subscriber.putNext(transformed); subscriber.putCompletion() }
            }
            return ActionDisposable { _ = cancelled.swap(true) }
        }
    }
    private func perform(_ action: [String: Any]) {
        guard let account = self.account else { return }
        switch action["type"] as? String {
        case "notice":
            let text = action["text"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in self?.notice?(text) }
        case "clipboard":
            let text = action["text"] as? String ?? ""
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        case "send":
            guard let raw = action["peer"] as? String, let dialogId = Int64(raw), dialogId != Int64.min, abs(dialogId) <= 0x00ffffffffffffff, let text = action["text"] as? String else { return }
            let signal = account.postbox.transaction { transaction -> PeerId? in
                if let rawPeer = action["native_peer"] as? String, let value = Int64(rawPeer) {
                    let id = PeerId(value)
                    if afterGramDialogId(id) == dialogId && id.namespace != Namespaces.Peer.SecretChat && transaction.getPeer(id) != nil { return id }
                    return nil
                }
                if dialogId > 0 {
                    let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(dialogId))
                    return transaction.getPeer(id) == nil ? nil : id
                }
                var candidates: [PeerId] = []
                for namespace in [Namespaces.Peer.CloudChannel, Namespaces.Peer.CloudGroup] {
                    let id = PeerId(namespace: namespace, id: PeerId.Id._internalFromInt64Value(-dialogId))
                    if transaction.getPeer(id) != nil { candidates.append(id) }
                }
                return candidates.count == 1 ? candidates[0] : nil
            } |> mapToSignal { peer -> Signal<[MessageId?], NoError> in
                guard let peer else { return .single([]) }
                var attributes: [MessageAttribute] = []
                if action["notify"] as? Bool == false { attributes.append(NotificationInfoMessageAttribute(flags: .muted)) }
                if let schedule = action["schedule"] as? Int64, schedule > 0, schedule <= Int64(Int32.max) {
                    attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: Int32(schedule), repeatPeriod: nil))
                }
                var reply: EngineMessageReplySubject?
                if let replyId = action["reply"] as? Int64, replyId > 0, replyId <= Int64(Int32.max) {
                    reply = EngineMessageReplySubject(messageId: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: Int32(replyId)), quote: nil, innerSubject: nil)
                }
                let message = EnqueueMessage.message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: reply, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
                // Plugin sends bypass plugin hooks to avoid recursive auto-replies.
                return enqueueMessagesWithoutPlugins(account: account, peerId: peer, messages: [message])
            }
            let _ = signal.startStandalone()
        default:
            break
        }
    }
}
