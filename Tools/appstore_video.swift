//
//  appstore_video.swift
//  Chess tools
//
//  Cuts recorded simulator clips into one App Preview: concatenates the given
//  time ranges, scales them to the size App Store Connect expects and writes
//  H.264 at 30 fps (the simulator records at ~72 fps, which Apple rejects).
//
//      swift Tools/appstore_video.swift <out.mp4> <width> <height> \
//          <clip.mp4>:<in>:<out> ...
//
//  Used by Tools/appstore_media.sh; see AppStore/screenshots.md.
//
import AVFoundation
import CoreMedia
import Foundation

let argv = CommandLine.arguments
guard argv.count > 4, let targetW = Double(argv[2]), let targetH = Double(argv[3]) else {
    FileHandle.standardError.write(Data(
        "usage: appstore_video <out.mp4> <width> <height> <clip.mp4>:<in>:<out>...\n".utf8))
    exit(2)
}

let outURL = URL(fileURLWithPath: argv[1])
let fps: Int32 = 30

struct Segment {
    let url: URL
    let start: Double
    let end: Double
}

let segments: [Segment] = argv[4...].map { spec in
    let parts = spec.split(separator: ":")
    guard parts.count == 3, let start = Double(parts[1]), let end = Double(parts[2]) else {
        FileHandle.standardError.write(Data("bad segment: \(spec)\n".utf8))
        exit(2)
    }
    return Segment(url: URL(fileURLWithPath: String(parts[0])), start: start, end: end)
}

let done = DispatchSemaphore(value: 0)

Task {
    do {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "appstore_video", code: 1, userInfo:
                            [NSLocalizedDescriptionKey: "could not add a video track"])
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero

        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "appstore_video", code: 2, userInfo:
                                [NSLocalizedDescriptionKey:
                                    "no video track in \(segment.url.lastPathComponent)"])
            }
            let natural = try await source.load(.naturalSize)
            let range = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                end: CMTime(seconds: segment.end, preferredTimescale: 600))
            try track.insertTimeRange(range, of: source, at: cursor)

            // Scale to the target width and centre vertically. The iPhone
            // recording is a hair taller than the preview format, so a couple
            // of rows fall outside the frame instead of the picture squashing.
            let scale = targetW / natural.width
            let ty = (targetH - natural.height * scale) / 2
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: 0, y: ty))

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform, at: .zero)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = cursor + range.duration
            print(String(format: "  %-18@ %5.2f→%5.2f  %5.2fs   running %5.2fs",
                         segment.url.lastPathComponent as NSString,
                         segment.start, segment.end, range.duration.seconds, cursor.seconds))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: targetW, height: targetH)
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
        videoComposition.instructions = instructions

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "appstore_video", code: 3, userInfo:
                            [NSLocalizedDescriptionKey: "could not create an export session"])
        }
        export.videoComposition = videoComposition
        try? FileManager.default.removeItem(at: outURL)
        try await export.export(to: outURL, as: .mp4)

        print(String(format: "→ %@  %d×%d  %.2fs  30 fps",
                     outURL.path, Int(targetW), Int(targetH), cursor.seconds))
    } catch {
        FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    done.signal()
}

done.wait()
