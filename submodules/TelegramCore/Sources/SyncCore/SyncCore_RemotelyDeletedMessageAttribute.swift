import Foundation
import Postbox

/// A persistent local tombstone. The message keeps its ID, text and media.
public final class RemotelyDeletedMessageAttribute: MessageAttribute {
    public let timestamp: Int32

    public init(timestamp: Int32) {
        self.timestamp = timestamp
    }

    public init(decoder: PostboxDecoder) {
        self.timestamp = decoder.decodeInt32ForKey("t", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.timestamp, forKey: "t")
    }
}

/// Keeps the original media descriptors for a view-once message after Telegram
/// replaces its visible media with an expired-content placeholder.
public final class AfterGramViewOnceMediaBackupAttribute: MessageAttribute {
    public let media: [Media]

    public init(media: [Media]) {
        self.media = media
    }

    public init(decoder: PostboxDecoder) {
        self.media = (try? decoder.decodeObjectArrayWithCustomDecoderForKey("m", decoder: { decoder in
            return decoder.decodeObjectForKey("v") as! Media
        })) ?? []
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeObjectArrayWithEncoder(self.media, forKey: "m", encoder: { media, encoder in
            encoder.encodeObject(media, forKey: "v")
        })
    }
}

public extension Message {
    var isRemotelyDeleted: Bool {
        return self.attributes.contains(where: { $0 is RemotelyDeletedMessageAttribute })
    }
}
