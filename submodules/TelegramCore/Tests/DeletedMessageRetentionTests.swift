import Foundation
import XCTest
import Postbox
import SwiftSignalKit
@testable import TelegramCore

final class DeletedMessageRetentionTests: XCTestCase {
    private var mediaBox: MediaBox!
    private var directory: String!

    override func setUp() {
        super.setUp()
        initializeAccountManagement()
        self.directory = NSTemporaryDirectory() + "retention-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
        self.mediaBox = MediaBox(basePath: self.directory, isMainProcess: true)
    }

    override func tearDown() {
        let ready = DispatchSemaphore(value: 0)
        let disposable = self.mediaBox.storageBox.totalSize().start(next: { _ in ready.signal() })
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        disposable.dispose()
        self.mediaBox = nil
        try? FileManager.default.removeItem(atPath: self.directory)
        super.tearDown()
    }

    func testRetainedBytesSurviveRemovalOfOriginalCacheFile() throws {
        let resource = LocalFileMediaResource(fileId: 321, size: 5)
        let original = self.directory + "/source"
        let bytes = Data([1, 2, 3, 4, 5])
        try bytes.write(to: URL(fileURLWithPath: original))
        let retained = try XCTUnwrap(copyRetainedMedia(resource: resource, mediaBox: self.mediaBox, source: original))
        try FileManager.default.removeItem(atPath: original)
        let path = retainedMediaPath(fileId: retained.fileId, mediaBox: self.mediaBox)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertEqual(copyRetainedMedia(resource: retained, mediaBox: self.mediaBox)?.fileId, retained.fileId)
    }

    func testMissingMediaIsNotPresentedAsLocallySaved() {
        XCTAssertNil(copyRetainedMedia(resource: LocalFileMediaResource(fileId: 999), mediaBox: self.mediaBox))
    }

