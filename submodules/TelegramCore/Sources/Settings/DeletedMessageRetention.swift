import Foundation
import Postbox
import SwiftSignalKit

public struct DeletedMessageRetentionSettings: Codable, Equatable {
    public var enabled: Bool
    public static let defaultValue = DeletedMessageRetentionSettings(enabled: true)
}

public let deletedMessageRetentionKey = applicationSpecificPreferencesKey(0x574741)

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

public struct AfterGramEditedMessageHistorySettings: Codable, Equatable {
    public var enabled: Bool
    public static let defaultValue = AfterGramEditedMessageHistorySettings(enabled: true)
}

public let afterGramEditedMessageHistoryKey = applicationSpecificPreferencesKey(0x574742)

public func afterGramEditedMessageHistorySettings(postbox: Postbox) -> Signal<AfterGramEditedMessageHistorySettings, NoError> {
    return postbox.preferencesView(keys: [afterGramEditedMessageHistoryKey])
    |> map { $0.values[afterGramEditedMessageHistoryKey]?.get(AfterGramEditedMessageHistorySettings.self) ?? .defaultValue }
}

public func updateAfterGramEditedMessageHistorySettings(postbox: Postbox, enabled: Bool) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.setPreferencesEntry(key: afterGramEditedMessageHistoryKey, value: PreferencesEntry(AfterGramEditedMessageHistorySettings(enabled: enabled)))
    }
    |> ignoreValues
}

func retentionStoreMessage(_ message: Message, attributes: [MessageAttribute], media: [Media], groupingKey: Int64?) -> StoreMessage {
    return StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: message.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: message.author?.id, text: message.text, attributes: attributes, media: media)
}

public func afterGramIsViewOnceAttributes(_ attributes: [MessageAttribute]) -> Bool {
    return attributes.contains(where: {
        ($0 as? AutoclearTimeoutMessageAttribute)?.timeout == viewOnceTimeout ||
        ($0 as? AutoremoveTimeoutMessageAttribute)?.timeout == viewOnceTimeout
    })
}

func afterGramIsViewOnceMessage(_ message: Message) -> Bool {
    return afterGramIsViewOnceAttributes(message.attributes)
}

/// Once a remotely deleted message reaches its normal auto-clear deadline, keep its
/// archived content but remove the timer attribute so the expiry operation cannot
/// repeatedly schedule itself.
func retainedRemoteDeletedMessageAfterAutoclear(_ message: Message, mediaBox: MediaBox) -> StoreMessage? {
    guard message.isRemotelyDeleted else { return nil }
    let attributes = message.attributes.filter { !($0 is AutoclearTimeoutMessageAttribute) }
    return retentionStoreMessage(message, attributes: attributes, media: retainedMessageMedia(message.media, mediaBox: mediaBox), groupingKey: message.groupingKey)
}

/// Converts an expired view-once message into a regular local message only after
/// its primary media bytes have been copied out of MediaBox's evictable cache.
func retainedViewOnceMessageAfterAutoclear(_ message: Message, mediaBox: MediaBox) -> StoreMessage? {
    guard afterGramIsViewOnceMessage(message),
          let backup = message.attributes.first(where: { $0 is AfterGramViewOnceMediaBackupAttribute }) as? AfterGramViewOnceMediaBackupAttribute,
          !backup.media.isEmpty else { return nil }

    let media = retainedMessageMedia(backup.media, mediaBox: mediaBox)
    let hasStablePrimaryMedia = media.contains { item in
        if let file = item as? TelegramMediaFile,
           let resource = file.resource as? LocalFileMediaResource {
            return FileManager.default.fileExists(atPath: retainedMediaPath(fileId: resource.fileId, mediaBox: mediaBox))
        } else if let image = item as? TelegramMediaImage,
                  image.representations.contains(where: { representation in
                      guard let resource = representation.resource as? LocalFileMediaResource else { return false }
                      return FileManager.default.fileExists(atPath: retainedMediaPath(fileId: resource.fileId, mediaBox: mediaBox))
                  }) {
            return true
        }
        return false
    }
    guard hasStablePrimaryMedia else { return nil }

    let attributes = message.attributes.filter { attribute in
        if attribute is AfterGramViewOnceMediaBackupAttribute { return false }
        if let attribute = attribute as? AutoclearTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout { return false }
        if let attribute = attribute as? AutoremoveTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout { return false }
        return true
    }
    return retentionStoreMessage(message, attributes: attributes, media: media, groupingKey: message.groupingKey)
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
            let backedUpMedia = current.attributes.first(where: { $0 is AfterGramViewOnceMediaBackupAttribute }) as? AfterGramViewOnceMediaBackupAttribute
            var attributes = current.attributes.filter { !($0 is AfterGramViewOnceMediaBackupAttribute) }
            attributes.append(RemotelyDeletedMessageAttribute(timestamp: Int32(Date().timeIntervalSince1970)))
            let media = retainedMessageMedia(backedUpMedia?.media ?? current.media, mediaBox: mediaBox)
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
            return TelegramMediaFile(fileId: file.fileId, partialReference: file.partialReference, resource: resource, previewRepresentations: file.previewRepresentations, videoThumbnails: file.videoThumbnails, videoCover: file.videoCover, immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes, alternativeRepresentations: [])
        } else if let image = media as? TelegramMediaImage {
            // Once the view-once resource expires, even a smaller CDN representation can
            // resolve to unrelated/stale content. Expose only representations whose bytes
            // have been copied to AfterGram's durable local store.
            let representations = image.representations.compactMap { retainedImageRepresentation($0, mediaBox: mediaBox) }
            if !representations.isEmpty {
                return TelegramMediaImage(imageId: image.imageId, representations: representations, videoRepresentations: image.videoRepresentations, immediateThumbnailData: image.immediateThumbnailData, emojiMarkup: image.emojiMarkup, reference: nil, partialReference: nil, flags: image.flags, video: image.video)
            }
        }
        return media
    }
}

