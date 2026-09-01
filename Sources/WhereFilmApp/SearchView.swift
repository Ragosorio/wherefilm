import SwiftUI
import AppKit
import AVKit
import WhereFilmCore
import WhereFilmSearch

let SearchWindowID = "wherefilm.search"

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: SearchResult?
    @State private var showingSettings = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        ZStack {
            WhereFilmBrand.background.ignoresSafeArea()

            Circle()
                .fill(WhereFilmBrand.blue.opacity(0.12))
                .frame(width: 620, height: 620)
                .blur(radius: 100)
                .offset(x: 380, y: -330)

            VStack(spacing: 0) {
                topBar
                composer
                content
            }
        }
        .preferredColorScheme(.dark)
        // An explicit tint as well as the colour scheme: every surface here is
        // near-black, so inheriting a light `labelColor` would make the text
        // vanish rather than merely look wrong.
        .foregroundStyle(WhereFilmBrand.silver)
        .tint(WhereFilmBrand.blue)
        .frame(minWidth: 820, minHeight: 620)
        .onAppear {
            // Keep release QA observational: the harness supplies a query and
            // should not leave a focused editor able to consume stray keyboard
            // input from the machine while six cases run unattended.
            if ProcessInfo.processInfo.environment["WHEREFILM_QA_REPORT"] == nil {
                queryFocused = true
            }
        }
        .sheet(item: $selected) { result in
            MomentPlayer(result: result) { selected = nil }
                .preferredColorScheme(.dark)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("WHEREFILM")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(2.1)
                Text("Tu archivo, al alcance de una frase")
                    .font(.caption)
                    .foregroundStyle(WhereFilmBrand.vapor.opacity(0.72))
            }

            Spacer()

            Label("Todo ocurre en tu Mac", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(WhereFilmBrand.silver.opacity(0.84))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(WhereFilmBrand.ophelia.opacity(0.72), in: Capsule())
                .overlay(Capsule().stroke(WhereFilmBrand.vapor.opacity(0.14)))

            Menu {
                Button {
                    model.scanAllMediaLocations()
                } label: {
                    Label("Analizar fotos y videos de mi Mac", systemImage: "photo.stack")
                }
                Button {
                    model.chooseLibrary()
                } label: {
                    Label("Añadir carpeta o disco específico…", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Analizar archivos", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Preferencias")
            .popover(isPresented: $showingSettings, arrowEdge: .top) {
                settingsPanel
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var composer: some View {
        @Bindable var model = model

        return VStack(spacing: 12) {
            VStack(spacing: 8) {
                Text("Encuentra el momento. No el archivo.")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                    .multilineTextAlignment(.center)

                Text("Describe una escena, un lugar o algo que se dijo.")
                    .font(.callout)
                    .foregroundStyle(WhereFilmBrand.vapor.opacity(0.78))
            }

            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(WhereFilmBrand.silver)

                TextField("Ejemplo: persona frente al mar hablando del presupuesto", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .focused($queryFocused)
                    .onSubmit { Task { await model.runSearch() } }

                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.results = []
                        model.lastPlan = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await model.runSearch() }
                } label: {
                    Text("Buscar")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(WhereFilmBrand.blue)
                .controlSize(.large)
                .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(WhereFilmBrand.inkWell.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(WhereFilmBrand.searchGlow, lineWidth: queryFocused ? 1.5 : 0.8)
                    .opacity(queryFocused ? 0.88 : 0.48)
            }
            .shadow(color: WhereFilmBrand.blue.opacity(queryFocused ? 0.2 : 0.08), radius: 24)

            HStack(spacing: 12) {
                Text("ALCANCE")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(.tertiary)

                Picker("Alcance", selection: $model.precision) {
                    ForEach(SearchPrecision.allCases) { precision in
                        Text(precision.label).tag(precision)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Text(model.precision.explanation)
                    .font(.caption)
                    .foregroundStyle(WhereFilmBrand.vapor.opacity(0.68))

                Spacer()

                if model.currentActivity != nil {
                    Label("Organizando en segundo plano", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(WhereFilmBrand.vapor.opacity(0.72))
                }
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.searchError ?? model.libraryError {
            centered(
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(20)
            )
        } else if model.results.isEmpty {
            centered(emptyState)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(model.results.count) momentos")
                        .font(.headline)
                    Text("ordenados por relevancia")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Haz clic para abrir justo ahí")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 44)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 390), spacing: 16)], spacing: 16) {
                        ForEach(model.results, id: \.momentKey) { result in
                            ResultCard(result: result) { selected = result }
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.bottom, 34)
                }
            }
        }
    }

    private func centered<Content: View>(_ content: Content) -> some View {
        VStack { Spacer(); content; Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.stats.assets == 0 {
            VStack(spacing: 16) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(WhereFilmBrand.silver)
                    .symbolEffect(.pulse, options: .repeating.speed(0.35))
                Text("Tu memoria visual empieza aquí")
                    .font(.title2.weight(.semibold))
                Text("Analiza automáticamente tus fotos y videos. WhereFilm aprende a encontrar cualquier momento sin subirlos a ninguna parte.")
                    .foregroundStyle(WhereFilmBrand.vapor.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                HStack(spacing: 12) {
                    Button("Analizar Fotos y Videos de mi Mac") { model.scanAllMediaLocations() }
                        .buttonStyle(.borderedProminent)
                        .tint(WhereFilmBrand.blue)
                        .controlSize(.large)
                    Button("Elegir carpeta específica…") { model.chooseLibrary() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .padding(34)
            .whereFilmGlass()
            .padding(.horizontal, 44)
        } else if model.query.isEmpty {
            VStack(spacing: 18) {
                Text("\(model.stats.moments.formatted()) momentos listos para encontrar")
                    .font(.title3.weight(.semibold))
                Text("Prueba una búsqueda")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    suggestion("atardecer frente al mar")
                    suggestion("carretera entre árboles")
                    suggestion("donde hablaron del presupuesto")
                }
            }
            .padding(28)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 34, weight: .light))
                Text("No encontramos una coincidencia clara")
                    .font(.title3.weight(.semibold))
                Text(model.precision == .broad
                     ? "Prueba con menos detalles o con una frase distinta."
                     : "Cambia el alcance a Amplia para explorar coincidencias aproximadas.")
                    .foregroundStyle(.secondary)
                if model.precision != .broad {
                    Button("Buscar de forma más amplia") {
                        model.precision = .broad
                        Task { await model.runSearch() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
    }

    private func suggestion(_ text: String) -> some View {
        Button("“\(text)”") {
            model.query = text
            Task { await model.runSearch() }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preferencias")
                .font(.headline)
            Toggle("Abrir WhereFilm al iniciar sesión", isOn: Binding(
                get: { model.launchesAtLogin },
                set: { model.setLaunchesAtLogin($0) }
            ))
            Text("Tus originales nunca se mueven. El índice y las vistas previas viven únicamente en esta Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Atajo global")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text("Abrir búsqueda")
                Spacer()
                Text("⌘⇧Espacio").foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

private struct ResultCard: View {
    let result: SearchResult
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                SearchResultThumbnail(result: result)
                LinearGradient(colors: [.clear, .black.opacity(0.74)], startPoint: .center, endPoint: .bottom)

                HStack {
                    if result.mediaType != .image {
                        Label(SearchResult.timecode(result.startSeconds), systemImage: "play.fill")
                    } else {
                        Label("Foto", systemImage: "photo")
                    }
                    Spacer()
                    Text("\(Int((result.score * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(.caption.weight(.semibold))
                .padding(10)
            }
            .frame(height: 168)
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(result.displayName)
                    .font(.headline)
                    .lineLimit(1)

                if let evidence = result.evidence.first {
                    Label(evidenceText(evidence), systemImage: icon(for: evidence))
                        .font(.caption)
                        .foregroundStyle(WhereFilmBrand.vapor.opacity(0.78))
                        .lineLimit(2)
                }

                if let location = result.bestLocation {
                    Label(locationText(location), systemImage: symbol(for: location.availability))
                        .font(.caption2)
                        .foregroundStyle(location.availability == .online ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
            }
            .padding(13)
        }
        .whereFilmGlass(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onOpen)
        .contextMenu {
            if let url = result.bestLocation?.url {
                Button("Abrir en \(SearchResult.timecode(result.startSeconds))", action: onOpen)
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copiar ruta") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            } else {
                Button("Ver vista previa", action: onOpen)
                Text("Conecta el disco para abrir el original")
            }
        }
    }

    private func evidenceText(_ evidence: Evidence) -> String {
        switch evidence {
        case .visual: "La escena coincide con tu descripción"
        case .transcript(let text, _): "Se escucha: “\(text.prefix(92))”"
        case .onScreenText(let text): "Aparece escrito: “\(text.prefix(72))”"
        case .metadata(let text, _): "Coincide con: \(text.prefix(72))"
        }
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

    private func locationText(_ location: ResolvedLocation) -> String {
        switch location.availability {
        case .online: "Disponible en \(location.volumeName)"
        case .offline: "Disco desconectado · vista previa disponible"
        case .moved: "El original cambió de lugar"
        case .missing: "Original no encontrado · índice conservado"
        }
    }
}

/// Dynamic thumbnail loader that handles pre-cached thumbnails, live original images,
/// and extracted video keyframes on-the-fly without locking the UI.
private struct SearchResultThumbnail: View {
    let result: SearchResult
    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoading {
                ZStack {
                    Rectangle().fill(WhereFilmBrand.brocade)
                    ProgressView().controlSize(.small)
                }
            } else {
                Rectangle().fill(WhereFilmBrand.brocade)
                    .overlay(
                        Image(systemName: result.mediaType == .video ? "film" : "photo")
                            .font(.title2)
                            .foregroundStyle(WhereFilmBrand.silver.opacity(0.45))
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: result.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // 1. Try cached preview on disk first
        if let previewPath = result.previewPath,
           let cached = NSImage(contentsOf: previewPath) {
            self.image = cached
            return
        }

        // 2. Direct fallback to live original media file
        guard let url = result.bestLocation?.url,
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        let mediaType = result.mediaType
        let startSecs = result.startSeconds

        let loaded: NSImage? = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            if mediaType == .image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    return NSImage(contentsOf: url)
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                return NSImage(contentsOf: url)
            } else if mediaType == .video {
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 512, height: 512)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                let time = CMTime(seconds: startSecs, preferredTimescale: 600)
                if let (cg, _) = try? await generator.image(at: time) {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            return nil
        }.value

        if let loaded {
            self.image = loaded
        }
    }
}

/// Opens the original at the matched moment. If its drive is disconnected, the
/// cached preview remains visible so a useful search result never turns blank.
private struct MomentPlayer: View {
    let result: SearchResult
    let onClose: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let imageURL = displayImageURL,
                          let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ContentUnavailableView("Vista previa no disponible", systemImage: "film")
                }
            }
            .frame(minWidth: 760, minHeight: 430)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.displayName).fontWeight(.medium)
                    Text(result.bestLocation?.url == nil
                         ? "Conecta el disco para reproducir el original"
                         : result.timeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = result.bestLocation?.url {
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Cerrar", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(WhereFilmBrand.inkWell)
        }
        .onAppear(perform: prepare)
        .onDisappear { player?.pause() }
    }

    private var displayImageURL: URL? {
        if result.mediaType == .image, let original = result.bestLocation?.url, FileManager.default.fileExists(atPath: original.path) {
            return original
        }
        return result.previewPath
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
