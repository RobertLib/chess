//
//  appstore_conform.swift
//  Chess tools
//
//  Rewrites a finished App Preview into exactly the shape App Store Connect
//  accepts. The upload check is strict and its error messages are not: it
//  reports "unsupported or corrupted audio" for problems that have nothing to
//  do with sound, so everything here is pinned rather than left to a preset.
//
//      swift Tools/appstore_conform.swift <preview.mp4> <width> <height> \
//          [<music.wav> [gain]]
//
//  Chess ships with no audio at all — the sounds are synthesised at launch — so
//  the bed comes from Tools/gen_preview_music.py rather than from the bundle.
//
//  Apple's specification (App Store Connect Help → App preview specifications):
//
//      resolution   iPhone 886 × 1920, iPad 13" 1200 × 1600 (portrait)
//      video        H.264 High Profile Level 4.0, progressive, 30 fps
//      bit rate     10–12 Mbps VBR
//      audio        stereo AAC, 256 kbps, 44.1 or 48 kHz — required
//      duration     15–30 s, at most 500 MB
//
//  Two things about that list are worth knowing, because both cost an upload to
//  find out. The native device resolution is *not* accepted — the one 886 × 1920
//  file is what Apple lists for every iPhone slot from 6.9" down to 6.1", and
//  the device's own 1242 × 2688 is not on the list — and Level 4.0 is a real
//  ceiling, so a preview at the device's own size comes out as Level 5.0 and is
//  refused. Silence does not satisfy the audio requirement either: AAC
//  compresses digital silence to about 2 kbps, two orders of magnitude under
//  the 256 kbps asked for, and a preview with no usable audio is treated as an
//  unsupported audio configuration. Hence the music bed — pass a file and it is
//  looped under the whole cut.
//
//  The picture is re-encoded, which it has to be to hit the profile and the
//  size. What comes out still carries the edit list AVFoundation writes for the
//  recording's leading trim — the track presents from time zero but starts
//  67 ms into its own media. That resisted every attempt to remove it (a
//  session opened on the first sample, retimed samples, a plain mux) and is
//  left alone: it is ordinary trim bookkeeping, every trimmed clip out of
//  iMovie or QuickTime has one, and Apple's specification does not mention it.
//
//  Used by Tools/appstore_media.sh; see AppStore/screenshots.md.
//
import AVFoundation
import CoreMedia
import Foundation

let argv = CommandLine.arguments
guard argv.count >= 4, argv.count <= 6,
      let targetW = Double(argv[2]), let targetH = Double(argv[3]) else {
    FileHandle.standardError.write(Data(
        "usage: appstore_conform <preview.mp4> <width> <height> [<music.m4a> [gain]]\n".utf8))
    exit(2)
}

let videoURL = URL(fileURLWithPath: argv[1])
let targetSize = CGSize(width: targetW, height: targetH)
let musicURL = argv.count > 4 ? URL(fileURLWithPath: argv[4]) : nil
let gain = argv.count > 5 ? Float(argv[5]) ?? 0.7 : 0.7

let fps: Int32 = 30
// Apple's band is 10–12 Mbps, and `AVVideoAverageBitRateKey` is a *ceiling*, not
// a target — the encoder spends what the picture needs and no more. A chess
// board is sixty-four flat squares with one piece sliding across them, so it
// needs almost nothing: asking for 14 Mbps with an ordinary one-second GOP
// measured well under the floor.
//
// What makes the number behave like a floor is `AVVideoMaxKeyFrameIntervalKey: 1`
// below — with every frame an I-frame there is no temporal prediction to save
// bits with, so each frame takes its equal share of the average and the result
// lands on the number asked for. Measured: 11.5 requested → 11.5 delivered,
// 35 MB for 25 s, well inside Level 4.0's ceiling and nowhere near Connect's
// 500 MB. Do not "optimise" the GOP back without re-measuring; a GOP of 2 was
// tried and came out at 26.5 Mbps, which is out of spec on its own.
let videoBitRate = 11_500_000
let sampleRate = 48_000.0
let audioChannels = 2
let audioBitRate = 256_000
let fadeIn = 0.5
let fadeOut = 1.5

func problem(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "appstore_conform", code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}

