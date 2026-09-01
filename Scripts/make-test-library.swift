#!/usr/bin/env swift
//
// Builds a small but *real* test library so the whole pipeline can be exercised
// end to end: photos with genuine scene content, and a video with genuine
// Spanish speech.
//
//   swift Scripts/make-test-library.swift ~/Desktop/wherefilm-test
//
// Photos come from macOS's own wallpapers (actual coastlines, mountains,
// deserts) and the narration from `say`, so nothing here is a mock — CLIP and
// SpeechTranscriber get something they can genuinely succeed or fail at.

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let outputRoot = URL(fileURLWithPath: arguments.count > 1
    ? (arguments[1] as NSString).expandingTildeInPath
    : NSHomeDirectory() + "/Desktop/wherefilm-test")

let wallpapers = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")

/// Source picture → the filename it gets in the test library. The names are
/// deliberately shoot-like, so filename search has something to chew on too.
let photos: [(source: String, name: String)] = [
    ("The Beach.heic", "PHOTOS/BEACH_0001.heic"),
    ("Big Sur Mountains.heic", "PHOTOS/MOUNTAIN_0002.heic"),
    ("The Desert.heic", "PHOTOS/DESERT_0003.heic"),
    ("The Cliffs.heic", "PHOTOS/CLIFFS_0004.heic"),
    ("Catalina Sunset.heic", "PHOTOS/SUNSET_0005.heic"),
    ("Big Sur Road.heic", "PHOTOS/ROAD_0006.heic"),
]

/// Frames of the fake interview, in order, one every few seconds.
let videoFrames = [
    "Big Sur Coastline.heic",
    "Big Sur Mountains.heic",
    "The Beach.heic",
    "Catalina Sunset.heic",
]

let narration = """
El problema que tuvimos fue el presupuesto. \
No teníamos dinero para la segunda etapa del proyecto. \
Por eso la campaña comienza hasta junio del año que viene.
"""

// MARK: - Helpers

func loadImage(_ name: String) -> CGImage? {
    let url = wallpapers.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1280,
    ] as CFDictionary)
}

func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_32ARGB, attributes as CFDictionary,
                              &buffer) == kCVReturnSuccess,
          let buffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

func run(_ launchPath: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
}

// MARK: - Photos

try FileManager.default.createDirectory(
    at: outputRoot.appendingPathComponent("PHOTOS"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(
    at: outputRoot.appendingPathComponent("ENTREVISTAS"), withIntermediateDirectories: true)

for photo in photos {
    let source = wallpapers.appendingPathComponent(photo.source)
    let destination = outputRoot.appendingPathComponent(photo.name)
    guard FileManager.default.fileExists(atPath: source.path) else {
        print("· skipping \(photo.source) — not present on this system")
        continue
    }
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: source, to: destination)
    print("· photo  \(photo.name)")
}

// MARK: - Narration

let audioURL = outputRoot.appendingPathComponent("narration.aiff")
try? FileManager.default.removeItem(at: audioURL)
print("· generating Spanish narration with `say`")
try run("/usr/bin/say", ["-v", "Paulina", "-o", audioURL.path, narration])

let audioAsset = AVURLAsset(url: audioURL)
let audioDuration = try await audioAsset.load(.duration)
let totalSeconds = max(CMTimeGetSeconds(audioDuration), 12)
print("  narration is \(String(format: "%.1f", totalSeconds))s")

// MARK: - Silent video

let width = 1280, height = 720
let fps: Int32 = 12
let silentURL = outputRoot.appendingPathComponent("silent.mov")
try? FileManager.default.removeItem(at: silentURL)

let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mov)
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
])
videoInput.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
writer.add(videoInput)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let secondsPerScene = totalSeconds / Double(videoFrames.count)
var frameIndex: Int64 = 0
let totalFrames = Int(totalSeconds * Double(fps))

print("· rendering \(totalFrames) frames across \(videoFrames.count) scenes")
for index in 0..<totalFrames {
    let seconds = Double(index) / Double(fps)
    let scene = min(videoFrames.count - 1, Int(seconds / secondsPerScene))
    guard let image = loadImage(videoFrames[scene]),
          let buffer = pixelBuffer(from: image, width: width, height: height) else { continue }

    while !videoInput.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(5))
    }
    adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
    frameIndex += 1
}
videoInput.markAsFinished()
await writer.finishWriting()

// MARK: - Mux

let interviewURL = outputRoot
    .appendingPathComponent("ENTREVISTAS")
    .appendingPathComponent("INTERVIEW_JUAN_03.mov")
try? FileManager.default.removeItem(at: interviewURL)

let composition = AVMutableComposition()
let silentAsset = AVURLAsset(url: silentURL)
let videoDuration = try await silentAsset.load(.duration)

if let sourceVideo = try await silentAsset.loadTracks(withMediaType: .video).first,
   let track = composition.addMutableTrack(withMediaType: .video,
                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
    try track.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                             of: sourceVideo, at: .zero)
}
if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
   let track = composition.addMutableTrack(withMediaType: .audio,
                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
    try track.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration),
                             of: sourceAudio, at: .zero)
}

guard let export = AVAssetExportSession(asset: composition,
                                        presetName: AVAssetExportPresetHighestQuality) else {
    fatalError("Could not create the export session.")
}
try await export.export(to: interviewURL, as: .mov)

try? FileManager.default.removeItem(at: silentURL)
try? FileManager.default.removeItem(at: audioURL)

print("""

    Test library ready: \(outputRoot.path)

      swift run wherefilm scan \(outputRoot.path) --index
      swift run wherefilm search "playa al atardecer" --explain
      swift run wherefilm search "el que habló del presupuesto" --explain
    """)
