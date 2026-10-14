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

public extension Message {
    var isRemotelyDeleted: Bool {
        return self.attributes.contains(where: { $0 is RemotelyDeletedMessageAttribute })
    }
}
