#!/usr/bin/env swift

import Foundation

struct Dataset: Decodable {
    struct Case: Decodable {
        let id: String
        let category: String
        let cluster: String
        let query: String
        let expectedAssets: [String]
    }

    let name: String
    let cases: [Case]
}

struct Result {
    let test: Dataset.Case
    let rankedAssets: [String]
    let firstUsefulMilliseconds: Double?
    let stableMilliseconds: Double?

    var expectedRank: Int? {
        rankedAssets.firstIndex(where: test.expectedAssets.contains).map { $0 + 1 }
    }
}

func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func percentile(_ fraction: Double, _ samples: [Double]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let rank = fraction * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    guard lower != upper else { return sorted[lower] }
    return sorted[lower] + ((sorted[upper] - sorted[lower]) * (rank - Double(lower)))
}

func timedValue(named name: String, in output: String) -> Double? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    guard let expression = try? NSRegularExpression(pattern: "\\b\(escaped) ([0-9.]+) ms"),
          let match = expression.firstMatch(
            in: output,
            range: NSRange(output.startIndex..<output.endIndex, in: output)),
          let range = Range(match.range(at: 1), in: output)
    else { return nil }
    return Double(output[range])
}

func rankedAssets(in output: String) -> [String] {
    output.split(separator: "\n").compactMap { line in
        guard let dot = line.firstIndex(of: "."),
              Int(line[..<dot]) != nil
        else { return nil }
        let start = line.index(after: dot)
        let remainder = line[start...].trimmingCharacters(in: .whitespaces)
        return remainder.components(separatedBy: "  ").first
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let binaryArgument = value(after: "--binary", in: arguments),
      let databaseArgument = value(after: "--database", in: arguments),
      let datasetArgument = value(after: "--dataset", in: arguments)
else {
    FileHandle.standardError.write(Data("Usage: benchmark-search.swift --binary <wherefilm> --database <index.sqlite> --dataset <dataset.json>\n".utf8))
    exit(64)
}

let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let binary = URL(fileURLWithPath: binaryArgument, relativeTo: workingDirectory).standardizedFileURL
let database = URL(fileURLWithPath: databaseArgument, relativeTo: workingDirectory).standardizedFileURL
let datasetURL = URL(fileURLWithPath: datasetArgument, relativeTo: workingDirectory).standardizedFileURL
let dataset = try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: datasetURL))
let usesFoundationModel = arguments.contains("--with-foundation-model")

var results: [Result] = []
print(dataset.name)
print(String(repeating: "─", count: dataset.name.count))

for test in dataset.cases {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = binary
    process.arguments = ["search", "--database", database.path]
        + (usesFoundationModel ? [] : ["--no-llm"])
        + ["--limit", "10", test.query]
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("\n\(test.id) failed:\n\(output)".utf8))
        exit(process.terminationStatus)
    }

    // The current CLI reports progressive timings; the baseline CLI at HEAD
    // reported one legacy "in N ms" duration. Supporting both lets the same
    // immutable dataset measure before and after without patching the baseline.
    let legacyMilliseconds = timedValue(named: "in", in: output)
    let result = Result(
        test: test,
        rankedAssets: rankedAssets(in: output),
        firstUsefulMilliseconds: timedValue(named: "first useful", in: output) ?? legacyMilliseconds,
        stableMilliseconds: timedValue(named: "stable", in: output) ?? legacyMilliseconds
    )
    results.append(result)
    let rank = result.expectedRank.map(String.init) ?? "miss"
    print("\(rank == "1" ? "✓" : "·") \(test.id) [\(test.category)] rank=\(rank)")
}

let count = Double(results.count)
let top1 = results.filter { $0.expectedRank == 1 }.count
let recall5 = results.filter { ($0.expectedRank ?? .max) <= 5 }.count
let recall10 = results.filter { ($0.expectedRank ?? .max) <= 10 }.count
let reciprocalRank = results.reduce(0.0) { total, result in
    total + (result.expectedRank.map { 1.0 / Double($0) } ?? 0)
}

let grouped = Dictionary(grouping: results, by: { $0.test.cluster })
var overlaps: [Double] = []
for clusterResults in grouped.values where clusterResults.count > 1 {
    for left in 0..<(clusterResults.count - 1) {
        for right in (left + 1)..<clusterResults.count {
            let lhs = Set(clusterResults[left].rankedAssets.prefix(5))
            let rhs = Set(clusterResults[right].rankedAssets.prefix(5))
            let denominator = max(1, min(lhs.count, rhs.count))
            overlaps.append(Double(lhs.intersection(rhs).count) / Double(denominator))
        }
    }
}

let useful = results.compactMap(\.firstUsefulMilliseconds)
let stable = results.compactMap(\.stableMilliseconds)
print("\nQuality")
print("  Top-1 consistency  \(top1)/\(results.count) (\(String(format: "%.1f", Double(top1) / count * 100))%)")
print("  Recall@5          \(recall5)/\(results.count) (\(String(format: "%.1f", Double(recall5) / count * 100))%)")
print("  Recall@10         \(recall10)/\(results.count) (\(String(format: "%.1f", Double(recall10) / count * 100))%)")
print("  MRR               \(String(format: "%.3f", reciprocalRank / count))")
if !overlaps.isEmpty {
    print("  Top-5 overlap     \(String(format: "%.1f", overlaps.reduce(0, +) / Double(overlaps.count) * 100))%")
}

print("\nLatency across queries (cold CLI process per query)")
print("  first useful      p50 \(String(format: "%.1f", percentile(0.50, useful))) ms · p95 \(String(format: "%.1f", percentile(0.95, useful))) ms · p99 \(String(format: "%.1f", percentile(0.99, useful))) ms")
print("  stable            p50 \(String(format: "%.1f", percentile(0.50, stable))) ms · p95 \(String(format: "%.1f", percentile(0.95, stable))) ms · p99 \(String(format: "%.1f", percentile(0.99, stable))) ms")
