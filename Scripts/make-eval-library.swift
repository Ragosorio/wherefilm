#!/usr/bin/env swift
//
// Builds the library that search *quality* is measured against.
//
//   swift Scripts/make-eval-library.swift /tmp/wherefilm-eval
//
// `make-test-library.swift` builds seven files, which is right for proving the
// pipeline runs end to end. It is far too small to say anything about recall:
// with seven assets, almost any ranking finds the answer, and the scale pass
// already showed what a nine-vector fixture does to a measurement.
//
// This one builds a library with **distractors** — thirty real photographs plus
// a wall of abstract wallpapers a query has to beat — and with content whose
// ground truth is knowable: Apple's own scene names, rendered on-screen text
// whose exact string is chosen here, and narration written here and spoken by
// `say`.
//
// Everything comes from the machine. Nothing is downloaded, and no personal
// media is touched.

import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let outputRoot = URL(fileURLWithPath: arguments.count > 1
    ? (arguments[1] as NSString).expandingTildeInPath
    : NSHomeDirectory() + "/Desktop/wherefilm-eval")

let wallpapers = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")

// MARK: - Photographs with knowable content
//
// Apple names these after what is in them, which is exactly the ground truth a
// scene query needs. The destination names are shoot-like on purpose: filename
// and folder search have to have something real to chew on too.

let scenes: [(source: String, name: String)] = [
    ("The Beach.heic",              "PLAYA/BEACH_0001.heic"),
    ("Big Sur Coastline.heic",      "PLAYA/COAST_0002.heic"),
    ("Big Sur Shore Rocks.heic",    "PLAYA/SHORE_ROCKS_0003.heic"),
    ("Big Sur Waters Edge.heic",    "PLAYA/WATERS_EDGE_0004.heic"),
    ("Catalina Coast.heic",         "PLAYA/CATALINA_COAST_0005.heic"),
    ("Catalina Shoreline.heic",     "PLAYA/CATALINA_SHORE_0006.heic"),

    ("Big Sur Mountains.heic",      "MONTANA/MOUNTAIN_0011.heic"),
    ("Peak.heic",                   "MONTANA/PEAK_0012.heic"),
    ("Valley.heic",                 "MONTANA/VALLEY_0013.heic"),
    ("Big Sur Aerial.heic",         "MONTANA/AERIAL_0014.heic"),
    ("Catalina Rock.heic",          "MONTANA/ROCK_0015.heic"),

    ("The Desert.heic",             "DESIERTO/DESERT_0021.heic"),
    ("The Cliffs.heic",             "ACANTILADO/CLIFFS_0031.heic"),
    ("Catalina Silhouette.heic",    "ACANTILADO/SILHOUETTE_0032.heic"),

    ("Catalina Sunset.heic",        "ATARDECER/SUNSET_0041.heic"),
    ("Catalina Evening.heic",       "ATARDECER/EVENING_0042.heic"),
    ("Big Sur Horizon.heic",        "ATARDECER/HORIZON_0043.heic"),
    ("Sonoma.heic",                 "ATARDECER/SONOMA_0044.heic"),

    ("Big Sur Night Grasses.heic",  "NOCHE/NIGHT_GRASS_0051.heic"),
    ("Big Sur Night Succulents.heic", "NOCHE/NIGHT_PLANTS_0052.heic"),
    ("Big Sur Dark.heic",           "NOCHE/DARK_0053.heic"),

    ("The Lake.heic",               "AGUA/LAKE_0061.heic"),
    ("Catalina Clouds.heic",        "CIELO/CLOUDS_0071.heic"),
    ("Tree.heic",                   "BOSQUE/TREE_0081.heic"),
    ("Big Sur Road.heic",           "CARRETERA/ROAD_0091.heic"),
    ("Dome.heic",                   "ARQUITECTURA/DOME_0101.heic"),
]

