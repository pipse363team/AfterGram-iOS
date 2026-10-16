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

func afterGramIsViewOnceMessage(_ message: Message) -> Bool {
    return message.attributes.contains(where: { ($0 as? AutoclearTimeoutMessageAttribute)?.timeout == viewOnceTimeout })
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
            let previews = file.previewRepresentations.map { retainedImageRepresentation($0, mediaBox: mediaBox) }
            return TelegramMediaFile(fileId: file.fileId, partialReference: file.partialReference, resource: resource, previewRepresentations: previews, videoThumbnails: file.videoThumbnails, videoCover: file.videoCover, immediateThumbnailData: file.immediateThumbnailData, mimeType: file.mimeType, size: file.size, attributes: file.attributes, alternativeRepresentations: [])
        } else if let image = media as? TelegramMediaImage {
            return TelegramMediaImage(imageId: image.imageId, representations: image.representations.map { retainedImageRepresentation($0, mediaBox: mediaBox) }, videoRepresentations: image.videoRepresentations, immediateThumbnailData: image.immediateThumbnailData, emojiMarkup: image.emojiMarkup, reference: image.reference, partialReference: image.partialReference, flags: image.flags, video: image.video)
        }
        return media
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
                self.waitingMessages.removeAll()
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
                    let existing = current.attributes.first(where: { $0 is AfterGramViewOnceMediaBackupAttribute }) as? AfterGramViewOnceMediaBackupAttribute
                    guard existing != nil || afterGramIsViewOnceMessage(current) else { return current.media }
                    let backupMedia = retainedMessageMedia(existing?.media ?? current.media, mediaBox: account.postbox.mediaBox)
                    let attributes = current.attributes.filter { !($0 is AfterGramViewOnceMediaBackupAttribute) } + [AfterGramViewOnceMediaBackupAttribute(media: backupMedia)]
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
                    resources = [file.resource] + file.previewRepresentations.map { $0.resource }
                } else if let image = media as? TelegramMediaImage {
                    resources = image.representations.map { $0.resource }
                }
                for resource in resources where !(resource is LocalFileMediaResource) {
                    if copyRetainedMedia(resource: resource, mediaBox: account.postbox.mediaBox) != nil { continue }
                    self.waitingMessages[resource.id, default: []].insert(message.id)
                    if self.known.insert(resource.id).inserted { self.pending.append((message, media, resource)) }
                }
            }
            self.advance()
        }
    }

    private func advance() {
        guard let account = self.account, self.enabled == true else { return }
        while self.active.count < 2, !self.pending.isEmpty {
            let (message, media, resource) = self.pending.removeFirst()
            let bag = DisposableSet()
            self.active[resource.id] = bag
            bag.add((fetchedMediaResource(mediaBox: account.postbox.mediaBox, userLocation: .peer(message.id.peerId), userContentType: .other, reference: .media(media: .message(message: MessageReference(message), media: media), resource: resource)) |> deliverOnMainQueue).start(error: { [weak self] _ in
                self?.finish(resource.id)
            }))
            bag.add((account.postbox.mediaBox.resourceData(resource) |> filter { $0.complete } |> take(1) |> deliverOnMainQueue).start(next: { [weak self, weak account] data in
                guard let self, let account, self.enabled == true else { return }
                let messageIds = Array(self.waitingMessages[resource.id] ?? [])
                if copyRetainedMedia(resource: resource, mediaBox: account.postbox.mediaBox, source: data.path) != nil {
                    let _ = account.postbox.transaction { transaction -> Void in
                        for id in messageIds {
                            guard let current = transaction.getMessage(id) else { continue }
                            var attributes = current.attributes
                            if let index = attributes.firstIndex(where: { $0 is AfterGramViewOnceMediaBackupAttribute }),
                               let backup = attributes[index] as? AfterGramViewOnceMediaBackupAttribute {
                                attributes[index] = AfterGramViewOnceMediaBackupAttribute(media: retainedMessageMedia(backup.media, mediaBox: account.postbox.mediaBox))
                            }
                            guard current.isRemotelyDeleted || attributes.contains(where: { $0 is AfterGramViewOnceMediaBackupAttribute }) else { continue }
                            let media = current.isRemotelyDeleted ? retainedMessageMedia(current.media, mediaBox: account.postbox.mediaBox) : current.media
                            transaction.updateMessage(id, update: { current in
                                return .update(retentionStoreMessage(current, attributes: attributes, media: media, groupingKey: current.groupingKey))
                            })
                        }
                    }.start()
                }
                self.finish(resource.id)
            }))
        }
    }

    private func finish(_ id: MediaResourceId) {
        self.active.removeValue(forKey: id)?.dispose()
        self.known.remove(id)
        self.waitingMessages.removeValue(forKey: id)
        self.advance()
    }
}