func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// Drains `output` into `input` and closes the writer. Both passes below are a
/// single track, so one reader and one writer input is all this has to juggle.
func transfer(from output: AVAssetReaderOutput, to input: AVAssetWriterInput,
              reader: AVAssetReader, writer: AVAssetWriter) async throws {
    guard reader.startReading() else {
        throw reader.error ?? problem(1, "could not start reading")
    }
    guard writer.startWriting() else {
        throw writer.error ?? problem(2, "could not start writing")
    }

    // The first frame of the recording does not sit at time zero, so the session
    // opens on it rather than on zero — the writer then measures the track from
    // the frame it was actually given. (It still notes the leading trim in an
    // edit list; see the header. This is the idiomatic way round regardless.)
    guard let first = output.copyNextSampleBuffer() else {
        throw reader.error ?? problem(3, "nothing to encode")
    }
    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(first))

    let queue = DispatchQueue(label: "cz.rob.chess.appstore-conform")
    var pending: CMSampleBuffer? = first
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                let next: CMSampleBuffer?
                if let pending {
                    next = pending
                } else {
                    next = output.copyNextSampleBuffer()
                }
                pending = nil
                guard let sample = next else {
                    input.markAsFinished()
                    if reader.status == .failed {
                        continuation.resume(throwing: reader.error ?? problem(4, "read failed"))
                    } else {
                        continuation.resume()
                    }
                    return
                }
                if !input.append(sample) {
                    input.markAsFinished()
                    continuation.resume(throwing: writer.error ?? problem(5, "encode failed"))
                    return
                }
            }
        }
    }
    await writer.finishWriting()
    if writer.status == .failed {
        throw writer.error ?? problem(6, "could not finish \(writer.outputURL.lastPathComponent)")
    }
}

/// Re-encodes the picture to the target size and to H.264 High 4.0. Scaling to
/// width and centring is what appstore_video.swift already does for the cut —
/// the preview's aspect ratio is within a rounding error of the target, so this
/// only ever drops a fraction of a row.
func encodeVideo(asset: AVAsset, track: AVAssetTrack, to outURL: URL) async throws {
    let duration = try await asset.load(.duration)
    let natural = try await track.load(.naturalSize)
    let scale = targetSize.width / natural.width
    let ty = (targetSize.height - natural.height * scale) / 2

    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(CGAffineTransform(scaleX: scale, y: scale)
        .concatenating(CGAffineTransform(translationX: 0, y: ty)), at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
    instruction.layerInstructions = [layer]

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = targetSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
    videoComposition.instructions = [instruction]

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    output.videoComposition = videoComposition
    reader.add(output)

    try? FileManager.default.removeItem(at: outURL)
    let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(targetSize.width),
        AVVideoHeightKey: Int(targetSize.height),
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: videoBitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264High40,
            // Every frame a keyframe. Two reasons, and the second is the load
            // bearing one: Connect seeks the file to build the poster frame and a
            // long GOP has bitten this pipeline before — and all-intra is what
            // turns the average bit rate above from a ceiling the encoder ignores
            // into the figure it actually delivers. See the note there.
            AVVideoMaxKeyFrameIntervalKey: 1,
            AVVideoExpectedSourceFrameRateKey: Int(fps),
        ],
        // Tag the colour explicitly; the simulator's own recording is Rec. 709
        // and an untagged file is left to the reader to guess at.
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)

    try await transfer(from: output, to: input, reader: reader, writer: writer)
}

/// Writes `seconds` of silent PCM — the fallback when no music is given. The
/// encoder needs samples to chew on and there is no way to ask for an empty
/// track. Note the warning above: a silent track is *not* enough for Connect.
func writeSilence(seconds: Double, to url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: audioChannels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ])
    let chunk = AVAudioFrameCount(sampleRate)   // a second at a time
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: chunk) else {
        throw problem(6, "could not allocate a silence buffer")
    }
    if let data = buffer.floatChannelData {
        for channel in 0..<Int(buffer.format.channelCount) {
            memset(data[channel], 0, Int(chunk) * MemoryLayout<Float>.size)
        }
    }
    var remaining = AVAudioFrameCount((seconds * sampleRate).rounded(.up))
    while remaining > 0 {
        buffer.frameLength = min(chunk, remaining)
        try file.write(from: buffer)
        remaining -= buffer.frameLength
    }
}

