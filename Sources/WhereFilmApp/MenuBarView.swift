import SwiftUI
import AppKit
import WhereFilmCore
import WhereFilmIndex

/// The menu bar panel.
///
/// The switch here is not decoration: it drives a real resource governor. When
/// the timeline needs every cycle, "Pause · 2h" genuinely stops the work and it
/// comes back on its own.
///
/// Worth saying plainly, because the wording matters to people: pausing the
/// indexer does not stop any listening. Indexing reads audio *tracks out of
/// files*. The microphone is never involved, and the app never asks for it.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private let pauseDurations: [(String, TimeInterval?)] = [
        ("15m", 15 * 60), ("30m", 30 * 60), ("1h", 3600),
        ("2h", 2 * 3600), ("4h", 4 * 3600), ("∞", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = model.startupError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Divider()
            indexerSection
            Divider()
            pauseSection
            Divider()
            statsSection
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Text("WhereFilm").font(.headline)
            Spacer()
            Text(model.pauseRemaining ?? model.throttleReason.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var indexerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INDEXER").font(.caption2).foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { model.mode },
                set: { model.mode = $0; if $0 != .paused { model.pausedUntil = nil } })) {
                ForEach(IndexerMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if let activity = model.currentActivity {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAUSE FOR").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(pauseDurations, id: \.0) { label, duration in
                    Button(label) { model.pause(for: duration) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if model.pauseRemaining != nil {
                Button("Resume now") { model.resume() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("\(model.stats.assets.formatted()) assets indexed")
            row("\(model.stats.moments.formatted()) searchable moments")
            if model.stats.volumesOffline > 0 {
                row("\(model.stats.volumesOffline) drive\(model.stats.volumesOffline == 1 ? "" : "s") offline")
            }
            if model.stats.pendingJobs > 0 {
                row("\(model.stats.pendingJobs.formatted()) files pending")
            }
            if model.stats.missingLocations > 0 {
                // Deliberately worded so it never reads as data loss.
                row("\(model.stats.missingLocations) originals missing — index kept")
            }
            if !model.modelInstalled {
                Text("Visual model not installed — run Scripts/fetch-models.sh")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func row(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: SearchWindowID)
            } label: {
                HStack {
                    Text("Open Search…")
                    Spacer()
                    Text("⌘⇧Space").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Button("Add Folder or Drive…") { addLibrary() }
                .buttonStyle(.plain)

            Divider()

            Button("Quit WhereFilm") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
    }

    private func addLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder or drive to index. Your originals are never moved or copied."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addLibrary(url)
    }
}
