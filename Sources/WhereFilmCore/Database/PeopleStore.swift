import Foundation
import GRDB

/// Everything the index knows about people, kept deliberately separable.
///
/// Face vectors are biometric data. The original plan left them out of the
/// product for that reason, and bringing them in means the protections have to be
/// structural rather than promised: this is the only file that writes them, they
/// live in their own tables, and `forgetEveryone()` removes all of it without
/// touching a single asset, transcript or embedding. A library with the people
/// data deleted is a fully working search index that has never heard of anyone.
extension IndexStore {
    // MARK: - Faces

    @discardableResult
    public func insertFaces(_ faces: [FaceRow]) throws -> [FaceRow] {
        guard !faces.isEmpty else { return [] }
        return try dbPool.write { db in
            try faces.map { face in
                var copy = face
                try copy.insert(db)
                copy.faceID = db.lastInsertedRowID
                return copy
            }
        }
    }

    /// Removes the faces of one asset, the way a visual re-index removes its
    /// moments. Names survive: they belong to the person, not to the frame.
    public func deleteFaces(assetID: Int64) throws {
        _ = try dbPool.write { db in
            try FaceRow.filter(Column("assetID") == assetID).deleteAll(db)
        }
    }

    public func faces(assetID: Int64) throws -> [FaceRow] {
        try dbPool.read { db in
            try FaceRow.filter(Column("assetID") == assetID)
                .order(Column("seconds")).fetchAll(db)
        }
    }

    public func faces(personID: Int64, limit: Int = 500) throws -> [FaceRow] {
        try dbPool.read { db in
            try FaceRow.filter(Column("personID") == personID)
                .order(Column("quality").desc).limit(limit).fetchAll(db)
        }
    }

    public func face(id: Int64) throws -> FaceRow? {
        try dbPool.read { db in try FaceRow.fetchOne(db, key: id) }
    }

    public func faceCount(modelID: String? = nil) throws -> Int {
        try dbPool.read { db in
            if let modelID {
                return try Int.fetchOne(db, sql: "SELECT count(*) FROM faces WHERE modelID = ?",
                                        arguments: [modelID]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM faces") ?? 0
        }
    }

    /// Faces no cluster has claimed yet, oldest first, for the consolidation
    /// pass to work through in bounded batches.
    public func unassignedFaces(modelID: String, limit: Int = 2000) throws -> [FaceRow] {
        try dbPool.read { db in
            try FaceRow
                .filter(Column("personID") == nil && Column("modelID") == modelID)
                .order(Column("faceID")).limit(limit).fetchAll(db)
        }
    }

    // MARK: - People

    public func people(includingUnnamed: Bool = true, limit: Int = 500) throws -> [Person] {
        try dbPool.read { db in
            var request = Person.order(Column("faceCount").desc)
            if !includingUnnamed { request = request.filter(Column("isNamed") == true) }
            return try request.limit(limit).fetchAll(db)
        }
    }

    public func person(id: Int64) throws -> Person? {
        try dbPool.read { db in try Person.fetchOne(db, key: id) }
    }

    @discardableResult
    public func createPerson(centroid: [Float], coverFaceID: Int64?) throws -> Person {
        try dbPool.write { db in
            var person = Person(centroid: VectorCodec.encodeFloat32(centroid),
                                faceCount: 0, coverFaceID: coverFaceID)
            try person.insert(db)
            person.personID = db.lastInsertedRowID
            return person
        }
    }

    /// Points faces at a cluster and refreshes its centroid from what it now
    /// holds.
    ///
    /// `assignedBy` is the whole safety mechanism. An automatic pass may move a
    /// face it placed itself; it must never move one a person placed, because
    /// the only thing worse than a wrong cluster is a wrong cluster that keeps
    /// coming back after being corrected.
    public func assign(faceIDs: [Int64], to personID: Int64, assignedBy: String = "auto") throws {
        guard !faceIDs.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: faceIDs.count)
            var arguments: [any DatabaseValueConvertible] = [assignedBy, personID]
            arguments += faceIDs.map { $0 as any DatabaseValueConvertible }
            var sql = """
                UPDATE faces SET assignedBy = ?, personID = ?
                WHERE faceID IN (\(placeholders))
                """
            if assignedBy != "user" {
                sql += " AND assignedBy <> 'user'"
            }
            try db.execute(sql: sql, arguments: StatementArguments(arguments))
            try Self.refreshCentroid(db, personID: personID)
        }
    }

