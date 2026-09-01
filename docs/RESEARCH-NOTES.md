# De dónde salió esto

Este proyecto arranca de una investigación profunda sobre cómo construir un
"Spotlight semántico" local para video y foto, nativo de macOS. Lo que sigue son
las conclusiones de esa investigación **más las verificaciones que hice contra
el SDK y los repositorios reales** en agosto de 2026 — incluyendo los tres puntos
donde la realidad no coincidió con el documento original.

## Lo que la investigación estableció

**No hace falta un LLM grande para buscar.** Un modelo imagen-texto produce un
vector para la frase y lo compara con los precalculados de los frames. Para
"dijo que no había presupuesto" se consulta la transcripción. El LLM, si se usa,
interpreta la consulta — no indexa la biblioteca.

**Indexar es caro; buscar no.** MaterialSearch reporta ~31.000 comparaciones de
imagen por segundo en un Intel J3455 modesto. Son benchmarks del proyecto, no
garantías, pero el punto se sostiene: una vez calculados los embeddings, buscar
es barato.

**No hay que indexar cada frame.** 30 min a 30 fps = 54.000 frames, casi todos
redundantes. Media Search Agent detecta shots y extrae keyframes; Fennec hace
scene detection; SentrySearch limita frames por bloque.

**Los originales no se mudan.** Peakto, Axle AI e Iconik convergen en el modelo
*catalog in place*: apuntar al almacenamiento existente y guardar la inteligencia
por separado. Iconik es explícito en que el registro del asset y su metadata
existen independientemente de la capa de almacenamiento.

**El análisis puede ser cacheable y transportable.** Adobe guarda el resultado de
Media Intelligence en el Media Cache, o como sidecar `.prmi` junto al video —
otra computadora reutiliza el análisis sin reprocesar el clip.

**La identidad no puede ser la ruta.** Peakto documenta el caso de una unidad
remontada como `/Volumes/Media 1`. Apple documenta que `fileResourceIdentifier`
no persiste entre reinicios.

## Lo que verifiqué, y dónde cambió el plan

### 1. MobileCLIP2 no tiene export oficial de Core ML

La investigación proponía MobileCLIP2. El hub dice otra cosa: Apple publica
MobileCLIP2 (S0/S2/S3/S4/B/L-14) **solo en PyTorch/OpenCLIP**. El repositorio
`apple/coreml-mobileclip` contiene únicamente **MobileCLIP v1**: `s0`, `s1`,
`s2`, `blt`.

Leído directamente del protobuf de los `.mlmodel`:

```
image encoder : image  RGB 256×256      → final_emb_1 [1,512] FLOAT32
text encoder  : text   INT32 [1,77]     → final_emb_1 [1,512] FLOAT32
```

**Consecuencia:** v1 del producto usa MobileCLIP-S0 v1. MobileCLIP2 y SigLIP 2
quedan como conversiones propias con `coremltools`, detrás de la misma
abstracción. Ver [ADR 4](decisions/0004-mobileclip-v1-and-the-spanish-problem.md).

### 2. El problema del español es medible, no teórico

El tokenizer CLIP lo hace visible. Contrastado contra
`openai/clip-vit-base-patch32` y reproducido exactamente por la implementación
Swift de este repositorio:

```
"a photo of a cat"                  → [49406, 320, 1125, 539, 320, 2368, 49407]
"man wearing a blue shirt"          → [49406, 786, 3309, 320, 1746, 2523, 49407]
"hombre con camisa azul, de noche!" → [49406, 906, 7782, 2457, 1004, 6536, 39807, …]
```

*man* es un token. *hombre* es `hom` + `bre</w>`. Por eso la traducción ocurre en
la consulta, no en el modelo.

### 3. La escala de similitud de MobileCLIP es la mitad de lo que se suele asumir

Medido en un MacBook Air M4 sobre fotografías reales:

| | cosine |
|---|---|
| Respuesta correcta | 0,177 – 0,258 |
| Plausible pero equivocada | 0,13 – 0,21 |
| Consulta absurda ("un plato de espagueti" sobre paisajes) | ≤ 0,099 |

Esto importa: sin un piso absoluto, el ranking relativo reporta felizmente "100%"
para la mejor de nueve malas coincidencias. Los números viven en
`MobileCLIPVariant`, no en el motor de búsqueda, porque son una propiedad del
modelo. Ver [ADR 5](decisions/0005-fusion-over-one-big-model.md).

## Lo que verifiqué y sí coincidió

| Afirmación | Verificación |
|---|---|
| SQLite del sistema trae FTS5 | ✅ SQLite 3.51.0, `unicode61 remove_diacritics 2` funcionando |
| USearch tiene bindings Swift con mmap | ✅ 2.26.2 vía SPM; `view()`, `save()`, `filteredSearch()`; SIMD `neon, neonhalf, neonsdot, neonfhm` |
| `SpeechAnalyzer` da timestamps on-device | ✅ `attributeOptions: [.audioTimeRange, .transcriptionConfidence]` y `SpeechAnalyzer.Options(priority: .background)` |
| El modelo de voz lo administra el sistema | ✅ `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`, `reserve(locale:)` |
| Español está soportado | ✅ 30 locales soportados; `es_ES`, `es_MX`, `es_CL`, `es_US` instalados en esta máquina |
| Vision tiene API Swift moderna de OCR | ✅ `RecognizeTextRequest.perform(on: CGImage)` |
| Foundation Models permite salida estructurada | ✅ `@Generable` + `@Guide`, disponible en este Mac |
| Core ML puede excluir la GPU | ✅ `MLComputeUnits.cpuAndNeuralEngine` |
| Transcribir no ocupa la máquina todo el video | ✅ 12 s de audio transcritos en 0,2 s (~60× realtime) en M4 |

## Proyectos estudiados

| Proyecto | Lo que aportó | Por qué no se usa tal cual |
|---|---|---|
| **Media Search Agent** (MIT) | La mejor especificación ejecutable: shots, keyframes, momentos, SQLite, ADRs | Python + FastAPI + React + Tauri + Qdrant; pre-1.0 |
| **MaterialSearch** | Demuestra que buscar es baratísimo con embeddings precalculados | GPL/LGPL; parte de la API no está publicada |
| **Fennec Search** (MIT) | Fusión CLIP + Whisper + escenas + transcripts | Docker + PostgreSQL + pgvector + ~10 GB |
| **CLIP-Finder2** | La ruta Swift → Core ML → MobileCLIP → ANE | iOS y fotos, no gestión de video |
| **PrivateLens** | Filosofía sidecar read-only y explicabilidad del match | Python/CLI, centrado en imágenes |
| **SentrySearch** | Estrategia de muestreo y chunking de video | ~6 GB de RAM solo para embeddings |

De SentrySearch la lección útil es el muestreo, no el modelo. Y su observación de
que embeddings de modelos distintos no son compatibles es la razón de que
`modelID` sea obligatorio en cada vector.

## Sobre reconocimiento facial

Deliberadamente fuera del núcleo. Implica información biométrica y posibles
obligaciones de consentimiento, y *"el chavo de playera azul"* se resuelve sin
saber quién es la persona. Añadirlo significaría otro modelo, otro índice, más
procesamiento y UX para agrupar y nombrar personas — todo para un problema que ya
está resuelto.
