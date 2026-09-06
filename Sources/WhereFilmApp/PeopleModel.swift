import Foundation
import AppKit
import CoreGraphics
import ImageIO
import Observation
import WhereFilmCore
import WhereFilmIndex

/// The people half of the app, kept out of `AppModel` because it is optional and
/// most libraries will never turn it on.
///
/// Clustering can only ever say "these look like the same person". The step that
/// makes it useful — deciding that this group *is* Jorge Álvarez — is something
/// only a person can do, and it has to happen somewhere they can see the faces.
/// A command line is the wrong place to look at forty thumbnails and recognise a
/// friend.
@MainActor
@Observable
final class PeopleModel {
    struct Card: Identifiable, Sendable {
        let id: Int64
        var name: String?
        var faceCount: Int
        var appearanceCount: Int
        var thumbnail: NSImage?
        /// Files this person turns up in, for the line under their name.
        var assetCount: Int

        var isNamed: Bool { !(name ?? "").isEmpty }
    }

    /// What this Mac can do, so the interface offers rather than demands.
    struct Capability: Sendable {
        var faceModelInstalled = false
        var facesIndexed = 0
        var peopleFound = 0
        var canDiarize = false
        var speakerModelsInstalled = false

        /// Whether the feature has produced anything yet.
        var hasResults: Bool { facesIndexed > 0 }
    }

    private(set) var cards: [Card] = []
    private(set) var capability = Capability()
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?
    /// Selected for a merge. Two clusters, then one button.
    var selection: Set<Int64> = []

    private weak var app: AppModel?

    init(app: AppModel?) {
        self.app = app
    }

    private var store: IndexStore? { app?.store }

    // MARK: - Loading

    func refresh() {
        guard let store, !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            var capability = Capability()
            capability.faceModelInstalled = CoreMLFaceEmbedder.isInstalled
            capability.canDiarize = Diarizer.isSupported
            capability.speakerModelsInstalled = Diarizer.isInstalled
            if let stats = try? store.peopleStats() {
                capability.facesIndexed = stats.faces
                capability.peopleFound = stats.people
            }
            self.capability = capability

            let people = (try? store.people(limit: 300)) ?? []
            var built: [Card] = []
            for person in people {
                guard let personID = person.personID else { continue }
                let faces = (try? store.faces(personID: personID, limit: 40)) ?? []
                let appearances = (try? store.appearances(personID: personID)) ?? []
                built.append(Card(
                    id: personID,
                    name: person.displayName,
                    faceCount: person.faceCount,
                    appearanceCount: appearances.count,
                    thumbnail: Self.thumbnail(for: faces, store: store),
                    assetCount: Set(faces.map(\.assetID)).count))
            }
            // Named first, then the biggest groups: the ones worth naming next
            // are the ones the library keeps seeing.
            cards = built.sorted {
                if $0.isNamed != $1.isNamed { return $0.isNamed }
                return $0.faceCount > $1.faceCount
            }
        }
    }

    /// Cuts the face out of the thumbnail the preview cache already wrote.
    ///
    /// No original is opened. If the preview has been evicted the card simply
    /// has no picture, which is a cosmetic loss rather than a broken feature.
    private static func thumbnail(for faces: [FaceRow], store: IndexStore) -> NSImage? {
        let paths = (try? store.previewPaths(momentIDs: faces.map(\.momentID))) ?? [:]
        for face in faces {
            guard let path = paths[face.momentID],
                  let source = CGImageSourceCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }

            // Vision's box is normalised with the origin at the lower left; a
            // CGImage crops from the upper left. A little context around the
            // face reads better at thumbnail size than a tight box.
            let width = Double(image.width), height = Double(image.height)
            let padX = face.width * 0.3 * width, padY = face.height * 0.3 * height
            let rect = CGRect(x: face.x * width - padX,
                              y: (1 - face.y - face.height) * height - padY,
                              width: face.width * width + padX * 2,
                              height: face.height * height + padY * 2)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard rect.width > 8, let cropped = image.cropping(to: rect) else { continue }
            return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
        }
        return nil
    }

    // MARK: - What a person decides

    func name(_ personID: Int64, as name: String) {
        guard let store else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.name(personID: personID, as: trimmed.isEmpty ? nil : trimmed)
            if let index = cards.firstIndex(where: { $0.id == personID }) {
                cards[index].name = trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Folds every selected group into the first one. The named group wins the
    /// name, so merging never loses one.
    func mergeSelection() {
        guard let store, selection.count > 1 else { return }
        let chosen = cards.filter { selection.contains($0.id) }
        guard let target = chosen.first(where: \.isNamed) ?? chosen.first else { return }
        isWorking = true
        do {
            for card in chosen where card.id != target.id {
                try store.merge(personID: card.id, into: target.id)
            }
            selection.removeAll()
            isWorking = false
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }

    /// Runs the consolidation pass, which merges groups that are obviously the
    /// same person and refuses to touch anything somebody has already ruled on.
    func consolidate() {
        guard let store, !isWorking else { return }
        isWorking = true
        Task {
            let merged = (try? await FaceClusterer().consolidate(store: store)) ?? 0
            isWorking = false
            if merged == 0 { errorMessage = "No había grupos lo bastante parecidos para unir." }
            refresh()
        }
    }

    func forgetEveryone() {
        guard let store else { return }
        do {
            try store.forgetEveryone()
            cards = []
            selection.removeAll()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Queues face analysis for everything already indexed, without a re-scan.
    func analyseFaces() {
        app?.enableFaceAnalysis()
    }
}