    /// Names a cluster, and makes the name findable with the typos people make.
    public func name(personID: Int64, as displayName: String?) throws {
        try dbPool.write { db in
            let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = !(trimmed?.isEmpty ?? true)
            try db.execute(sql: """
                UPDATE people SET displayName = ?, isNamed = ?, updatedAt = ? WHERE personID = ?
                """, arguments: [named ? trimmed : nil, named, Date(), personID])
            try db.execute(sql: "DELETE FROM person_names WHERE personID = ?",
                           arguments: [personID])
            if named, let trimmed {
                // The *folded* name is what gets indexed. Trigram tokenisation
                // is literal, so an indexed "Álvarez" and a typed "Alvarez"
                // share no run containing the accented character — and the
                // whole reason this table exists is to survive that. The name a
                // person will read comes from `people.displayName`.
                try db.execute(sql: "INSERT INTO person_names (name, personID) VALUES (?, ?)",
                               arguments: [Self.foldName(trimmed), personID])
            }
            var feedback = PersonFeedback(kind: .name, aPersonID: personID)
            try feedback.insert(db)
        }
    }

    /// Folds one cluster into another. The faces move, the correction is
    /// remembered, and the empty cluster goes away.
    public func merge(personID: Int64, into target: Int64) throws {
        guard personID != target else { return }
        try dbPool.write { db in
            try db.execute(sql: "UPDATE faces SET personID = ? WHERE personID = ?",
                           arguments: [target, personID])
            try db.execute(sql: "UPDATE person_appearances SET personID = ? WHERE personID = ?",
                           arguments: [target, personID])
            var feedback = PersonFeedback(kind: .merge, aPersonID: target, bPersonID: personID)
            try feedback.insert(db)
            try db.execute(sql: "DELETE FROM person_names WHERE personID = ?",
                           arguments: [personID])
            try db.execute(sql: "DELETE FROM people WHERE personID = ?", arguments: [personID])
            try Self.refreshCentroid(db, personID: target)
        }
    }

    /// Pulls faces out of a cluster into a new one. "These twelve are not him."
    @discardableResult
    public func split(faceIDs: [Int64], from personID: Int64) throws -> Int64? {
        guard !faceIDs.isEmpty else { return nil }
        return try dbPool.write { db in
            var person = Person(faceCount: 0)
            try person.insert(db)
            let newID = db.lastInsertedRowID
            let placeholders = databaseQuestionMarks(count: faceIDs.count)
            var arguments: [any DatabaseValueConvertible] = [newID]
            arguments += faceIDs.map { $0 as any DatabaseValueConvertible }
            // Marked as a person's decision, so no later pass can put them back.
            try db.execute(sql: """
                UPDATE faces SET personID = ?, assignedBy = 'user' WHERE faceID IN (\(placeholders))
                """, arguments: StatementArguments(arguments))
            var feedback = PersonFeedback(kind: .split, aPersonID: personID, bPersonID: newID)
            try feedback.insert(db)
            try Self.refreshCentroid(db, personID: personID)
            try Self.refreshCentroid(db, personID: newID)
            return newID
        }
    }

