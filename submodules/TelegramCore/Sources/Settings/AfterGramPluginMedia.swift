import Foundation
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import Postbox

func afterGramPluginMedia(account: Account, value: [String: Any]) async -> AnyMediaReference? {
    guard let path = value["path"] as? String, let kind = value["kind"] as? String,
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 512 * 1024 * 1024 else { return nil }
    let id = Int64.random(in: Int64.min ... Int64.max)
    let resource = LocalFileMediaResource(fileId: id, size: size.int64Value)
    if kind == "photo" {
        guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage, cgImage.width <= Int(Int32.max), cgImage.height <= Int(Int32.max),
              let data = image.jpegData(compressionQuality: value["high_quality"] as? Bool == true ? 1.0 : 0.9) else { return nil }
        account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
        let representation = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: Int32(cgImage.width), height: Int32(cgImage.height)), resource: LocalFileMediaResource(fileId: id, size: Int64(data.count)), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
        return .standalone(media: TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: id), representations: [representation], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: []))
    }
    var fileAttributes: [TelegramMediaFileAttribute] = [.FileName(fileName: URL(fileURLWithPath: path).lastPathComponent)]
    if kind == "video" || kind == "audio" {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        if kind == "video" {
            guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
                  let naturalSize = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) else { return nil }
            let dimensions = naturalSize.applying(transform)
            guard abs(dimensions.width) <= CGFloat(Int32.max), abs(dimensions.height) <= CGFloat(Int32.max) else { return nil }
            fileAttributes.append(.Video(duration: seconds, size: PixelDimensions(width: Int32(abs(dimensions.width)), height: Int32(abs(dimensions.height))), flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil))
        } else {
            guard seconds <= Double(Int32.max), let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return nil }
            fileAttributes.append(.Audio(isVoice: false, duration: Int(seconds), title: nil, performer: nil, waveform: nil))
        }
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
    account.postbox.mediaBox.storeResourceData(resource.id, data: data, synchronous: true)
    let mime = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    return .standalone(media: TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: id), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: mime, size: size.int64Value, attributes: fileAttributes, alternativeRepresentations: []))
}
