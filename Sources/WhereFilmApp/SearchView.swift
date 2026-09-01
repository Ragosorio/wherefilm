import SwiftUI
import AppKit
import AVKit
import WhereFilmCore
import WhereFilmSearch

let SearchWindowID = "wherefilm.search"

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: SearchResult?
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { queryFocused = true }
        .sheet(item: $selected) { result in
            MomentPlayer(result: result) { selected = nil }
        }
    }

    private var composer: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Describe what you're looking for…", text: $model.query, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...3)
                    .focused($queryFocused)
                    .onSubmit { Task { await model.runSearch() } }
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
            }

            if let plan = model.lastPlan {
                // Showing the decomposition is not a debug affordance. When a
                // result looks wrong, this line is usually the explanation.
                HStack(spacing: 10) {
                    Text(plan.source.rawValue)
                    if !plan.visualPhrases.isEmpty {
                        Text("visual: \(plan.visualPhrases[0])")
                    }
                    if !plan.spokenTerms.isEmpty {
                        Text("spoken: \(plan.spokenTerms.prefix(4).joined(separator: ", "))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.searchError {
            centered(Label(error, systemImage: "exclamationmark.triangle"))
        } else if model.results.isEmpty {
            centered(emptyState)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results, id: \.momentKey) { result in
                        ResultRow(result: result) { selected = result }
                        Divider()
                    }
                }
            }
        }
    }

    private func centered<Content: View>(_ content: Content) -> some View {
        VStack { Spacer(); content; Spacer() }
            .frame(maxWidth: .infinity)
            .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(model.query.isEmpty ? "\(model.stats.moments.formatted()) moments indexed" : "No moments found")
                .font(.title3)
            Text(model.query.isEmpty
                 ? "Try: “entrevista de noche”, “letrero de McDonald's”, “donde habló del presupuesto”"
                 : "Try describing what you saw, or what was said.")
                .font(.callout)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.displayName).fontWeight(.medium)
                    Text(result.timeRange).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((result.score * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                // Never a bare percentage. Seeing which signal fired is what
                // makes a slightly-wrong answer useful instead of frustrating.
                ForEach(Array(result.evidence.prefix(3).enumerated()), id: \.offset) { _, evidence in
                    Label(evidence.label, systemImage: icon(for: evidence))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let location = result.bestLocation {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: location.availability))
                        Text(location.summary)
                        Text(location.relativePath)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .font(.caption)
                    .foregroundStyle(location.availability == .online ? Color.secondary : Color.orange)
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { if result.bestLocation?.url != nil { onOpen() } }
        .contextMenu {
            if let url = result.bestLocation?.url {
                Button("Play at \(SearchResult.timecode(result.startSeconds))") { onOpen() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            } else {
                Text("The drive holding this file isn't connected")
            }
        }
    }

    /// Previews are stored at index time precisely so a result stays *visible*
    /// after the drive goes back in the drawer.
    private var thumbnail: some View {
        Group {
            if let path = result.previewPath, let image = NSImage(contentsOf: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: result.mediaType == .video ? "film" : "photo")
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func icon(for evidence: Evidence) -> String {
        switch evidence {
        case .visual: "eye"
        case .transcript: "waveform"
        case .onScreenText: "textformat"
        case .metadata: "folder"
        }
    }

    private func symbol(for availability: Availability) -> String {
        switch availability {
        case .online: "externaldrive.fill"
        case .offline: "externaldrive.badge.xmark"
        case .moved: "arrow.triangle.turn.up.right.diamond"
        case .missing: "exclamationmark.triangle"
        }
    }
}

/// Plays the original starting at the matched instant.
///
/// The unit of a result is a *moment*, not a file, so "open it" has to mean
/// "open it there" — otherwise the user is left scrubbing a two-hour clip.
private struct MomentPlayer: View {
    let result: SearchResult
    let onClose: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            if let player {
                VideoPlayer(player: player)
                    .frame(minWidth: 720, minHeight: 405)
            } else if let url = result.bestLocation?.url,
                      let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(minWidth: 720, minHeight: 405)
            }

            HStack {
                Text(result.displayName).fontWeight(.medium)
                Text(result.timeRange).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onAppear(perform: prepare)
        .onDisappear { player?.pause() }
    }

    private func prepare() {
        guard result.mediaType != .image, let url = result.bestLocation?.url else { return }
        let player = AVPlayer(url: url)
        player.seek(to: CMTime(seconds: result.startSeconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        self.player = player
    }
}

extension SearchResult: Identifiable {
    public var id: String { momentKey }

    var momentKey: String {
        "\(assetID)-\(momentID ?? -1)-\(Int(startSeconds * 100))"
    }
}
