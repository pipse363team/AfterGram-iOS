import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import AfterGramPython
import TelegramApi

public func afterGramDialogId(_ peerId: PeerId) -> Int64 {
    let id = peerId.id._internalGetInt64Value()
    return peerId.namespace == Namespaces.Peer.CloudUser ? id : -id
}

private func afterGramTextEntities(_ values: [[String: Any]], text: String) -> [MessageTextEntity] {
    return values.compactMap { value in
        guard let offset = value["offset"] as? Int, let length = value["length"] as? Int,
              offset >= 0, length > 0, offset <= text.utf16.count, length <= text.utf16.count - offset else { return nil }
        let type: MessageTextEntityType
        switch value["type"] as? String {
        case "bold": type = .Bold
        case "italic": type = .Italic
        case "underline": type = .Underline
        case "strikethrough": type = .Strikethrough
        case "code": type = .Code
        case "pre": type = .Pre(language: value["language"] as? String)
        case "spoiler": type = .Spoiler
        case "blockquote": type = .BlockQuote(isCollapsed: value["collapsed"] as? Bool ?? false)
        case "text_link":
            guard let url = value["url"] as? String, !url.isEmpty else { return nil }
            type = .TextUrl(url: url)
        case "custom_emoji":
            guard let id = value["document_id"] as? Int64, id > 0 else { return nil }
            type = .CustomEmoji(stickerPack: nil, fileId: id)
        case "url": type = .Url
        case "mention": type = .Mention
        case "hashtag": type = .Hashtag
        case "bot_command": type = .BotCommand
        case "email": type = .Email
        case "phone_number": type = .PhoneNumber
        case "text_mention":
            guard let id = value["user_id"] as? Int64, id > 0, id <= 0x00ffffffffffffff else { return nil }
            type = .TextMention(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id)))
        default: return nil
        }
        return MessageTextEntity(range: offset ..< offset + length, type: type)
    }
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
    private var requestHookSnapshot: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var incomingDisposable: Disposable?
    private var userDisposable: Disposable?
    private var requests: [String: Disposable] = [:]
    private let pluginUI = AfterGramPluginUI()
    private var selfUser: [String: Any]?
    private var enabledPluginIds: Set<String> = []
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
        self.userDisposable?.dispose()
        for request in self.requests.values { request.dispose() }
        self.pluginUI.dispose()
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
        account.network.afterGramPluginShouldHook = { [weak self] name in
            guard let self else { return false }
            let key = "TL_" + name.replacingOccurrences(of: ".", with: "_")
            self.lock.lock();defer { self.lock.unlock() }
            return self.active && self.requestHookSnapshot.contains { entry in
                guard let hook = entry["name"] as? String else { return false }
                return entry["substring"] as? Bool == true ? key.contains(hook) : key == hook
            }
        }
        account.network.afterGramPluginRequestHook = { [weak self] name, stage, payload, error, completion in
            guard let self else { completion(payload);return }
            Self.queue.async { [weak self] in
                guard let self else { completion(payload);return }
                var request: [String: Any] = ["op":"request_hook", "name":name, "stage":stage, "payload":payload.base64EncodedString()]
                if let error { request["error"] = error }
                let result = self.execute(request)
                if result["cancel"] as? Bool == true { completion(nil) }
                else if let encoded = result["payload"] as? String, let data = Data(base64Encoded: encoded) { completion(data) }
                else { completion(payload) }
            }
        }
        self.userDisposable = account.postbox.peerView(id: account.peerId).start(next: { [weak self] view in
            let user = (view.peers[account.peerId] as? TelegramUser).map(afterGramPluginUserSnapshot)
            Self.queue.async { [weak self] in self?.selfUser = user }
        })
        self.incomingDisposable = account.stateManager.pluginIncomingMessages.start(next: { [weak self] messages in
            guard let self, self.isActive else { return }
            for message in messages where message.id.namespace == Namespaces.Message.Cloud {
                let peer = afterGramDialogId(message.id.peerId)
                let name = message.id.peerId.namespace == Namespaces.Peer.CloudChannel ? "TL_updateNewChannelMessage" : "TL_updateNewMessage"
                var request: [String: Any] = ["op": "update", "name": name, "peer": String(peer), "native_peer": String(message.id.peerId.toInt64()), "update": ["message": ["id": message.id.id, "message": message.text, "dialog_id": peer, "out": false, "date":message.timestamp]]]
                if let value = message.peers[message.id.peerId], let input = apiInputPeer(value) {
                    let buffer = Buffer();input.serialize(buffer, true);request["peer_wire"] = buffer.makeData().base64EncodedString()
                }
                self.request(request) { _ in }
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
        if let account = self.account { request["self_id"] = account.peerId.id._internalGetInt64Value() }
        if let user = self.selfUser { request["self_user"] = user }
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
        let callbacks = Set(status["callbacks"] as? [String] ?? [])
        self.pluginUI.synchronize(Set(status["dialogs"] as? [String] ?? []))
        for key in Array(self.requests.keys) where !callbacks.contains(key) {
            self.requests.removeValue(forKey: key)?.dispose()
        }
        self.enabledPluginIds = Set((status["plugins"] as? [[String: Any]] ?? []).filter { $0["enabled"] as? Bool == true }.compactMap { $0["id"] as? String })
        self.lock.lock()
        self.active = (status["plugins"] as? [[String: Any]] ?? []).contains { $0["enabled"] as? Bool == true }
        self.menuSnapshot = menuStatus["menus"] as? [[String: Any]] ?? []
        self.requestHookSnapshot = status["hooks"] as? [[String: Any]] ?? []
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
        guard let account = self.account else { return .single(messages.map { Optional($0) }) }
        return account.postbox.transaction { transaction -> String? in
            guard let peer = transaction.getPeer(peerId), let input = apiInputPeer(peer) else { return nil }
            let buffer = Buffer();input.serialize(buffer, true);return buffer.makeData().base64EncodedString()
        } |> mapToSignal { [weak self] wire -> Signal<[EnqueueMessage?], NoError> in
            guard let self else { return .single(messages.map { Optional($0) }) }
            return self.transformPrepared(peerId: peerId, messages: messages, peerWire: wire)
        }
    }
    private func transformPrepared(peerId: PeerId, messages: [EnqueueMessage], peerWire: String?) -> Signal<[EnqueueMessage?], NoError> {
        return Signal { subscriber in
            let cancelled = Atomic(value: false)
            Self.queue.async { [weak self] in
                guard let self, !cancelled.with({ $0 }) else { subscriber.putCompletion(); return }
                var transformed: [EnqueueMessage?] = []
                for message in messages {
                    if cancelled.with({ $0 }) { return }
                    switch message {
                    case let .message(text, attributes, inlineStickers, media, threadId, reply, story, grouping, correlation, bubble):
                        var request: [String: Any] = ["op": "outgoing", "text": text, "peer": String(afterGramDialogId(peerId)), "native_peer": String(peerId.toInt64())]
                        if let wire = peerWire { request["peer_wire"] = wire }
                        let response = self.execute(request)
                        if response["cancel"] as? Bool == true {
                            transformed.append(nil)
                        } else {
                            let updated = response["text"] as? String ?? text
                            // Old entity ranges and inline stickers cannot describe rewritten text.
                            var updatedAttributes = updated == text ? attributes : attributes.filter { !($0 is TextEntitiesMessageAttribute) }
                            if let entities = response["entities"] as? [[String: Any]] {
                                updatedAttributes.removeAll { $0 is TextEntitiesMessageAttribute }
                                updatedAttributes.append(TextEntitiesMessageAttribute(entities: afterGramTextEntities(entities, text: updated)))
                            }
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
        case "dialog", "dialog_update", "dialog_dismiss", "open_url", "share":
            self.pluginUI.handle(action) { [weak self] response in self?.request(response) { _ in } }
        case "rpc":
            guard let callback = action["callback"] as? String, let name = action["name"] as? String,
                  let payload = action["payload"] as? String, let data = Data(base64Encoded: payload),
                  data.count >= 4, data.count <= 8 * 1024 * 1024,
                  let signature = BufferReader(Buffer(data: data)).readInt32(), afterGramApiFunctionNames[signature] == name else { return }
            let description = FunctionDescription(name: name, parameters: [])
            let parser = DeserializeFunctionResponse<String> { buffer in
                return buffer.makeData().base64EncodedString()
            }
            let disposable = account.network.request((description, Buffer(data: data), parser), automaticFloodWait: false).start(next: { [weak self] response in
                guard let self else { return }
                Self.queue.async { [weak self] in
                    guard let self else { return }
                    self.requests.removeValue(forKey: callback)?.dispose()
                    var parsed: Any?
                    if let bufferData = Data(base64Encoded: response) {
                        if afterGramApiFunctionResultTypes[name]?.hasPrefix("Api.") == true {
                            parsed = Api.parse(Buffer(data: bufferData))
                        } else if afterGramApiFunctionResultTypes[name] == "[Api.User]" {
                            let reader = BufferReader(Buffer(data: bufferData))
                            if reader.readInt32() == 0x1cb5c415 { parsed = Api.parseVector(reader, elementSignature: 0, elementType: Api.User.self) }
                        }
                    }
                    if let updates = parsed as? Api.Updates { account.stateManager.addUpdates(updates) }
                    if let parsed {
                        let (users,chats) = afterGramPluginCollectPeers(parsed)
                        if !users.isEmpty || !chats.isEmpty {
                            let _ = account.postbox.transaction({ transaction -> [String: Any]? in
                                updatePeers(transaction: transaction, accountPeerId: account.peerId, peers: AccumulatedPeers(transaction: transaction, chats: chats, users: users))
                                return (transaction.getPeer(account.peerId) as? TelegramUser).map(afterGramPluginUserSnapshot)
                            }).startStandalone(next: { [weak self] user in
                                Self.queue.async { [weak self] in
                                    guard let self else { return }
                                    if let user { self.selfUser = user }
                                    self.execute(["op":"rpc_result", "callback":callback, "payload":response])
                                }
                            })
                            return
                        }
                    }
                    self.execute(["op": "rpc_result", "callback": callback, "payload": response])
                }
            }, error: { [weak self] error in
                Self.queue.async { [weak self] in
                    guard let self else { return }
                    self.requests.removeValue(forKey: callback)?.dispose()
                    self.execute(["op": "rpc_result", "callback": callback, "error": ["code": error.errorCode, "text": error.errorDescription ?? "RPC error"]])
                }
            })
            self.requests[callback] = disposable
        case "cancel_rpc":
            if let callback = action["callback"] as? String { self.requests.removeValue(forKey: callback)?.dispose() }
        case "notice":
            self.pluginUI.handle(action) { _ in }
        case "clipboard":
            let text = action["text"] as? String ?? ""
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        case "send", "edit":
            if let value = action["media"] as? [String: Any] {
                Task { [weak self] in
                    let media = await afterGramPluginMedia(account: account, value: value)
                    Self.queue.async { [weak self] in
                        guard let self, let owner = action["plugin"] as? String, self.enabledPluginIds.contains(owner) else { return }
                        guard let media else { self.execute(["op":"native_error", "text":"Cannot prepare plugin media file"]);return }
                        self.enqueuePluginMessage(account: account, action: action, media: media)
                    }
                }
            } else { self.enqueuePluginMessage(account: account, action: action, media: nil) }
        default:
            break
        }
    }
    private func enqueuePluginMessage(account: Account, action: [String: Any], media: AnyMediaReference?) {
        guard let raw = action["peer"] as? String, let dialogId = Int64(raw), dialogId != Int64.min, abs(dialogId) <= 0x00ffffffffffffff, let text = action["text"] as? String else { return }
        let mediaValue = action["media"] as? [String: Any]
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
            guard let peer else {
                self.request(["op": "native_error", "text": "Chat is unavailable or its Telegram ID is ambiguous"]) { _ in }
                return .single([])
            }
            let entities = afterGramTextEntities(action["entities"] as? [[String: Any]] ?? [], text: text)
            if action["type"] as? String == "edit" {
                guard let id = action["id"] as? Int64, id > 0, id <= Int64(Int32.max) else { return .single([]) }
                return _internal_requestEditMessage(account: account, messageId: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: Int32(id)), text: text, media: .keep, entities: TextEntitiesMessageAttribute(entities: entities), richText: nil, inlineStickers: [:], webpagePreviewAttribute: nil, disableUrlPreview: false, scheduleInfoAttribute: nil, invertMediaAttribute: nil)
                |> map { _ -> [MessageId?] in return [] }
                |> `catch` { _ -> Signal<[MessageId?], NoError> in
                    self.request(["op": "native_error", "text": "Telegram could not edit the message"]) { _ in }
                    return .single([])
                }
            }
            var attributes: [MessageAttribute] = []
            if !entities.isEmpty { attributes.append(TextEntitiesMessageAttribute(entities: entities)) }
            if mediaValue?["spoiler"] as? Bool == true { attributes.append(MediaSpoilerMessageAttribute()) }
            if action["notify"] as? Bool == false { attributes.append(NotificationInfoMessageAttribute(flags: .muted)) }
            if let schedule = action["schedule"] as? Int64, schedule > 0, schedule <= Int64(Int32.max) {
                attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: Int32(schedule), repeatPeriod: nil))
            }
            var reply: EngineMessageReplySubject?
            if let replyId = action["reply"] as? Int64, replyId > 0, replyId <= Int64(Int32.max) {
                reply = EngineMessageReplySubject(messageId: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: Int32(replyId)), quote: nil, innerSubject: nil)
            }
            let message = EnqueueMessage.message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: media, threadId: nil, replyToMessageId: reply, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
            // Plugin sends bypass plugin hooks to avoid recursive auto-replies.
            return enqueueMessagesWithoutPlugins(account: account, peerId: peer, messages: [message])
        }
        let _ = signal.startStandalone()
    }

}
