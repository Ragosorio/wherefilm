import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import WhereFilmCore
@testable import WhereFilmIndex
@testable import WhereFilmSearch

@Suite("Frame analysis")
struct FrameAnalysisTests {
    /// A real bitmap with real text, because the whole point of these paths is
    /// what Vision does with pixels.
    static func card(_ lines: [String], width: Int = 1200, height: Int = 600) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let colour = CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
            ])
            context.textPosition = CGPoint(x: 60, y: Double(height) - 120 - Double(index) * 100)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()
    }

    @Test("Moving a frame between processes costs nothing in text recall")
    func jpegHandoffPreservesText() throws {
        // The helper receives a JPEG, not the original bitmap, and OCR is the
        // reason this project decodes keyframes at 1024 px in the first place.
        // If the handoff cost recall, the whole design would be paying for
        // throughput with the thing it was protecting.
        let image = try #require(Self.card(["COTIZACION 4582", "PRESUPUESTO TOTAL"]))
        let data = try #require(VisionHelperPool.encode(image))
        #expect(data.count < 400_000, "a 1200 px frame should stay well under half a megabyte")

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
    }

    @Test("With no helper available the in-process path still reads the frame")
    func inProcessFallbackReadsText() async throws {
        // The fallback is not decoration: a bundle built before helpers existed,
        // a test binary, or a copy someone moved out of its folder all land here.
        let image = try #require(Self.card(["TOMA 7", "ROLLO A0045"]))
        var options = FrameAnalyzer.Options()
        options.classifiesScene = false
        options.recognizesText = true
        let analyzer = FrameAnalyzer(options: options)
        let results = await analyzer.analyzeInProcessForTesting([image])
        let text = try #require(results.first?.text?.text)
        #expect(text.contains("TOMA 7"))
        #expect(text.contains("A0045"))
    }

    @Test("Vision's classifier answers with a taxonomy, not with nothing")
    func classifierProducesLabels() async throws {
        let image = try #require(Self.card(["ACTA DE LA REUNION"]))
        let labels = await FrameAnalyzer.classifyInProcess(image, floor: 0, limit: 5)
        #expect(!labels.isEmpty, "a page of text should classify as something")
        // The taxonomy is Vision's, so this asserts the shape of the answer, not
        // its content: identifiers are underscored words, not free text.
        #expect(labels.allSatisfy { !$0.identifier.contains(" ") })
    }
}

@Suite("Scene label ranking")
struct SceneLabelTests {
    @Test("A label the whole library shares is worth nothing")
    func rarityFallsToZeroForUbiquitousLabels() {
        // Measured, not assumed: `sky` and `outdoor` land on most of a landscape
        // library, and admitting them promoted thirty files equally for "nubes
        // en el cielo" — it cost seven cases their rank.
        let everywhere = SearchEngine.rarity(of: "sky", in: (["sky": 43], 43))
        let common = SearchEngine.rarity(of: "outdoor", in: (["outdoor": 30], 43))
        let rare = SearchEngine.rarity(of: "duck", in: (["duck": 1], 43))
        #expect(everywhere == 0)
        #expect(rare > common)
        #expect(rare <= 1)
    }

    @Test("Label lookups drop the words the planner itself added")
    func labelPatternIgnoresTemplates() throws {
        // The visual phrases arrive templated — "a photo of a yellow duck" —
        // and searching a label index for "photo" costs a scan and finds noise.
        let pattern = try #require(SearchEngine.labelPattern(
            for: ["a photo of a yellow duck swimming"]))
        #expect(!pattern.contains("photo"))
        #expect(pattern.contains("duck"))
        #expect(pattern.contains("yellow"))
    }

    @Test("A label with no overlap with the query is not a candidate")
    func unrelatedLabelsAreRejected() throws {
        #expect(SearchEngine.labelPattern(for: ["a photo of the"]) == nil)
    }
}
