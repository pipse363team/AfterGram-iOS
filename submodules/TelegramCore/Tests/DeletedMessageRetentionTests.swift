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

    func testRetainedMediaFileOperationsRunSeriallyOffMainAndCompleteOnMain() {
        let completed = expectation(description: "file operation callbacks")
        completed.expectedFulfillmentCount = 3
        var operationResults: [(Int, Bool)] = []
        var callbackOrder: [Int] = []
        var disposables: [Disposable] = []

        for index in 0 ..< 3 {
            disposables.append(performDeletedMessageRetentionFileOperation({
                (index, Thread.isMainThread)
            }, completion: { result in
                XCTAssertTrue(Thread.isMainThread)
                operationResults.append(result)
                callbackOrder.append(result.0)
                completed.fulfill()
            }))
        }

        wait(for: [completed], timeout: 5)
        XCTAssertEqual(callbackOrder, [0, 1, 2])
        XCTAssertEqual(operationResults.map(\.1), [false, false, false])
        disposables.forEach { $0.dispose() }
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

    func testViewOncePhotoKeepsAvailableBytesWhenRetentionIsEnabled() throws {
        let resource = LocalFileMediaResource(fileId: 654, size: 4)
        self.mediaBox.storeResourceData(resource.id, data: Data([4, 3, 2, 1]), synchronous: true)
        let image = TelegramMediaImage(
            imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 654),
            representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 10, height: 10), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)],
            immediateThumbnailData: nil,
            reference: nil,
            partialReference: nil,
            flags: []
        )

        let result = try XCTUnwrap(retainedOrExpiredSecretMedia([image], enabled: true, mediaBox: self.mediaBox).first as? TelegramMediaImage)
        XCTAssertTrue(hasRetainedMediaBytes(result, mediaBox: self.mediaBox))
        XCTAssertTrue(result.representations[0].resource is LocalFileMediaResource)
    }

    func testViewOnceMediaWithoutSavedBytesExpiresAndDisabledRetentionDoesNotCopy() throws {
        let resource = LocalFileMediaResource(fileId: 655, size: 4)
        self.mediaBox.storeResourceData(resource.id, data: Data([4, 3, 2, 1]), synchronous: true)
        let file = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 655), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: 4, attributes: [.Video(duration: 1, size: PixelDimensions(width: 10, height: 10), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)], alternativeRepresentations: [])

        let disabled = try XCTUnwrap(retainedOrExpiredSecretMedia([file], enabled: false, mediaBox: self.mediaBox).first as? TelegramMediaExpiredContent)
        XCTAssertEqual(disabled.data, .file)

        let missing = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 656), partialReference: nil, resource: LocalFileMediaResource(fileId: 656), previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "video/mp4", size: 4, attributes: [.Video(duration: 1, size: PixelDimensions(width: 10, height: 10), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)], alternativeRepresentations: [])
        let expiredMissing = try XCTUnwrap(retainedOrExpiredSecretMedia([missing], enabled: true, mediaBox: self.mediaBox).first as? TelegramMediaExpiredContent)
        XCTAssertEqual(expiredMissing.data, .file)
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

    func testEditedMessageHistoryCapturesPreviousTextAndIgnoresNoOpEdits() throws {
        let previous = SparseFixtures.message(SparseFixtures.channelId, 77, timestamp: 100).withUpdatedText("before edit")
        let attributes = editedMessageHistoryAttributes(previousMessage: previous, updatedText: "after edit", updatedAttributes: [], updatedMedia: [], mediaBox: self.mediaBox)
        let history = try XCTUnwrap(attributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute)
        XCTAssertEqual(history.revisions.count, 1)
        XCTAssertEqual(history.revisions[0].text, "before edit")

        let updated = previous.withUpdatedText("after edit").withUpdatedAttributes(attributes)
        let repeatedAttributes = editedMessageHistoryAttributes(previousMessage: updated, updatedText: "after edit", updatedAttributes: updated.attributes, updatedMedia: updated.media, mediaBox: self.mediaBox)
        let repeatedHistory = try XCTUnwrap(repeatedAttributes.first(where: { $0 is EditedMessageHistoryAttribute }) as? EditedMessageHistoryAttribute)
        XCTAssertEqual(repeatedHistory.revisions.count, 1)
        XCTAssertEqual(repeatedHistory.revisions[0].text, "before edit")

        let encoder = PostboxEncoder()
        history.encode(encoder)
        let decoded = EditedMessageHistoryAttribute(decoder: PostboxDecoder(buffer: MemoryBuffer(data: encoder.makeData())))
        XCTAssertEqual(decoded.revisions.map(\.text), ["before edit"])
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
        let transaction = box.transaction { transaction -> Void in
            let message = SparseFixtures.message(SparseFixtures.channelId, 42, timestamp: 10).withUpdatedText("kept")
            let _ = transaction.addMessages([retentionStoreMessage(message, attributes: [], media: [], groupingKey: nil)], location: .Random)
            let remove = retainRemotelyDeletedMessages(transaction: transaction, mediaBox: box.mediaBox, ids: [id, missingId])
            XCTAssertEqual(remove, [missingId])
            transaction.deleteMessages(remove, forEachMedia: nil)
            XCTAssertEqual(transaction.getMessage(id)?.text, "kept")
            XCTAssertEqual(transaction.getMessage(id)?.isRemotelyDeleted, true)
            XCTAssertTrue(retainRemotelyDeletedMessages(transaction: transaction, mediaBox: box.mediaBox, ids: [id]).isEmpty)
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
