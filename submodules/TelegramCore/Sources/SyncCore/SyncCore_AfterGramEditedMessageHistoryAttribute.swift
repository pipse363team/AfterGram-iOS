import Foundation
import Postbox

/// Locally retained text versions captured when a cloud message is edited.
public final class AfterGramEditedMessageHistoryAttribute: MessageAttribute {
    public let versions: [String]

    public init(versions: [String]) {
        self.versions = Array(versions.suffix(20))
    }

    public init(decoder: PostboxDecoder) {
        self.versions = Array(decoder.decodeStringArrayForKey("v").suffix(20))
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeStringArray(self.versions, forKey: "v")
    }
}
