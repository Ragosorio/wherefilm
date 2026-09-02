import SwiftUI
import AppKit
import WhereFilmCore
import WhereFilmIndex

/// Compact control center. Indexing reads audio tracks from selected files; the
/// microphone is never involved and is not requested by the app.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    private let pauseDurations: [(String, TimeInterval?)] = [
        ("15 min", 15 * 60), ("1 h", 3600), ("4 h", 4 * 3600), ("Sin límite", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = model.startupError ?? model.libraryError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusCard
            pauseSection
            actions
        }
        .padding(16)
        .frame(width: 330)
        .preferredColorScheme(.dark)
        // Same reason as the search window: this panel paints its own near-black
        // ground, so inheriting a light `labelColor` would not merely look wrong,
        // it would make every line of text disappear.
        .foregroundStyle(WhereFilmBrand.silver)
        .tint(WhereFilmBrand.blue)
        .background(WhereFilmBrand.inkWell)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("WHEREFILM")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(1.8)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.8), radius: 5)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stat(model.stats.assets, "encontrados", icon: "photo.stack")
                Divider().frame(height: 34)
                stat(model.stats.searchableAssets, "buscables ahora", icon: "sparkles.rectangle.stack")
            }

            if model.stats.assets > 0 {
                Text("\(model.stats.visuallyUnderstoodAssets.formatted()) con comprensión visual · \(model.stats.transcribedAssets.formatted()) transcritos · \(model.stats.ocrEnrichedAssets.formatted()) con texto en pantalla")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.stats.enrichingAssets > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("WhereFilm está aprendiendo \(model.stats.enrichingAssets.formatted()) archivo(s)")
                        .font(.caption)
                }
            }

            if model.stats.volumesOffline > 0 {
                Label("\(model.stats.volumesOffline) disco(s) desconectado(s) · índice disponible", systemImage: "externaldrive.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.modelInstalled {
                Label("El modelo visual no está disponible", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(13)
        .whereFilmGlass(cornerRadius: 16)
    }

    private func stat(_ value: Int, _ label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(WhereFilmBrand.silver)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.formatted()).font(.headline).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TRABAJO EN SEGUNDO PLANO")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.mode == .paused || model.pauseRemaining != nil {
                    Button("Reanudar") { model.resume() }.buttonStyle(.link)
                }
            }

            if model.mode == .paused || model.pauseRemaining != nil {
                Text(model.pauseRemaining.map { "Pausado por \($0)" } ?? "Pausado hasta que lo reanudes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(pauseDurations, id: \.0) { label, duration in
                        Button(label) { model.pause(for: duration) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 8)

            action("Abrir búsqueda", symbol: "sparkle.magnifyingglass", shortcut: "⌘⇧Espacio") {
                SearchWindowController.shared.show()
            }
            action("Analizar fotos y videos del Mac", symbol: "photo.stack", shortcut: nil) {
                model.scanAllMediaLocations()
            }
            action("Añadir carpeta o disco…", symbol: "plus.rectangle.on.folder", shortcut: nil) {
                model.chooseLibrary()
            }

            Divider().padding(.vertical, 8)

            action(model.hidesDockIcon ? "Mostrar en el Dock" : "Ocultar del Dock",
                   symbol: model.hidesDockIcon ? "dock.arrow.up.rectangle" : "dock.arrow.down.rectangle",
                   shortcut: nil) {
                model.hidesDockIcon.toggle()
            }

            Divider().padding(.vertical, 8)

            Button("Salir de WhereFilm") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func action(_ title: String, symbol: String, shortcut: String?, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var statusLabel: String {
        if let remaining = model.pauseRemaining { return "Pausado · \(remaining)" }
        if model.mode == .paused { return "Pausado por ti" }
        if model.currentActivity != nil { return "Organizando tu archivo" }
        return switch model.throttleReason {
        case .none: "Listo para buscar"
        case .userPaused: "Pausado por ti"
        case .thermal: "Esperando a que la Mac se enfríe"
        case .lowPower: "Pausado por ahorro de energía"
        case .onBattery: "Con batería · buscando imágenes y texto"
        case .lowBattery: "Pausado · queda poca batería"
        case .editorInForeground: "Esperando mientras editas"
        case .editorRunning: "Modo ligero · editor abierto"
        case .searchActive: "Búsqueda con prioridad"
        }
    }

    private var statusColor: Color {
        model.mode == .paused || model.pauseRemaining != nil ? .orange : WhereFilmBrand.blue
    }
}