    /// Drops clusters that hold nothing. A split or a re-index can empty one, and
    /// an empty person in a list of people is a bug report waiting to happen.
    @discardableResult
    public func pruneEmptyPeople() throws -> Int {
        try dbPool.write { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT personID FROM people
                WHERE isNamed = 0
                  AND personID NOT IN (SELECT personID FROM faces WHERE personID IS NOT NULL)
                """)
            guard !ids.isEmpty else { return 0 }
            try db.execute(sql: """
                DELETE FROM people WHERE personID IN (\(databaseQuestionMarks(count: ids.count)))
                """, arguments: StatementArguments(ids))
            return ids.count
        }
    }

    private static func refreshCentroid(_ db: Database, personID: Int64) throws {
        let rows = try FaceRow.filter(Column("personID") == personID).fetchAll(db)
        guard !rows.isEmpty else {
            try db.execute(sql: "UPDATE people SET faceCount = 0, updatedAt = ? WHERE personID = ?",
                           arguments: [Date(), personID])
            return
        }
        var sum = [Float](repeating: 0, count: rows[0].dimensions)
        var counted = 0
        for row in rows {
            let vector = row.decodedVector
            guard vector.count == sum.count else { continue }
            for index in vector.indices { sum[index] += vector[index] }
            counted += 1
        }
        guard counted > 0 else { return }
        let centroid = VectorCodec.normalized(sum)
        // The best face of the cluster is its cover: a person picks their friend
        // out of a grid by the clearest picture, not the first one.
        let cover = rows.max { ($0.quality ?? 0) < ($1.quality ?? 0) }?.faceID
        try db.execute(sql: """
            UPDATE people SET centroid = ?, faceCount = ?, coverFaceID = ?, updatedAt = ?
            WHERE personID = ?
            """, arguments: [VectorCodec.encodeFloat32(centroid), rows.count,
                             cover, Date(), personID])
    }

    // MARK: - Appearances

    public func replaceAppearances(assetID: Int64, _ appearances: [PersonAppearance]) throws {
        try dbPool.write { db in
            try PersonAppearance.filter(Column("assetID") == assetID).deleteAll(db)
            for appearance in appearances {
                var copy = appearance
                try copy.insert(db)
            }
        }
    }

    public func appearances(personID: Int64, limit: Int = 500) throws -> [PersonAppearance] {
        try dbPool.read { db in
            try PersonAppearance.filter(Column("personID") == personID)
                .order(Column("assetID"), Column("startSeconds"))
                .limit(limit).fetchAll(db)
        }
    }

    public func appearances(assetID: Int64) throws -> [PersonAppearance] {
        try dbPool.read { db in
            try PersonAppearance.filter(Column("assetID") == assetID)
                .order(Column("startSeconds")).fetchAll(db)
        }
    }

    // MARK: - Finding people by name

    public struct NamedPerson: Sendable {
        public let personID: Int64
        public let name: String
        /// Lower is better, straight from bm25.
        public let rank: Double
    }

    /// Names, folded to the form the index stores them in.
    ///
    /// Accents are a spelling detail people drop constantly — "Alvarez" for
    /// "Álvarez" — so they are removed on both sides. Everything else about a
    /// name is preserved.
    public static func foldName(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "es"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func trigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 3 else { return [] }
        return (0...(characters.count - 3)).map { String(characters[$0..<($0 + 3)]) }
    }

    /// Finds people whose name matches, tolerantly.
    ///
    /// Two steps, because neither alone is enough. The trigram index narrows
    /// thousands of names to a handful by shared three-character runs — that is
    /// what lets "Alvares" reach "Álvarez" at all, since the two share every run
    /// but one. Then the handful is ranked in Swift by edit distance, because
    /// FTS5 ranks by term frequency and a misspelling is not a frequency
    /// question.
    ///
    /// The table holds only names a person typed, so it stays tiny however large
    /// the library grows, and the second step is over a handful of short strings.
    public func people(namedLike query: String, limit: Int = 10) throws -> [NamedPerson] {
        let folded = Self.foldName(query)
        guard folded.count >= 3 else { return [] }
        let runs = Self.trigrams(folded)
        guard !runs.isEmpty else { return [] }
        let pattern = runs.map { "\"\($0)\"" }.joined(separator: " OR ")

        let candidates: [(personID: Int64, folded: String, display: String)] =
            try dbPool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT person_names.name AS folded, person_names.personID AS personID,
                           people.displayName AS display, bm25(person_names) AS rank
                    FROM person_names
                    JOIN people ON people.personID = person_names.personID
                    WHERE person_names MATCH ? ORDER BY rank LIMIT ?
                    """, arguments: [pattern, limit * 6])
                    .map { (personID: $0["personID"], folded: $0["folded"],
                            display: $0["display"] ?? $0["folded"]) }
            }

