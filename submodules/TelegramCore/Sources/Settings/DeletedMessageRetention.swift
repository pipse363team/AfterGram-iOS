import Foundation
import Postbox
import SwiftSignalKit

private let deletedMessageRetentionFileQueue = DispatchQueue(label: "org.telegram.deletedMessageRetention.files", qos: .utility)

/// File-system work for retained media must not run on the UI queue. The result is
/// returned on main so the prefetcher's state machine stays confined to that queue.
func performDeletedMessageRetentionFileOperation<T>(_ operation: @escaping () -> T, completion: @escaping (T) -> Void) -> Disposable {
    let cancelled = Atomic<Bool>(value: false)
    let workItem = DispatchWorkItem {
        guard !cancelled.with({ $0 }) else { return }
        let result = operation()
        DispatchQueue.main.async {
            guard !cancelled.with({ $0 }) else { return }
            completion(result)
        }
    }
    deletedMessageRetentionFileQueue.async(execute: workItem)
    return ActionDisposable {
        _ = cancelled.swap(true)
        workItem.cancel()
    }
}

public struct DeletedMessageRetentionSettings: Codable, Equatable {
    public var enabled: Bool
    public static let defaultValue = DeletedMessageRetentionSettings(enabled: true)
}

public let deletedMessageRetentionKey = applicationSpecificPreferencesKey(0x574741)

public final class EditedMessageRevision: PostboxCoding {
    public let timestamp: Int32
    public let text: String
    public let entities: [MessageTextEntity]
    public let media: [Media]

    public init(timestamp: Int32, text: String, entities: [MessageTextEntity], media: [Media]) {
        self.timestamp = timestamp
        self.text = text
        self.entities = entities
        self.media = media
    }

    public init(decoder: PostboxDecoder) {
        self.timestamp = decoder.decodeInt32ForKey("t", orElse: 0)
        self.text = decoder.decodeStringForKey("x", orElse: "")
        self.entities = decoder.decodeObjectArrayForKey("e")
        let decodedMedia: [PostboxCoding] = decoder.decodeObjectArrayForKey("m")
        self.media = decodedMedia.compactMap { $0 as? Media }
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.timestamp, forKey: "t")
        encoder.encodeString(self.text, forKey: "x")
        encoder.encodeObjectArray(self.entities, forKey: "e")
        encoder.encodeObjectArrayWithEncoder(self.media, forKey: "m", encoder: { media, encoder in
            media.encode(encoder)
        })
    }
}

public final class EditedMessageHistoryAttribute: MessageAttribute {
    public let revisions: [EditedMessageRevision]

    public init(revisions: [EditedMessageRevision]) {
        self.revisions = revisions
    }

    public required init(decoder: PostboxDecoder) {
        self.revisions = decoder.decodeObjectArrayForKey("r")
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeObjectArray(self.revisions, forKey: "r")
    }
}

public extension Message {
    var editedMessageRevisions: [EditedMessageRevision] {
        return (self.attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute)?.revisions ?? []
    }
}

/// Keep the prior content on the current message row before applying a server edit.
/// Repeated edit updates with identical content are ignored.
func editedMessageHistoryAttributes(previousMessage: Message, updatedText: String, updatedAttributes: [MessageAttribute], updatedMedia: [Media], mediaBox: MediaBox) -> [MessageAttribute] {
    let existing = previousMessage.editedMessageRevisions
    let previousEntities = previousMessage.textEntitiesAttribute?.entities ?? []
    let updatedEntities = (updatedAttributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
    let contentChanged = previousMessage.text != updatedText || previousEntities != updatedEntities || !areMediaArraysSemanticallyEqual(previousMessage.media, updatedMedia)
    var revisions = existing
    if contentChanged {
        let timestamp = previousMessage.editedTime ?? previousMessage.timestamp
        let revision = EditedMessageRevision(timestamp: timestamp, text: previousMessage.text, entities: previousEntities, media: retainedMessageMedia(previousMessage.media, mediaBox: mediaBox))
        let duplicate = revisions.last.map { $0.text == revision.text && $0.entities == revision.entities && areMediaArraysSemanticallyEqual($0.media, revision.media) } ?? false
        if !duplicate {
            revisions.append(revision)
            if revisions.count > 20 {
                revisions.removeFirst(revisions.count - 20)
            }
        }
    }
    var result = updatedAttributes.filter { !($0 is EditedMessageHistoryAttribute) }
    if !revisions.isEmpty {
        result.append(EditedMessageHistoryAttribute(revisions: revisions))
    }
    return result
}

public func deletedMessageRetentionSettings(postbox: Postbox) -> Signal<DeletedMessageRetentionSettings, NoError> {
    return postbox.preferencesView(keys: [deletedMessageRetentionKey])
    |> map { $0.values[deletedMessageRetentionKey]?.get(DeletedMessageRetentionSettings.self) ?? .defaultValue }
}

public func updateDeletedMessageRetentionSettings(postbox: Postbox, enabled: Bool) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.setPreferencesEntry(key: deletedMessageRetentionKey, value: PreferencesEntry(DeletedMessageRetentionSettings(enabled: enabled)))
    }
    |> ignoreValues
}