/// Abstract wallpapers. These exist to be *wrong answers* — a landscape query
/// has to beat a wall of colourful noise, and a nonsense query has to return
/// nothing rather than the least-bad gradient.
let distractors: [(source: String, name: String)] = [
    ("Chroma Blue.heic",       "GRAFICOS/GFX_0201.heic"),
    ("Chroma Red.heic",        "GRAFICOS/GFX_0202.heic"),
    ("Grid Green.heic",        "GRAFICOS/GFX_0203.heic"),
    ("Grid Magenta.heic",      "GRAFICOS/GFX_0204.heic"),
    ("Iridescence.heic",       "GRAFICOS/GFX_0205.heic"),
    ("Light Stream Blue.heic", "GRAFICOS/GFX_0206.heic"),
    ("Motion Purple.heic",     "GRAFICOS/GFX_0207.heic"),
    ("Radial Yellow.heic",     "GRAFICOS/GFX_0208.heic"),
    ("Solar Gradients.heic",   "GRAFICOS/GFX_0209.heic"),
    ("hello Orange.heic",      "GRAFICOS/GFX_0210.heic"),
    ("iMac Blue.heic",         "GRAFICOS/GFX_0211.heic"),
    ("Studio Color.heic",      "GRAFICOS/GFX_0212.heic"),
]

// MARK: - Rendered text
//
// The exact strings are chosen here, so OCR recall is measurable rather than
// guessed. A slate, a badge and a printed quotation — the three things people
// actually search an archive for by their text.

let textCards: [(name: String, lines: [String], background: (Double, Double, Double))] = [
    ("CLAQUETAS/SLATE_A0045.png",
     ["TOMA 7", "ROLLO A0045", "ESC 12  TAKE 3", "DIR. JORGE ALVAREZ"],
     (0.06, 0.06, 0.08)),
    ("DOCUMENTOS/COTIZACION_4582.png",
     ["COTIZACION 4582", "CLIENTE: ACME PRODUCCIONES", "PRESUPUESTO TOTAL Q 18,400.00",
      "VIGENCIA 30 DIAS", "AUTORIZA: MANU GONZALEZ"],
     (0.97, 0.97, 0.95)),
    ("DOCUMENTOS/GAFETE_PRENSA.png",
     ["PRENSA", "JORGE ALVAREZ", "PRODUCTOR", "FESTIVAL 2026"],
     (0.10, 0.20, 0.45)),
]

// MARK: - Narrated videos

let narrations: [(name: String, frames: [String], text: String)] = [
    ("ENTREVISTAS/INTERVIEW_JUAN_03.mov",
     ["Big Sur Coastline.heic", "Big Sur Mountains.heic", "The Beach.heic", "Catalina Sunset.heic"],
     """
     El problema que tuvimos fue el presupuesto. \
     No teníamos dinero para la segunda etapa del proyecto. \
     Por eso la campaña comienza hasta junio del año que viene.
     """),
    ("ENTREVISTAS/INTERVIEW_MARTA_07.mov",
     ["The Desert.heic", "The Cliffs.heic", "Valley.heic", "The Lake.heic"],
     """
     Grabamos en el desierto durante tres días con un equipo muy pequeño. \
     La luz de la tarde en el acantilado fue lo más difícil de conseguir. \
     Al final el cliente aprobó la campaña sin cambios.
     """),
]

// MARK: - Helpers

func loadImage(_ name: String, maxPixel: Int = 1280) -> CGImage? {
    let url = wallpapers.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ] as CFDictionary)
}