        return candidates
            .map { candidate -> (NamedPerson, Double) in
                let similarity = Self.nameSimilarity(folded, candidate.folded)
                return (NamedPerson(personID: candidate.personID, name: candidate.display,
                                    rank: 1 - similarity), similarity)
            }
            // A name has to be close, not merely to share letters: without this
            // every three-letter run in the library would answer every query.
            .filter { $0.1 >= 0.62 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// How alike two folded names are, 0…1.
    ///
    /// Whole words count for more than characters do: searching "Jorge" when the
    /// library holds "Jorge Álvarez" is a real question with a right answer, and
    /// edit distance alone would call those two names barely related.
    static func nameSimilarity(_ query: String, _ name: String) -> Double {
        guard !query.isEmpty, !name.isEmpty else { return 0 }
        if name.contains(query) || query.contains(name) { return 1 }

        let asked = query.split(separator: " ").map(String.init)
        let stored = name.split(separator: " ").map(String.init)
        var wordScore = 0.0
        for word in asked {
            let best = stored.map { 1 - normalizedDistance(word, $0) }.max() ?? 0
            wordScore += best
        }
        wordScore /= Double(asked.count)

        let whole = 1 - normalizedDistance(query, name)
        return max(wordScore, whole)
    }

    /// Levenshtein distance divided by the longer string, so it is comparable
    /// across names of different lengths.
    static func normalizedDistance(_ a: String, _ b: String) -> Double {
        let left = Array(a), right = Array(b)
        guard !left.isEmpty, !right.isEmpty else { return 1 }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[right.count]) / Double(max(left.count, right.count))
    }

    /// An unordered pair of person ids, so "3 was split from 7" and "7 was split
    /// from 3" are the same fact.
    public struct Pair: Hashable, Sendable {
        public let low: Int64
        public let high: Int64

        public init(_ a: Int64, _ b: Int64) {
            low = min(a, b)
            high = max(a, b)
        }
    }

    /// Pairs of clusters a person has pulled apart.
    ///
    /// Read before any automatic merge. "These twelve are not him" has to
    /// outlive every later pass, or the correction is theatre.
    public func splitPairs() throws -> Set<Pair> {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT aPersonID, bPersonID FROM people_feedback WHERE kind = 'split'")
            var out: Set<Pair> = []
            for row in rows {
                guard let a: Int64 = row["aPersonID"], let b: Int64 = row["bPersonID"]
                else { continue }
                out.insert(Pair(a, b))
            }
            return out
        }
    }

    // MARK: - Statistics and erasure

    public struct PeopleStats: Sendable {
        public let faces: Int
        public let people: Int
        public let named: Int
        public let unassignedFaces: Int
        public let appearances: Int
    }

    public func peopleStats() throws -> PeopleStats {
        try dbPool.read { db in
            PeopleStats(
                faces: try Int.fetchOne(db, sql: "SELECT count(*) FROM faces") ?? 0,
                people: try Int.fetchOne(db, sql: "SELECT count(*) FROM people") ?? 0,
                named: try Int.fetchOne(db, sql: "SELECT count(*) FROM people WHERE isNamed = 1") ?? 0,
                unassignedFaces: try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM faces WHERE personID IS NULL") ?? 0,
                appearances: try Int.fetchOne(db, sql: "SELECT count(*) FROM person_appearances") ?? 0)
        }
    }

    /// Deletes every trace of face and person analysis, and nothing else.
    ///
    /// This is not a convenience. Biometric data that cannot be removed on
    /// demand should not be collected, so the button has to exist before the
    /// feature does — and it has to be provably narrow: assets, locations,
    /// moments, embeddings, transcripts, OCR and labels are all untouched, and
    /// the library keeps working exactly as it did before anyone was recognised.
    public func forgetEveryone() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM person_appearances")
            try db.execute(sql: "DELETE FROM person_names")
            try db.execute(sql: "DELETE FROM people_feedback")
            try db.execute(sql: "DELETE FROM faces")
            try db.execute(sql: "DELETE FROM people")
        }
    }
}
