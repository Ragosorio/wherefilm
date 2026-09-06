import Foundation
import ArgumentParser
import WhereFilmCore
import WhereFilmIndex

/// `wherefilm voices` — who was speaking, and linking that to who was on screen.
///
/// Kept as its own command rather than folded into `people` because it carries a
/// cost the rest of the product does not: the models are a download, and the
/// hardware requirement is real. Anything that costs a promise should be asked
/// for by name.
struct Voices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voices",
        abstract: "Speaker analysis: who talks, where, and which face they belong to.",
        discussion: """
            Apple silicon only, and the weights are fetched once from Hugging \
            Face by `voices install` — the single network request in this app, \
            which is why it is a command somebody runs rather than something \
            indexing does on its own. FluidAudio is Apache-2.0; the pyannote \
            models it downloads are CC-BY-4.0.
            """,
        subcommands: [VoicesStatus.self, VoicesInstall.self, VoicesList.self,
                      VoicesLink.self],
        defaultSubcommand: VoicesStatus.self)
}

struct VoicesStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Whether this Mac can do it, and what it has found.")

    @OptionGroup var storeOptions: StoreOptions

    func run() async throws {
        print("Speaker models: \(Diarizer.status)")
        let store = try storeOptions.makeStore()
        let stats = try store.voiceStats()
        print("\(stats.segments) speech segments · \(stats.voices) distinct voices "
            + "· \(stats.linked) linked to a person")
        if stats.segments == 0 {
            print("\nNothing yet. Speaker analysis is opt-in:")
            print("  wherefilm voices install        # once, downloads the models")
            print("  wherefilm index --voices")
        }
    }
}

struct VoicesInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Download the speaker models. Once, deliberately.")

    func run() async throws {
        guard Diarizer.isSupported else {
            throw ValidationError("Speaker analysis needs Apple silicon; this Mac has no "
                + "neural engine. Everything else works unchanged.")
        }
        print("Downloading speaker models from Hugging Face…")
        print("This is the only network request WhereFilm makes. Nothing about your")
        print("library is sent anywhere — the traffic is one way, and it happens once.")
        try await Diarizer.install()
        print("\nInstalled to \(Diarizer.modelsDirectory.path)")
        print("Now: wherefilm index --voices")
    }
}

struct VoicesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Distinct voices, and how much each one talks.")

    @OptionGroup var storeOptions: StoreOptions

    @Option(name: .shortAndLong, help: "How many to show.")
    var limit = 30

    func run() async throws {
        let store = try storeOptions.makeStore()
        let voices = try store.voices().prefix(limit)
        guard !voices.isEmpty else {
            print("No voices yet. `wherefilm voices status` explains why.")
            return
        }
        for voice in voices {
            guard let voiceID = voice.voiceID else { continue }
            let segments = try store.voiceSegments(voiceID: voiceID)
            let seconds = segments.reduce(0.0) { $0 + ($1.endSeconds - $1.startSeconds) }
            let files = Set(segments.map(\.assetID)).count
            var line = "[\(voiceID)] \(Int(seconds))s across \(files) file"
                + (files == 1 ? "" : "s")
            if let personID = voice.personID, let person = try store.person(id: personID) {
                line += " — \(person.displayName ?? "person \(personID)")"
            }
            print(line)
        }

        // Proposals are the interesting part: a voice that keeps overlapping one
        // face is very probably that person, and confirming it makes "¿dónde
        // habla Jorge?" work in the shots where he is off camera.
        let proposals = try await VoiceClusterer().proposals(store: store)
        let unlinked = proposals.filter { proposal in
            (try? store.voices().first { $0.voiceID == proposal.voiceID }?.personID) == nil
        }
        guard !unlinked.isEmpty else { return }
        print("\nLikely the same person, from how often they share the screen:")
        for proposal in unlinked.prefix(10) {
            let person = try store.person(id: proposal.personID)
            let name = person?.displayName ?? "unnamed person \(proposal.personID)"
            print("  voice \(proposal.voiceID) ↔ \(name) — "
                + "\(Int(proposal.sharedSeconds))s together, "
                + "\(Int(proposal.coverage * 100))% of what that voice says")
        }
        print("\nConfirm one with:  wherefilm voices link <voiceID> <personID>")
    }
}

struct VoicesLink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link", abstract: "This voice belongs to this person.")

    @OptionGroup var storeOptions: StoreOptions

    @Argument(help: "The voice id from `wherefilm voices list`.")
    var voiceID: Int64

    @Argument(help: "The person id from `wherefilm people list`. Omit to unlink.")
    var personID: Int64?

    func run() async throws {
        let store = try storeOptions.makeStore()
        if let personID {
            guard let person = try store.person(id: personID) else {
                throw ValidationError("No person with id \(personID).")
            }
            try store.link(voiceID: voiceID, to: personID)
            // Every file this voice speaks in gains a spoken appearance, so the
            // link is worth something immediately rather than at the next index.
            let assets = Set(try store.voiceSegments(voiceID: voiceID).map(\.assetID))
            var written = 0
            let linked = try store.voices().reduce(into: [Int64: Int64]()) { map, voice in
                if let id = voice.voiceID, let person = voice.personID { map[id] = person }
            }
            for assetID in assets {
                let segments = try store.voiceSegments(assetID: assetID)
                let spoken = SpokenAppearanceBuilder.intervals(
                    from: segments, assetID: assetID, personOf: linked)
                let faces = try store.appearances(assetID: assetID).filter { $0.source != "voice" }
                try store.replaceAppearances(assetID: assetID, faces + spoken)
                written += spoken.count
            }
            print("Voice \(voiceID) is \(person.displayName ?? "person \(personID)") — "
                + "\(written) spoken appearances across \(assets.count) files.")
        } else {
            try store.link(voiceID: voiceID, to: nil)
            print("Voice \(voiceID) is nobody in particular again.")
        }
    }
}