func retentionStoreMessage(_ message: Message, attributes: [MessageAttribute], media: [Media], groupingKey: Int64?) -> StoreMessage {
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: message.author?.id, text: message.text, attributes: attributes, media: media)
}

/// Returns only IDs which still require deletion. Call before replaying remote deletes.
func retainRemotelyDeletedMessages(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId]) -> [MessageId] {
    let settings = transaction.getPreferencesEntry(key: deletedMessageRetentionKey)?.get(DeletedMessageRetentionSettings.self) ?? .defaultValue
    guard settings.enabled else {
        return ids.filter { transaction.getMessage($0)?.isRemotelyDeleted != true }
    }
    var remove: [MessageId] = []
    for id in ids {
        guard id.namespace == Namespaces.Message.Cloud,
              id.peerId.namespace != Namespaces.Peer.SecretChat,
              let message = transaction.getMessage(id) else {
            remove.append(id)
            continue
        }
        if message.isRemotelyDeleted { continue }
        transaction.updateMessage(id, update: { current in
            let attributes = current.attributes + [RemotelyDeletedMessageAttribute(timestamp: Int32(Date().timeIntervalSince1970))]
            let media = retainedMessageMedia(current.media, mediaBox: mediaBox)
            // Separate deleted album members so unaffected members are not faded.
            return .update(retentionStoreMessage(current, attributes: attributes, media: media, groupingKey: nil))
        })
    }
    return remove
}

func retainedMediaFileId(_ resource: MediaResource) -> Int64 {
    // Stable across launches, unlike Swift's randomized Hasher.
    var hash: UInt64 = 14695981039346656037
    for byte in resource.id.stringRepresentation.utf8 {
        hash = (hash ^ UInt64(byte)) &* 1099511628211
    }
    return Int64(bitPattern: hash)
}

func retainedMediaPath(fileId: Int64, mediaBox: MediaBox) -> String {
    return mediaBox.basePath + "/retained-message-media/resource-\(fileId)"
}

func hasRetainedMediaBytes(_ media: Media, mediaBox: MediaBox) -> Bool {
    func hasRetainedResource(_ resource: MediaResource) -> Bool {
        guard let resource = resource as? LocalFileMediaResource else { return false }
        return FileManager.default.fileExists(atPath: retainedMediaPath(fileId: resource.fileId, mediaBox: mediaBox))
    }

    if let file = media as? TelegramMediaFile {
        return hasRetainedResource(file.resource)
    } else if let image = media as? TelegramMediaImage {
        return image.representations.contains(where: { hasRetainedResource($0.resource) })
    }
    return false
}

/// Keep bytes outside both MediaBox caches. A hard link also survives cache unlinking.
func copyRetainedMedia(resource: MediaResource, mediaBox: MediaBox, source: String? = nil) -> LocalFileMediaResource? {
    if let resource = resource as? LocalFileMediaResource,
       FileManager.default.fileExists(atPath: retainedMediaPath(fileId: resource.fileId, mediaBox: mediaBox)) { return resource }
    let fileId = retainedMediaFileId(resource)
    let directory = mediaBox.basePath + "/retained-message-media"
    let path = retainedMediaPath(fileId: fileId, mediaBox: mediaBox)
    let manager = FileManager.default
    if !manager.fileExists(atPath: path) {
        guard let source = source ?? mediaBox.completedResourcePath(resource) else { return nil }
        do {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let temporary = path + "." + UUID().uuidString
            defer { try? manager.removeItem(atPath: temporary) }
            do { try manager.linkItem(atPath: source, toPath: temporary) }
            catch { try manager.copyItem(atPath: source, toPath: temporary) }
            // Concurrent attempts may already have installed the same immutable resource.
            if !manager.fileExists(atPath: path) { try manager.moveItem(atPath: temporary, toPath: path) }
        } catch { return nil }
    }
    return LocalFileMediaResource(fileId: fileId, size: resource.size)
}

