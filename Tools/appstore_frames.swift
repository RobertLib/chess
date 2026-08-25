//
//  appstore_frames.swift
//  Chess tools
//
//  Pulls still frames out of a finished App Preview so the cut can be checked
//  without watching it.
//
//      swift Tools/appstore_frames.swift <video.mp4> <out-dir> <seconds>...
//
//  Every window in the preview is supposed to hold something *moving* from its
//  first frame to its last (see AppStore/screenshots.md). Nothing enforces that:
//  a window that has drifted past the action does not fail, it just goes still.
//  So the check is to look at the frames either side of each cut — which is what
//  this is for, and why it is a tool rather than a line of ffmpeg: ffmpeg is not
//  installed on a stock macOS, and this needs nothing that is not already here.
//
//  Frames come out named after their timestamp (`at-04.90s.png`), so a contact
//  sheet made of them is in order:
//
//      swift Tools/appstore_frames.swift AppStore/preview/en-US/iphone-6.5.mp4 \
//          /tmp/frames 0.1 4.9 5.1 10.4 10.6 15.4 15.6 22.4 22.6 24.9
//      magick montage /tmp/frames/*.png -tile 5x -geometry 200x+4+4 /tmp/sheet.png
//
//  Seeking is tolerant to one frame, not to the nearest keyframe: a keyframe snap
//  can land on the very frame you were trying to rule out. Zero tolerance was
//  tried first and is worse than it sounds — the finished previews are all-intra
//  and seek to the exact frame either way, but the *raw* simulator recordings are
//  variable frame rate, and on those an exact request past about 21 s silently
//  came back with the last frame it could find instead. A frame's worth of slack
//  costs nothing and makes the raw clips seekable, which is where the cut points
//  are actually chosen.
//
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let argv = CommandLine.arguments
guard argv.count >= 4 else {
    FileHandle.standardError.write(Data(
        "usage: appstore_frames <video.mp4> <out-dir> <seconds>...\n".utf8))
    exit(2)
}

let videoURL = URL(fileURLWithPath: argv[1])
let outDir = URL(fileURLWithPath: argv[2])
let times = argv[3...].compactMap(Double.init)
guard times.count == argv.count - 3 else {
    FileHandle.standardError.write(Data("every argument after the directory has to be a number\n".utf8))
    exit(2)
}

let done = DispatchSemaphore(value: 0)

Task {
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // One frame at 30 fps, either side; see the header.
        let slack = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack

        for seconds in times {
            let requested = CMTime(seconds: seconds, preferredTimescale: 600)
            let (image, actual) = try await generator.image(at: requested)
            let name = String(format: "at-%05.2fs.png", seconds)
            let url = outDir.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw NSError(domain: "appstore_frames", code: 1, userInfo:
                                [NSLocalizedDescriptionKey: "could not write \(name)"])
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "appstore_frames", code: 2, userInfo:
                                [NSLocalizedDescriptionKey: "could not finalise \(name)"])
            }
            print(String(format: "  %@  asked %6.2fs  got %6.2fs  %dx%d",
                         name, seconds, actual.seconds, image.width, image.height))
        }
    } catch {
        FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    done.signal()
}

done.wait()