/// Loops the music (or silence) up to `duration` and encodes it to AAC at the
/// rate Apple asks for. The reader handles the mixing and the rate conversion.
func encodeAudio(duration: CMTime, to outURL: URL) async throws {
    let sourceURL = musicURL ?? outURL.deletingLastPathComponent()
        .appendingPathComponent("silence.caf")
    if musicURL == nil {
        try writeSilence(seconds: duration.seconds, to: sourceURL)
    }

    let asset = AVURLAsset(url: sourceURL)
    guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
        throw problem(7, "no audio track in \(sourceURL.lastPathComponent)")
    }
    let sourceDuration = try await asset.load(.duration)
    guard sourceDuration > .zero else {
        throw problem(8, "\(sourceURL.lastPathComponent) is empty")
    }

    let composition = AVMutableComposition()
    guard let track = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw problem(9, "could not add an audio track")
    }
    var cursor = CMTime.zero
    while cursor < duration {
        let take = min(sourceDuration, duration - cursor)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: take),
                                  of: sourceTrack, at: cursor)
        cursor = cursor + take
    }

    let parameters = AVMutableAudioMixInputParameters(track: track)
    parameters.setVolume(gain, at: .zero)
    if musicURL != nil {
        // Music that starts and stops at full volume reads as a glitch. The
        // fades are short enough not to eat into the gameplay.
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                                 timeRange: CMTimeRange(start: .zero,
                                                        duration: time(fadeIn)))
        parameters.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: duration - time(fadeOut),
                                                        duration: time(fadeOut)))
    }
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]

    let reader = try AVAssetReader(asset: composition)
    let output = AVAssetReaderAudioMixOutput(
        audioTracks: composition.tracks(withMediaType: .audio),
        audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: audioChannels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
    output.audioMix = mix
    reader.add(output)

    try? FileManager.default.removeItem(at: outURL)
    let writer = try AVAssetWriter(outputURL: outURL, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: audioChannels,
        AVEncoderBitRateKey: audioBitRate,
    ])
    input.expectsMediaDataInRealTime = false
    writer.add(input)

    try await transfer(from: output, to: input, reader: reader, writer: writer)
    if musicURL == nil {
        try? FileManager.default.removeItem(at: sourceURL)
    }
}

let done = DispatchSemaphore(value: 0)

Task {
    do {
        let original = AVURLAsset(url: videoURL)
        guard let sourceVideo = try await original.loadTracks(withMediaType: .video).first else {
            throw problem(10, "no video track in \(videoURL.lastPathComponent)")
        }
        let duration = try await original.load(.duration)
        guard duration.seconds >= 15, duration.seconds <= 30 else {
            throw problem(11, String(format: "%.1fs is outside Connect's 15–30 s",
                                     duration.seconds))
        }

        // Work beside the file: replaceItemAt wants both on the same volume.
        let work = videoURL.deletingLastPathComponent()
            .appendingPathComponent(".appstore_conform-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let videoOnly = work.appendingPathComponent("video.mp4")
        let audioOnly = work.appendingPathComponent("audio.m4a")
        try await encodeVideo(asset: original, track: sourceVideo, to: videoOnly)
        try await encodeAudio(duration: duration, to: audioOnly)

        // Put the two together. Passthrough copies both tracks as encoded, so
        // nothing above is undone here, and inserting from time zero is what
        // leaves the result without the offset edit list a composed export
        // would otherwise carry.
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoOnly)
        let audioAsset = AVURLAsset(url: audioOnly)
        guard let encodedVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw problem(12, "could not add the encoded picture")
        }
        let videoDuration = try await videoAsset.load(.duration)
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                  of: encodedVideo, at: .zero)

        guard let encodedAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let audio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw problem(13, "could not add the encoded audio")
        }
        // AAC comes out in whole packets, a fraction of a second longer than
        // asked for. Trim it so the sound does not outlast the picture.
        let audioDuration = min(try await audioAsset.load(.duration), videoDuration)
        try audio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration),
                                  of: encodedAudio, at: .zero)

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw problem(14, "could not create an export session")
        }
        // Moves the index to the front, so Connect can read the file as it
        // arrives instead of having to take all of it first.
        export.shouldOptimizeForNetworkUse = true
        let outURL = work.appendingPathComponent(videoURL.lastPathComponent)
        try await export.export(to: outURL, as: .mp4)
        _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: outURL)

        // Report what the file ended up holding, not what was asked for above.
        let result = AVURLAsset(url: videoURL)
        let finalVideo = try await result.loadTracks(withMediaType: .video).first
        let finalAudio = try await result.loadTracks(withMediaType: .audio).first
        let videoRate = try await finalVideo?.load(.estimatedDataRate) ?? 0
        let audioRate = try await finalAudio?.load(.estimatedDataRate) ?? 0
        let size = (try FileManager.default.attributesOfItem(atPath: videoURL.path)[.size]
                    as? Int) ?? 0
        print(String(format: "→ %@\n  %d×%d  %.2fs  H.264 High 4.0 %.1f Mbit/s  " +
                     "AAC %.0f kHz stereo %.0f kbit/s  %.1f MB  (%@)",
                     videoURL.path, Int(targetW), Int(targetH), duration.seconds,
                     videoRate / 1_000_000, sampleRate / 1000, audioRate / 1000,
                     Double(size) / 1_048_576,
                     musicURL.map { "music: \($0.lastPathComponent)" } ?? "silent" as String))
    } catch {
        FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    done.signal()
}

done.wait()
