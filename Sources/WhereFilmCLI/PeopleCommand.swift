import Foundation
import ArgumentParser
import WhereFilmCore
import WhereFilmIndex

/// `wherefilm people` — who the library thinks it has seen, and what you can
/// tell it about them.
///
/// Clustering can only ever produce "these look like the same person". Turning
/// that into "this is Jorge Álvarez" is a thing only a person can do, and every
/// correction has to outlive the next automatic pass, so naming, merging and
/// splitting are first-class commands rather than a debugging aid.
struct People: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "people",
        abstract: "See, name and correct the people found in your library.",
        discussion: """
            Face analysis is off unless you ask for it: `wherefilm index --faces`. \
            Face vectors are biometric data about people who did not choose to be \
            in an index, so it is a decision, not a default — and \
            `wherefilm people forget` removes all of it without touching anything \
            else the library knows.
            """,
        subcommands: [ListPeople.self, NamePerson.self, MergePeople.self,
                      SplitPerson.self, WherePerson.self, Consolidate.self, Forget.self],
        defaultSubcommand: ListPeople.self)
}

struct ListPeople: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Everyone the library has grouped so far.")

    @OptionGroup var storeOptions: StoreOptions

    @Flag(name: .long, help: "Only people who have been given a name.")
    var named = false

    @Option(name: .shortAndLong, help: "How many to show.")
    var limit = 40

    func run() async throws {
        let store = try storeOptions.makeStore()
        let stats = try store.peopleStats()
        print("\(stats.faces) faces · \(stats.people) people · \(stats.named) named "
            + "· \(stats.appearances) appearances")
        if stats.faces == 0 {
            print("\nNothing yet. Face analysis is opt-in:")
            print("  wherefilm index --faces")
            return
        }
        print("")

        let people = try store.people(includingUnnamed: !named, limit: limit)
        for person in people {
            guard let personID = person.personID else { continue }
            let name = person.displayName ?? "(unnamed)"
            let mark = person.isNamed ? "✓" : "·"
            print("\(mark) [\(personID)] \(name) — \(person.faceCount) faces")
        }
        let unnamed = people.filter { !$0.isNamed }.count
        if unnamed > 0 {
            print("\nName one with:  wherefilm people name <id> \"Jorge Álvarez\"")
        }
    }
}

struct NamePerson: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "name", abstract: "Say who a group of faces is.")

    @OptionGroup var storeOptions: StoreOptions

    @Argument(help: "The person id from `wherefilm people list`.")
    var personID: Int64

    @Argument(parsing: .remaining, help: "Their name. Omit to remove the name.")
    var name: [String] = []

    func run() async throws {
        let store = try storeOptions.makeStore()
        guard let person = try store.person(id: personID) else {
            throw ValidationError("No person with id \(personID).")
        }
        let joined = name.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        try store.name(personID: personID, as: joined.isEmpty ? nil : joined)
        if joined.isEmpty {
            print("Removed the name from person \(personID) — its \(person.faceCount) faces stay grouped.")
        } else {
            print("Person \(personID) is \(joined) — \(person.faceCount) faces, "
                + "searchable by name now.")
        }
    }
}

struct MergePeople: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge", abstract: "Two groups are the same person.")

    @OptionGroup var storeOptions: StoreOptions

    @Argument(help: "The group to keep.")
    var into: Int64

    @Argument(help: "The group to fold into it.")
    var from: Int64

    func run() async throws {
        let store = try storeOptions.makeStore()
        try store.merge(personID: from, into: into)
        let person = try store.person(id: into)
        print("Merged \(from) into \(into) — \(person?.faceCount ?? 0) faces"
            + (person?.displayName.map { " · \($0)" } ?? ""))
    }
}

struct SplitPerson: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split", abstract: "These faces are not that person.")

    @OptionGroup var storeOptions: StoreOptions

    @Argument(help: "The group they were wrongly put in.")
    var personID: Int64

    @Argument(parsing: .remaining, help: "Face ids to pull out.")
    var faceIDs: [Int64]

    func run() async throws {
        let store = try storeOptions.makeStore()
        guard !faceIDs.isEmpty else { throw ValidationError("Name at least one face id.") }
        guard let newID = try store.split(faceIDs: faceIDs, from: personID) else {
            throw ValidationError("Nothing to split.")
        }
        // The correction is recorded permanently: no later consolidation pass is
        // allowed to put these two back together.
        print("Moved \(faceIDs.count) faces out of \(personID) into new group \(newID).")
        print("They will never be merged back automatically.")
    }
}

struct WherePerson: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "where", abstract: "Where does this person appear?")

    @OptionGroup var storeOptions: StoreOptions

    @Argument(parsing: .remaining, help: "A name, spelled roughly.")
    var name: [String]

    func run() async throws {
        let store = try storeOptions.makeStore()
        let query = name.joined(separator: " ")
        let matches = try store.people(namedLike: query)
        guard !matches.isEmpty else {
            print("Nobody named anything like “\(query)”.")
            return
        }
        for match in matches {
            let appearances = try store.appearances(personID: match.personID)
            print("\(match.name) — \(appearances.count) appearances")
            var byAsset: [Int64: [PersonAppearance]] = [:]
            for appearance in appearances { byAsset[appearance.assetID, default: []].append(appearance) }
            for (assetID, list) in byAsset.sorted(by: { $0.key < $1.key }) {
                let asset = try store.asset(id: assetID)
                print("  \(asset?.displayName ?? "asset \(assetID)")")
                for appearance in list.prefix(12) {
                    let start = SearchResultTime.timecode(appearance.startSeconds)
                    let end = SearchResultTime.timecode(appearance.endSeconds)
                    let percent = Int((appearance.confidence * 100).rounded())
                    print("    \(start)–\(end)   \(percent)%")
                }
                if list.count > 12 { print("    … and \(list.count - 12) more") }
            }
        }
    }
}

struct Consolidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "consolidate",
        abstract: "Merge groups that turned out to be the same person.")

    @OptionGroup var storeOptions: StoreOptions

    func run() async throws {
        let store = try storeOptions.makeStore()
        let before = try store.peopleStats()
        let merged = try await FaceClusterer().consolidate(store: store)
        let after = try store.peopleStats()
        print("Merged \(merged) groups — \(before.people) → \(after.people) people.")
        print("Named groups and corrected splits were left alone.")
    }
}

struct Forget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget",
        abstract: "Delete every face and person, and nothing else.")

    @OptionGroup var storeOptions: StoreOptions

    @Flag(name: .long, help: "Required. This cannot be undone.")
    var yes = false

    func run() async throws {
        let store = try storeOptions.makeStore()
        let stats = try store.peopleStats()
        guard yes else {
            print("This would delete \(stats.faces) face vectors, \(stats.people) people "
                + "and \(stats.appearances) appearances.")
            print("Everything else — files, moments, transcripts, on-screen text, "
                + "labels, embeddings — is untouched,")
            print("and the library keeps working exactly as it did before anyone was recognised.")
            print("\nRun again with --yes to do it.")
            return
        }
        try store.forgetEveryone()
        print("Deleted \(stats.faces) face vectors and \(stats.people) people.")
        let after = try store.stats()
        print("The library still holds \(after.assets) files and \(after.moments) moments.")
    }
}

/// Timecodes are formatted in the search module, which the people commands do
/// not otherwise need. One small duplicate beats one large dependency.
enum SearchResultTime {
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