func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_32ARGB,
                              [kCVPixelBufferCGImageCompatibilityKey: true,
                               kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                              &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

/// Renders text large enough that Vision can genuinely read it at the 1024 px
/// the indexer decodes to — which is the whole point of the resolution work in
/// `KeyframeSampler`.
func renderTextCard(lines: [String], background: (Double, Double, Double)) -> CGImage? {
    let width = 1600, height = 900
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    let dark = (background.0 + background.1 + background.2) / 3 < 0.5
    context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
    let colour = dark
        ? CGColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1)
        : CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)

    for (index, line) in lines.enumerated() {
        // CoreText attribute names, not AppKit's: this script deliberately
        // links no UI framework.
        let attributed = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ])
        let displayLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 120, y: Double(height) - 200 - Double(index) * 130)
        CTLineDraw(displayLine, context)
    }
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func run(_ launchPath: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
}

func copyWallpaper(_ entry: (source: String, name: String)) {
    let source = wallpapers.appendingPathComponent(entry.source)
    let destination = outputRoot.appendingPathComponent(entry.name)
    guard FileManager.default.fileExists(atPath: source.path) else {
        print("· skipping \(entry.source) — not on this system")
        return
    }
    try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: destination)
    try? FileManager.default.copyItem(at: source, to: destination)
    print("· photo  \(entry.name)")
}

// MARK: - Build

try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

for entry in scenes { copyWallpaper(entry) }
for entry in distractors { copyWallpaper(entry) }

for card in textCards {
    guard let image = renderTextCard(lines: card.lines, background: card.background) else { continue }
    try write(image, to: outputRoot.appendingPathComponent(card.name))
    print("· text   \(card.name)  — \"\(card.lines[0])\"")
}

for narration in narrations {
    let stem = (narration.name as NSString).lastPathComponent
    let audioURL = outputRoot.appendingPathComponent("\(stem).aiff")
    try? FileManager.default.removeItem(at: audioURL)
    print("· speech \(stem)")
    try run("/usr/bin/say", ["-v", "Paulina", "-o", audioURL.path, narration.text])

    let audioAsset = AVURLAsset(url: audioURL)
    let audioDuration = try await audioAsset.load(.duration)
    let totalSeconds = max(CMTimeGetSeconds(audioDuration), 12)

    let width = 1280, height = 720
    let fps: Int32 = 12
    let silentURL = outputRoot.appendingPathComponent("\(stem).silent.mov")
    try? FileManager.default.removeItem(at: silentURL)

    let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mov)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    videoInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
    writer.add(videoInput)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    let secondsPerScene = totalSeconds / Double(narration.frames.count)
    var frameIndex: Int64 = 0
    for index in 0..<Int(totalSeconds * Double(fps)) {
        let seconds = Double(index) / Double(fps)
        let scene = min(narration.frames.count - 1, Int(seconds / secondsPerScene))
        guard let image = loadImage(narration.frames[scene]),
              let buffer = pixelBuffer(from: image, width: width, height: height) else { continue }
        while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps))
        frameIndex += 1
    }
    videoInput.markAsFinished()
    await writer.finishWriting()

    let finalURL = outputRoot.appendingPathComponent(narration.name)
    try? FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: finalURL)

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
    try await export.export(to: finalURL, as: .mov)
    try? FileManager.default.removeItem(at: silentURL)
    try? FileManager.default.removeItem(at: audioURL)
    print("  \(narration.name) — \(String(format: "%.1f", totalSeconds))s")
}

let total = scenes.count + distractors.count + textCards.count + narrations.count
print("""

Evaluation library ready: \(outputRoot.path)
  \(scenes.count) photographs with knowable scene content
  \(distractors.count) abstract distractors
  \(textCards.count) rendered text cards with exact known strings
  \(narrations.count) narrated Spanish videos
  \(total) assets total

Index it into an isolated home so your real index is untouched:

  WHEREFILM_HOME=/tmp/wherefilm-eval-home swift run wherefilm scan \(outputRoot.path) --index
  WHEREFILM_HOME=/tmp/wherefilm-eval-home swift run wherefilm index --full-speed
  WHEREFILM_HOME=/tmp/wherefilm-eval-home swift run wherefilm eval --set Benchmarks/quality-v1.json
""")