private func retainedImageRepresentation(_ representation: TelegramMediaImageRepresentation, mediaBox: MediaBox) -> TelegramMediaImageRepresentation? {
    guard let resource = copyRetainedMedia(resource: representation.resource, mediaBox: mediaBox) else { return nil }
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
    private var active: [MediaResourceId: DisposableSet] = [:]

    init(account: Account) {
        self.account = account
        self.settingsDisposable.set((deletedMessageRetentionSettings(postbox: account.postbox) |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else { return }
            self.enabled = settings.enabled
            let initialMessages = self.initialMessages
            self.initialMessages.removeAll()
            if !settings.enabled {
                self.pending.removeAll()
                self.active.values.forEach { $0.dispose() }
                self.active.removeAll()
                self.known.removeAll()
            } else {
                for message in initialMessages { self.prepare(message) }
            }
        }))
    }

    deinit {
        self.settingsDisposable.dispose()
        self.active.values.forEach { $0.dispose() }
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
            if afterGramIsViewOnceMessage(message) || message.attributes.contains(where: { $0 is AfterGramViewOnceMediaBackupAttribute }) {
                let _ = account.postbox.transaction { transaction -> [Media] in
                    guard let current = transaction.getMessage(message.id) else {
                        return message.media
                    }
                    if let existing = current.attributes.first(where: { $0 is AfterGramViewOnceMediaBackupAttribute }) as? AfterGramViewOnceMediaBackupAttribute {
                        return existing.media
                    }
                    guard afterGramIsViewOnceMessage(current) else { return current.media }
                    let backupMedia = current.media
                    let attributes = current.attributes + [AfterGramViewOnceMediaBackupAttribute(media: backupMedia)]
                    transaction.updateMessage(current.id, update: { current in
                        return .update(retentionStoreMessage(current, attributes: attributes, media: current.media, groupingKey: current.groupingKey))
                    })
                    return backupMedia
                }.start(next: { [weak self] media in
                    self?.prepareMedia(message, media: media)
                })
            } else {
                self.prepareMedia(message, media: message.media)
            }
        }
    }

    private func prepareMedia(_ message: Message, media messageMedia: [Media]) {
        Queue.mainQueue().async { [weak self] in
            guard let self, let account = self.account, self.enabled == true else { return }
            for media in messageMedia {
                var resources: [MediaResource] = []
                if let file = media as? TelegramMediaFile {
                    resources = [file.resource]
                } else if let image = media as? TelegramMediaImage, let largest = image.representations.max(by: {
                    Int64($0.dimensions.width) * Int64($0.dimensions.height) < Int64($1.dimensions.width) * Int64($1.dimensions.height)
                }) {
                    resources = [largest.resource]
                }
                for resource in resources {
                    let retainedPath = retainedMediaPath(fileId: retainedMediaFileId(resource), mediaBox: account.postbox.mediaBox)
                    if FileManager.default.fileExists(atPath: retainedPath) { continue }
                    guard self.known.insert(resource.id).inserted else { continue }
                    if resource is LocalFileMediaResource {
                        guard let source = account.postbox.mediaBox.completedResourcePath(resource) else {
                            self.known.remove(resource.id)
                            continue
                        }
                        DispatchQueue.global(qos: .utility).async { [weak self, weak account] in
                            if let account {
                                _ = copyRetainedMedia(resource: resource, mediaBox: account.postbox.mediaBox, source: source)
                            }
                            Queue.mainQueue().async {
                                self?.finish(resource.id)
                            }
                        }
                    } else {
                        self.pending.append((message, media, resource))
                    }
                }
            }
            self.advance()
        }
    }

    private func advance() {
        guard let account = self.account, self.enabled == true else { return }
        while self.active.count < 1, !self.pending.isEmpty {
            let (message, media, resource) = self.pending.removeFirst()
            let bag = DisposableSet()
            self.active[resource.id] = bag
            bag.add((fetchedMediaResource(mediaBox: account.postbox.mediaBox, userLocation: .peer(message.id.peerId), userContentType: .other, reference: .media(media: .message(message: MessageReference(message), media: media), resource: resource)) |> deliverOnMainQueue).start(error: { [weak self] _ in
                self?.finish(resource.id)
            }))
            bag.add((account.postbox.mediaBox.resourceData(resource) |> filter { $0.complete } |> take(1) |> deliverOnMainQueue).start(next: { [weak self, weak account] data in
                guard let self, let account, self.enabled == true else { return }
                // Detach completed bytes off the UI/database queues. The backup
                // descriptor stays unchanged, so this does not re-render the chat row.
                DispatchQueue.global(qos: .utility).async { [weak self, weak account] in
                    if let account {
                        _ = copyRetainedMedia(resource: resource, mediaBox: account.postbox.mediaBox, source: data.path)
                    }
                    Queue.mainQueue().async {
                        self?.finish(resource.id)
                    }
                }
            }))
        }
    }

    private func finish(_ id: MediaResourceId) {
        self.active.removeValue(forKey: id)?.dispose()
        self.known.remove(id)
        self.advance()
    }
}