    func testViewOnceExpiryKeepsMediaOnlyAfterBytesAreRetained() throws {
        let resource = LocalFileMediaResource(fileId: 777, size: 3)
        let bytes = Data([4, 5, 6])
        self.mediaBox.storeResourceData(resource.id, data: bytes, synchronous: true)
        let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 777), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/jpeg", size: 3, attributes: [], alternativeRepresentations: [])
        let message = SparseFixtures.message(SparseFixtures.channelId, 777, timestamp: 10).withUpdatedAttributes([
            AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil),
            AfterGramViewOnceMediaBackupAttribute(media: [file])
        ])

        let retained = try XCTUnwrap(retainedViewOnceMessageAfterAutoclear(message, mediaBox: self.mediaBox))
        XCTAssertFalse(retained.attributes.contains(where: { $0 is AfterGramViewOnceMediaBackupAttribute }))
        XCTAssertFalse(retained.attributes.contains(where: { ($0 as? AutoclearTimeoutMessageAttribute)?.timeout == viewOnceTimeout }))
        let retainedFile = try XCTUnwrap(retained.media.first as? TelegramMediaFile)
        let retainedResource = try XCTUnwrap(retainedFile.resource as? LocalFileMediaResource)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: retainedMediaPath(fileId: retainedResource.fileId, mediaBox: self.mediaBox))), bytes)
    }

    func testRetainedViewOncePhotoDropsUncachedRemoteRepresentations() throws {
        let transientResource = LocalFileMediaResource(fileId: 881, size: 3)
        let retainedResource = LocalFileMediaResource(fileId: 882, size: 3)
        let bytes = Data([9, 8, 7])
        self.mediaBox.storeResourceData(retainedResource.id, data: bytes, synchronous: true)
        let image = TelegramMediaImage(
            imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 882),
            representations: [
                TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 320, height: 320), resource: transientResource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false),
                TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 1280, height: 1280), resource: retainedResource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
            ],
            immediateThumbnailData: nil,
            reference: nil,
            partialReference: nil,
            flags: []
        )

        let result = try XCTUnwrap(retainedMessageMedia([image], mediaBox: self.mediaBox).first as? TelegramMediaImage)
        XCTAssertEqual(result.representations.count, 1)
        XCTAssertEqual(result.representations.first?.dimensions, PixelDimensions(width: 1280, height: 1280))
        XCTAssertNil(result.reference)
        let localResource = try XCTUnwrap(result.representations.first?.resource as? LocalFileMediaResource)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: retainedMediaPath(fileId: localResource.fileId, mediaBox: self.mediaBox))), bytes)
    }

    func testViewOnceMediaBackupAttributeRoundTripsMedia() {
        let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 55), partialReference: nil, resource: LocalFileMediaResource(fileId: 56, size: 3), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/jpeg", size: 3, attributes: [], alternativeRepresentations: [])
        let original = AfterGramViewOnceMediaBackupAttribute(media: [file])
        let encoder = PostboxEncoder()
        original.encode(encoder)
        let decoded = AfterGramViewOnceMediaBackupAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        let decodedFile = decoded.media.first as? TelegramMediaFile
        XCTAssertEqual(decodedFile?.resource.id, file.resource.id)
    }

    func testGifVideoAndRoundVideoKeepTheirPlaybackMetadata() throws {
        let cases: [[TelegramMediaFileAttribute]] = [
            [.Animated, .Video(duration: 3, size: PixelDimensions(width: 320, height: 240), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)],
            [.Video(duration: 5, size: PixelDimensions(width: 640, height: 360), flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil)],
            [.Video(duration: 7, size: PixelDimensions(width: 240, height: 240), flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)]
        ]
        for (index, attributes) in cases.enumerated() {
            let resource = LocalFileMediaResource(fileId: Int64(100 + index), size: 3)
            self.mediaBox.storeResourceData(resource.id, data: Data([1, 2, 3]), synchronous: true)
            let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: Int64(index)), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: 3, attributes: attributes, alternativeRepresentations: [])
            let result = try XCTUnwrap(retainedMessageMedia([file], mediaBox: self.mediaBox).first as? TelegramMediaFile)
            let local = try XCTUnwrap(result.resource as? LocalFileMediaResource)
            XCTAssertNotEqual(local.fileId, resource.fileId)
            XCTAssertEqual(result.isAnimated, file.isAnimated)
            XCTAssertEqual(result.isInstantVideo, file.isInstantVideo)
            XCTAssertEqual(result.isVideo, file.isVideo)
            let encoder = PostboxEncoder()
            result.encode(encoder)
            let decoded = TelegramMediaFile(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
            XCTAssertEqual(decoded.resource.id, result.resource.id)
            XCTAssertEqual(decoded.isInstantVideo, file.isInstantVideo)
        }
    }

    func testDeletionMarkerSurvivesEncodingAndDoesNotReplaceMessageText() {
        let marker = RemotelyDeletedMessageAttribute(timestamp: 1234)
        let encoder = PostboxEncoder()
        marker.encode(encoder)
        let decoded = RemotelyDeletedMessageAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertEqual(decoded.timestamp, marker.timestamp)
        let message = SparseFixtures.message(SparseFixtures.channelId, 42, timestamp: 100).withUpdatedText("original text").withUpdatedAttributes([decoded])
        XCTAssertTrue(message.isRemotelyDeleted)
        let stored = retentionStoreMessage(message, attributes: message.attributes, media: message.media, groupingKey: nil)
        XCTAssertEqual(stored.text, "original text")
        XCTAssertNil(stored.groupingKey)
        XCTAssertEqual(stored.timestamp, message.timestamp)
    }

    func testEditedMessageHistoryIsPersistentAndBounded() {
        let original = AfterGramEditedMessageHistoryAttribute(versions: (0 ..< 25).map { "version-\($0)" })
        let encoder = PostboxEncoder()
        original.encode(encoder)
        let decoded = AfterGramEditedMessageHistoryAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertEqual(decoded.versions.count, 20)
        XCTAssertEqual(decoded.versions.first, "version-5")
        XCTAssertEqual(decoded.versions.last, "version-24")
    }

    func testRemoteDeleteRetainsRowAndManualDeleteStillRemovesIt() throws {
        let ready = expectation(description: "open account database")
        var postbox: Postbox?
        let parameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: false, key: ValueBoxEncryptionParameters.Key(data: Data(repeating: 0, count: 32))!, salt: ValueBoxEncryptionParameters.Salt(data: Data(repeating: 0, count: 16))!)
        let opening = openPostbox(basePath: self.directory + "/postbox", seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: parameters, timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: true, isReadOnly: false, useCopy: false, useCaches: true, removeDatabaseOnError: false).start(next: { result in
            if case let .postbox(value) = result {
                postbox = value
                ready.fulfill()
            }
        })
        wait(for: [ready], timeout: 15)
        opening.dispose()
        let box = try XCTUnwrap(postbox)
        let updated = expectation(description: "remote delete transaction")
        let id = SparseFixtures.messageId(SparseFixtures.channelId, 42)
        let missingId = SparseFixtures.messageId(SparseFixtures.channelId, 43)
        let viewOnceId = SparseFixtures.messageId(SparseFixtures.channelId, 44)
        let viewOnceResource = LocalFileMediaResource(fileId: 444, size: 3)
        box.mediaBox.storeResourceData(viewOnceResource.id, data: Data([7, 8, 9]), synchronous: true)
        let viewOnceFile = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 444), partialReference: nil, resource: viewOnceResource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "image/jpeg", size: 3, attributes: [], alternativeRepresentations: [])
        let transaction = box.transaction { transaction -> Void in
            let message = SparseFixtures.message(SparseFixtures.channelId, 42, timestamp: 10).withUpdatedText("kept")
            let _ = transaction.addMessages([retentionStoreMessage(message, attributes: [], media: [], groupingKey: nil)], location: .Random)
            let viewOnceMessage = SparseFixtures.message(SparseFixtures.channelId, 44, timestamp: 10).withUpdatedAttributes([
                AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil),
                AfterGramViewOnceMediaBackupAttribute(media: [viewOnceFile])
            ])
            XCTAssertTrue(afterGramIsViewOnceMessage(viewOnceMessage))
            let expiredMessage = retentionStoreMessage(viewOnceMessage, attributes: viewOnceMessage.attributes, media: [TelegramMediaExpiredContent(data: .image)], groupingKey: nil)
            let _ = transaction.addMessages([expiredMessage], location: .Random)
            let remove = retainRemotelyDeletedMessages(transaction: transaction, mediaBox: box.mediaBox, ids: [id, missingId, viewOnceId])
            XCTAssertEqual(remove, [missingId])
            transaction.deleteMessages(remove, forEachMedia: nil)
            XCTAssertEqual(transaction.getMessage(id)?.text, "kept")
            XCTAssertEqual(transaction.getMessage(id)?.isRemotelyDeleted, true)
            XCTAssertTrue(retainRemotelyDeletedMessages(transaction: transaction, mediaBox: box.mediaBox, ids: [id]).isEmpty)
            if let retainedViewOnce = transaction.getMessage(viewOnceId) {
                XCTAssertTrue(afterGramIsViewOnceMessage(retainedViewOnce))
                XCTAssertTrue(retainedViewOnce.isRemotelyDeleted)
                XCTAssertFalse(retainedViewOnce.attributes.contains(where: { $0 is AfterGramViewOnceMediaBackupAttribute }))
                let restoredFile = retainedViewOnce.media.first as? TelegramMediaFile
                XCTAssertNotNil(restoredFile)
                if let restoredFile = restoredFile {
                    XCTAssertTrue(restoredFile.resource is LocalFileMediaResource)
                    let path = retainedMediaPath(fileId: retainedMediaFileId(viewOnceResource), mediaBox: box.mediaBox)
                    XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), Data([7, 8, 9]))
                }
                if let expiredViewOnce = retainedRemoteDeletedMessageAfterAutoclear(retainedViewOnce, mediaBox: box.mediaBox) {
                    XCTAssertTrue(expiredViewOnce.attributes.contains(where: { $0 is RemotelyDeletedMessageAttribute }))
                    XCTAssertFalse(expiredViewOnce.attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute }))
                } else {
                    XCTFail("Expected remotely deleted view-once media to remain archived after its timer")
                }
            } else {
                XCTFail("Expected remotely deleted view-once message to remain in the archive")
            }
            transaction.deleteMessages([id], forEachMedia: nil)
            XCTAssertNil(transaction.getMessage(id))
        }.start(completed: { updated.fulfill() })
        wait(for: [updated], timeout: 15)
        transaction.dispose()
        // Wait for lazy media storage initialization before removing test files.
        let closed = expectation(description: "database ready to close")
        let closeDisposable = box.mediaBox.storageBox.totalSize().start(next: { _ in closed.fulfill() })
        wait(for: [closed], timeout: 10)
        closeDisposable.dispose()
    }
}