func retainedMessageMedia(_ media: [Media], mediaBox: MediaBox) -> [Media] {
    return media.map { media in
        if let file = media as? TelegramMediaFile, let resource = copyRetainedMedia(resource: file.resource, mediaBox: mediaBox) {
            let previews = file.previewRepresentations.map { retainedImageRepresentation($0, mediaBox: mediaBox) }
            return TelegramMediaFile(fileId: file.fileId, partialReference: file.partialReference, resource: resource, previewRepresentations: previews, videoThumbnails: file.videoThumbnails, videoCover: file.videoCover, immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes, alternativeRepresentations: [])
        } else if let image = media as? TelegramMediaImage {
            return TelegramMediaImage(imageId: image.imageId, representations: image.representations.map { retainedImageRepresentation($0, mediaBox: mediaBox) }, videoRepresentations: image.videoRepresentations, immediateThumbnailData: image.immediateThumbnailData, emojiMarkup: image.emojiMarkup, reference: image.reference, partialReference: image.partialReference, flags: image.flags, video: image.video)
        }
        return media
    }
}

/// Expire view-once media from the normal cache while keeping a separate copy when
/// the retained-message setting is enabled and the bytes have already arrived.
func retainedOrExpiredSecretMedia(_ media: [Media], enabled: Bool, mediaBox: MediaBox) -> [Media] {
    return media.map { item in
        if enabled,
           let retained = retainedMessageMedia([item], mediaBox: mediaBox).first,
           hasRetainedMediaBytes(retained, mediaBox: mediaBox) {
            return retained
        }
        if item is TelegramMediaImage {
            return TelegramMediaExpiredContent(data: .image)
        } else if let file = item as? TelegramMediaFile {
            if file.isInstantVideo {
                return TelegramMediaExpiredContent(data: .videoMessage)
            } else if file.isVoice {
                return TelegramMediaExpiredContent(data: .voiceMessage)
            } else {
                return TelegramMediaExpiredContent(data: .file)
            }
        }
        return item
    }
}

private func retainedImageRepresentation(_ representation: TelegramMediaImageRepresentation, mediaBox: MediaBox) -> TelegramMediaImageRepresentation {
    guard let resource = copyRetainedMedia(resource: representation.resource, mediaBox: mediaBox) else { return representation }
    return TelegramMediaImageRepresentation(dimensions: representation.dimensions, resource: resource, progressiveSizes: representation.progressiveSizes, immediateThumbnailData: representation.immediateThumbnailData, hasVideo: representation.hasVideo, isPersonal: representation.isPersonal, typeHint: representation.typeHint)
}

/// Account-owned downloads continue when message views scroll offscreen. Two at a time.
public final class DeletedMessageMediaPrefetcher {
    private weak var account: Account?
    private var enabled: Bool?
    private var initialMessages: [Message] = []
    private let settingsDisposable = MetaDisposable()
    private var pending: [(Message, Media, MediaResource)] = []
    private var known = Set<MediaResourceId>()
    private var waitingMessages: [MediaResourceId: Set<MessageId>] = [:]
    private var active: [MediaResourceId: DisposableSet] = [:]
    private var fileOperations: [MediaResourceId: Disposable] = [:]
    private var generation: Int = 0

