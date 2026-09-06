import SwiftUI
import WhereFilmCore

/// Where a repeated stranger becomes a name.
///
/// The clustering can group faces; it cannot know who anybody is. This is the
/// only place in the product where the machine asks a question instead of
/// answering one, and the whole design follows from that: the faces are large
/// enough to recognise, the field to name them is the first thing under each
/// one, and every correction is one click.
struct PeopleView: View {
    @Bindable var model: PeopleModel
    @Environment(\.dismiss) private var dismiss

    /// Names being typed, held here so a field does not fight the model on every
    /// keystroke.
    @State private var drafts: [Int64: String] = [:]
    @State private var confirmingForget = false
    /// Which field is being typed in, so a name is saved when somebody clicks
    /// away instead of only when they remember to press Return.
    @FocusState private var focusedPerson: Int64?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)

            if model.cards.isEmpty {
                empty
            } else {
                grid
            }

            Divider().opacity(0.25)
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(WhereFilmBrand.background)
        .onAppear { model.refresh() }
        .alert("No se pudo guardar", isPresented: .constant(model.errorMessage != nil)) {
            Button("Entendido") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Personas")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(WhereFilmBrand.vapor.opacity(0.75))
                    // Long status lines wrap instead of pushing the window wide.
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Listo") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        let capability = model.capability
        if !capability.hasResults {
            return "Todo ocurre en tu Mac. Nada se envía a ningún lado."
        }
        let named = model.cards.filter(\.isNamed).count
        return "\(capability.facesIndexed) caras · \(capability.peopleFound) grupos · "
            + "\(named) con nombre"
    }

    // MARK: - Empty state

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(WhereFilmBrand.vapor.opacity(0.5))

            Text("Todavía no hay caras agrupadas")
                .font(.title3.weight(.medium))

            // The capability is described, and then offered. Never demanded.
            Text(offerText)
                .font(.callout)
                .foregroundStyle(WhereFilmBrand.vapor.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            if model.capability.faceModelInstalled {
                Button {
                    model.analyseFaces()
                    model.refresh()
                } label: {
                    Label("Analizar caras de mi biblioteca", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            capabilityNotes
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    /// What this Mac can and cannot do, stated once and without asking for
    /// anything.
    ///
    /// The app should never demand a capability it can check for. On a Mac
    /// without a neural engine speaker analysis is simply absent, and saying so
    /// plainly is more useful than a button that fails.
    private var capabilityNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            capabilityRow(
                ok: model.capability.faceModelInstalled,
                title: "Reconocimiento facial",
                detail: model.capability.faceModelInstalled
                    ? "Modelo instalado (AuraFace)."
                    : "Sin modelo: las caras se agrupan con un descriptor genérico "
                        + "que confunde a personas distintas.")
            capabilityRow(
                ok: model.capability.canDiarize && model.capability.speakerModelsInstalled,
                title: "Quién habla",
                detail: !model.capability.canDiarize
                    ? "Necesita Apple Silicon. Esta Mac no puede, y todo lo demás sigue igual."
                    : (model.capability.speakerModelsInstalled
                        ? "Modelos instalados."
                        : "Falta una descarga única: wherefilm voices install"))
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.top, 6)
    }

    private func capabilityRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(ok ? Color.green.opacity(0.8) : WhereFilmBrand.vapor.opacity(0.6))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(WhereFilmBrand.vapor.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var offerText: String {
        if model.capability.faceModelInstalled {
            return """
                WhereFilm puede agrupar las caras que se repiten y dejarte ponerles \
                nombre. Es opcional, se guarda solo en esta Mac, y puedes borrarlo \
                todo cuando quieras. Volver a analizar lo ya indexado toma un rato.
                """
        }
        return """
            Falta el modelo de reconocimiento facial. Sin él las caras se agrupan \
            con un descriptor genérico que confunde a personas distintas.
            Instálalo una vez con Scripts/fetch-face-model.sh y vuelve aquí.
            """
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)],
                spacing: 18
            ) {
                ForEach(model.cards) { card in
                    personCard(card)
                }
            }
            .padding(22)
        }
    }

    private func personCard(_ card: PeopleModel.Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail = card.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(WhereFilmBrand.ophelia.opacity(0.6))
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(WhereFilmBrand.vapor.opacity(0.45)))
                    }
                }
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipped()

                if model.selection.contains(card.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, WhereFilmBrand.blue)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { toggle(card.id) }

            // The field is the point of the whole screen, so it comes first and
            // it is always there — named or not.
            TextField("¿Quién es?", text: binding(for: card))
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .lineLimit(1)
                .focused($focusedPerson, equals: card.id)
                .onSubmit { commit(card.id) }
                // Typing a name and clicking the next face is the natural way to
                // work through a wall of strangers. Losing the name because
                // nobody pressed Return would be the interface's fault.
                .onChange(of: focusedPerson) { previous, _ in
                    if previous == card.id { commit(card.id) }
                }

            Text(detail(for: card))
                .font(.caption2)
                .foregroundStyle(WhereFilmBrand.vapor.opacity(0.65))
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .whereFilmGlass(cornerRadius: 16)
        .contextMenu {
            Button(model.selection.contains(card.id) ? "Quitar de la selección" : "Seleccionar") {
                toggle(card.id)
            }
            if card.isNamed {
                Button("Quitar el nombre") { model.name(card.id, as: "") }
            }
        }
    }

    private func detail(for card: PeopleModel.Card) -> String {
        var parts = ["\(card.faceCount) \(card.faceCount == 1 ? "cara" : "caras")"]
        if card.assetCount > 0 {
            parts.append("\(card.assetCount) \(card.assetCount == 1 ? "archivo" : "archivos")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.consolidate()
            } label: {
                Label("Unir parecidos", systemImage: "arrow.triangle.merge")
            }
            .help("Une grupos que son claramente la misma persona. Nunca une dos que ya tienen nombre.")
            .disabled(model.cards.count < 2 || model.isWorking)

            Button {
                model.mergeSelection()
            } label: {
                Label("Es la misma persona (\(model.selection.count))",
                      systemImage: "person.2.badge.gearshape")
            }
            .disabled(model.selection.count < 2 || model.isWorking)

            Spacer()

            if model.isWorking || model.isLoading {
                ProgressView().controlSize(.small)
            }

            Button(role: .destructive) {
                confirmingForget = true
            } label: {
                Label("Borrar todas las personas", systemImage: "trash")
            }
            .disabled(model.cards.isEmpty)
            .confirmationDialog(
                "¿Borrar todas las caras y personas?",
                isPresented: $confirmingForget, titleVisibility: .visible
            ) {
                Button("Borrar todo", role: .destructive) { model.forgetEveryone() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borran caras, grupos, nombres y apariciones. Tus archivos, "
                    + "momentos, transcripciones y búsquedas quedan intactos.")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - Editing

    private func binding(for card: PeopleModel.Card) -> Binding<String> {
        Binding(
            get: { drafts[card.id] ?? card.name ?? "" },
            set: { drafts[card.id] = $0 }
        )
    }

    private func commit(_ personID: Int64) {
        guard let draft = drafts[personID] else { return }
        // Only write when it actually changed: every focus change would
        // otherwise rewrite the same name and log a correction that never
        // happened.
        let current = model.cards.first { $0.id == personID }?.name ?? ""
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) != current else { return }
        model.name(personID, as: draft)
    }

    private func toggle(_ personID: Int64) {
        if model.selection.contains(personID) {
            model.selection.remove(personID)
        } else {
            model.selection.insert(personID)
        }
    }
}