    init(account: Account) {
        self.account = account
        self.settingsDisposable.set((deletedMessageRetentionSettings(postbox: account.postbox) |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else { return }
            self.enabled = settings.enabled
            let initialMessages = self.initialMessages
            self.initialMessages.removeAll()
            if !settings.enabled {
                self.generation &+= 1
                self.pending.removeAll()
                self.active.values.forEach { $0.dispose() }
                self.active.removeAll()
                self.fileOperations.values.forEach { $0.dispose() }
                self.fileOperations.removeAll()
                self.known.removeAll()
                self.waitingMessages.removeAll()
            } else {
                for message in initialMessages { self.prepare(message) }
            }
        }))
    }

    deinit {
        self.settingsDisposable.dispose()
        self.active.values.forEach { $0.dispose() }
        self.fileOperations.values.forEach { $0.dispose() }
    }

    public func prepare(_ message: Message) {
        Queue.mainQueue().async { [weak self] in
            guard let self, let account = self.account,
                  message.id.namespace == Namespaces.Message.Cloud else { return }
            guard let enabled = self.enabled else {
                self.initialMessages.append(message)
                return
            }
            guard enabled else { return }
            for media in message.media {
                var resources: [MediaResource] = []
                if let file = media as? TelegramMediaFile {
                    resources = [file.resource] + file.previewRepresentations.map { $0.resource }
                } else if let image = media as? TelegramMediaImage {
                    resources = image.representations.map { $0.resource }
                }
                for resource in resources where !(resource is LocalFileMediaResource) {
                    self.waitingMessages[resource.id, default: []].insert(message.id)
                    guard self.known.insert(resource.id).inserted else { continue }
                    let generation = self.generation
                    let operation = performDeletedMessageRetentionFileOperation({
                        copyRetainedMedia(resource: resource, mediaBox: account.postbox.mediaBox) != nil
                    }, completion: { [weak self] alreadyRetained in
                        guard let self, self.generation == generation, self.enabled == true else { return }
                        self.fileOperations.removeValue(forKey: resource.id)
                        if alreadyRetained {
                            self.known.remove(resource.id)
                            self.waitingMessages.removeValue(forKey: resource.id)
                        } else {
                            self.pending.append((message, media, resource))
                            self.advance()
                        }
                    })
                    self.fileOperations[resource.id] = operation
                }
            }
        }
    }

    private func advance() {
        guard let account = self.account, self.enabled == true else { return }
        while self.active.count < 2, !self.pending.isEmpty {
            let (message, media, resource) = self.pending.removeFirst()
            let bag = DisposableSet()
            self.active[resource.id] = bag
            let generation = self.generation
            bag.add((fetchedMediaResource(mediaBox: account.postbox.mediaBox, userLocation: .peer(message.id.peerId), userContentType: .other, reference: .media(media: .message(message: MessageReference(message), media: media), resource: resource)) |> deliverOnMainQueue).start(error: { [weak self] _ in
                guard let self, self.generation == generation, self.enabled == true else { return }
                self.finish(resource.id)
            }))
            bag.add((account.postbox.mediaBox.resourceData(resource) |> filter { $0.complete } |> take(1) |> deliverOnMainQueue).start(next: { [weak self, weak account] data in
                guard let self, let account, self.generation == generation, self.enabled == true else { return }
                let operation = performDeletedMessageRetentionFileOperation({
                    copyRetainedMedia(resource: resource, mediaBox: account.postbox.mediaBox, source: data.path) != nil
                }, completion: { [weak self, weak account] copied in
                    guard let self, let account, self.generation == generation, self.enabled == true else { return }
                    self.fileOperations.removeValue(forKey: resource.id)
                    if copied {
                        let messageIds = Array(self.waitingMessages[resource.id] ?? [])
                        let _ = account.postbox.transaction { transaction -> Void in
                            for id in messageIds {
                                guard let current = transaction.getMessage(id), current.isRemotelyDeleted else { continue }
                                transaction.updateMessage(id, update: { current in
                                    return .update(retentionStoreMessage(current, attributes: current.attributes, media: retainedMessageMedia(current.media, mediaBox: account.postbox.mediaBox), groupingKey: current.groupingKey))
                                })
                            }
                        }.start()
                    }
                    self.finish(resource.id)
                })
                self.fileOperations[resource.id] = operation
                bag.add(operation)
            }))
        }
    }

    private func finish(_ id: MediaResourceId) {
        self.active.removeValue(forKey: id)?.dispose()
        self.fileOperations.removeValue(forKey: id)?.dispose()
        self.known.remove(id)
        self.waitingMessages.removeValue(forKey: id)
        self.advance()
    }
}
