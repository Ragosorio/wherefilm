# WhereFilm — Plan 2

**Precisión, personas (caras y voces) y Macs Intel.**

Fecha: 2026-09-05 · Base: `28e8e87` (v0.3.1) · Autor del análisis: sesión de
investigación sobre el repo indexado + verificación contra el SDK de macOS 26 y
fuentes públicas.

Este documento **no reemplaza** [`docs/PLAN.md`](PLAN.md) (que sigue siendo el
plan de construcción del producto v1). Lo continúa: asume todo lo que ya existe y
describe qué hay que cambiar para tres objetivos nuevos:

1. **Correr en una Mac Intel i9** sin degradarse a algo inservible.
2. **Ser más preciso** — hoy devuelve cosas correctas, pero no las *suficientes*
   ni en el orden correcto.
3. **Saber quién es quién** — que "Jorge Álvarez" sea una entidad del sistema, en
   fotos y en video, con el minuto exacto, y que el sistema **aprenda** de las
   correcciones y del uso.

Cada afirmación de este documento está marcada con su nivel de evidencia:

| Marca | Significa |
|---|---|
| ✅ **verificado** | Comprobado en esta máquina contra el SDK instalado o el código del repo |
| 📄 **documentado** | Afirmado por documentación o publicación pública citada abajo |
| 🔬 **por medir** | Hipótesis razonable que **debe** medirse antes de construir sobre ella |

---

## Índice

- [0. Cómo funciona hoy, de verdad](#0-cómo-funciona-hoy-de-verdad)
- [1. Diagnóstico: dónde se pierde precisión hoy](#1-diagnóstico-dónde-se-pierde-precisión-hoy)
- [2. Objetivo A — Mac Intel i9](#2-objetivo-a--mac-intel-i9)
- [3. Objetivo B — Precisión](#3-objetivo-b--precisión)
- [4. Objetivo C — Personas: caras, voces y "apareció en el minuto X"](#4-objetivo-c--personas-caras-voces-y-apareció-en-el-minuto-x)
- [5. Objetivo D — Escala: muchos discos, sin castigar la máquina](#5-objetivo-d--escala-muchos-discos-sin-castigar-la-máquina)
- [6. Objetivo E — Que aprenda de ti](#6-objetivo-e--que-aprenda-de-ti)
- [7. Esquema de base de datos: migraciones v5 → v11](#7-esquema-de-base-de-datos-migraciones-v5--v11)
- [8. Fases, entregables y criterios de aceptación](#8-fases-entregables-y-criterios-de-aceptación)
- [9. Licencias, privacidad y decisiones que hay que documentar](#9-licencias-privacidad-y-decisiones-que-hay-que-documentar)
- [10. Tu lista de técnicas: qué adoptar, qué adaptar, qué descartar](#10-tu-lista-de-técnicas-qué-adoptar-qué-adaptar-qué-descartar)
- [11. Referencias](#11-referencias)

---

## 0. Cómo funciona hoy, de verdad

Mapa del código real, no del plan. 1.527 nodos y 5.052 aristas en el grafo del
proyecto; 43 archivos Swift; ~11.5k líneas.

### 0.1 El flujo completo

```
                    ┌─────────────── INDEXADO (caro, una vez) ───────────────┐

 carpeta/disco  →  LibraryScanner  →  ContentKey (quick-id)  →  assets+locations
                                                                     │
                                                              jobs (cola SQLite)
                                                                     │
      ┌──────────────┬───────────────────────┬─────────────────┬─────┘
      ↓              ↓                       ↓                 ↓
  .metadata      .visual                  .ocr            .transcribe
  MediaProbe     KeyframeSampler          TextRecognizer   Transcriber
  (AVAsset)      dHash → momentos         Vision           SpeechAnalyzer
                 MobileCLIP-S0 (Core ML)  .accurate        + timestamps
                 → embeddings int8        → ocr_texts      → transcript_chunks
                 → USearch HNSW           → FTS5           → FTS5
                 → previews (LRU)

  Guardias: VisionGate (Vision ≤2, Core ML en exclusiva) · WorkBudget (frames
  vivos) · DecodeGate (decodes full-res) · ResourceGovernor (térmico, batería,
  Resolve al frente, pausa manual)

                    └───────────────────────────────────────────────────────┘

                    ┌─────────────── BÚSQUEDA (baratísima) ─────────────────┐

  frase  →  QueryPlanner  →  SearchPlan{visualPhrases[], spokenTerms[],
            (FoundationModels → léxico es→en → literal)   literalTerms[], …}
                                    │
                 ┌──────────────────┼──────────────────┐
                 ↓                  ↓                  ↓
          CLIP text enc.       FTS5 transcript     FTS5 ocr+metadata
          → USearch HNSW       (bm25)              (bm25)
                 │                  │                  │
                 └────────── fuse() ventana 30 s ──────┘
                                    ↓
                  score = 0.45·v + 0.35·t + 0.12·ocr + 0.08·meta
                          + agreementBonus
                                    ↓
                          build() → SearchResult[]

                    └───────────────────────────────────────────────────────┘
```

### 0.2 Piezas y su archivo

| Pieza | Archivo | Qué hace |
|---|---|---|
| Identidad | [`ContentKey.swift`](../Sources/WhereFilmCore/Identity/ContentKey.swift) | quick-id: tamaño ‖ duración ‖ 1 MiB inicio/centro/fin |
| Volúmenes | [`VolumeRegistry.swift`](../Sources/WhereFilmCore/Identity/VolumeRegistry.swift) | UUID de volumen, nunca la ruta |
| Esquema | [`Schema.swift`](../Sources/WhereFilmCore/Database/Schema.swift) | 4 migraciones; FTS5 `unicode61 remove_diacritics 2` + `fts5vocab` |
| Almacén | [`IndexStore.swift`](../Sources/WhereFilmCore/Database/IndexStore.swift) | 965 líneas; toda la verdad |
| Visual | [`MobileCLIP.swift`](../Sources/WhereFilmML/MobileCLIP.swift) | S0 v1, 256×256 → 512d, `.cpuAndNeuralEngine` |
| ANN | [`VectorIndex.swift`](../Sources/WhereFilmML/VectorIndex.swift) | USearch HNSW, `cos`, f16, mmap; derivado y reconstruible |
| Keyframes | [`KeyframeSampler.swift`](../Sources/WhereFilmIndex/KeyframeSampler.swift) | cada 5 s, dHash 8×8, umbral Hamming 12, máx 4.000, 1024 px |
| OCR | [`TextRecognizer.swift`](../Sources/WhereFilmIndex/TextRecognizer.swift) | `RecognizeTextRequest` `.accurate` |
| Voz | [`Transcriber.swift`](../Sources/WhereFilmIndex/Transcriber.swift) | `SpeechAnalyzer` + `SpeechTranscriber`, chunks ~12 s |
| Cola | [`Indexer.swift`](../Sources/WhereFilmIndex/Indexer.swift) | actor coordinador, workers no aislados |
| Plan de consulta | [`QueryPlanner.swift`](../Sources/WhereFilmSearch/QueryPlanner.swift) | 3 niveles: FoundationModels → léxico → literal |
| Fusión | [`SearchEngine.swift`](../Sources/WhereFilmSearch/SearchEngine.swift) | 712 líneas; normalización, fusión temporal, ranking |

### 0.3 Lo que ya está bien resuelto y no hay que tocar

- **`asset ≠ location`**. Es la decisión que sostiene todo. Ninguna mejora de
  este plan la altera.
- **El índice vectorial es derivado.** Cambiar de modelo = reindexar en
  background, nunca migrar. Ya está preparado con `modelID` por vector.
- **Los guardias de concurrencia.** `VisionGate` no es una perilla: es un parche
  a un fallo de Apple. Ver [`vision-concurrency-ceiling`] en las notas del
  proyecto y el comentario largo en el archivo.
- **La honestidad de la medición.** El fixture de 9 vectores mentía por 800×.
  Todo lo que este plan proponga medir usa `bench-fixture` para latencia y
  material real para calidad. **Nunca al revés.**

---

## 1. Diagnóstico: dónde se pierde precisión hoy

Tu frase fue exacta: *"si devuelve bien las cosas pero no funciona"*. Eso
describe un motor con **buena precisión y mal recall**, más un ranking que no
sabe decir cuánto vale cada señal. Aquí está el porqué, con evidencia del código.

### 1.1 Doce defectos concretos, en orden de impacto

| # | Defecto | Evidencia | Efecto que sientes |
|---|---|---|---|
| **1** | El único modelo visual es **MobileCLIP-S0**, el más pequeño de la familia | `MobileCLIPVariant` por defecto `.s0` | "pato amarillo" falla; escenas genéricas ganan a objetos concretos |
| **2** | **No hay ningún detector de objetos ni clasificador** | no existe `ClassifyImageRequest` en el repo | todo lo concreto depende de S0 |
| **3** | `plan.mediaType` y `plan.dateRange` **se calculan y se tiran** | `SearchEngine.swift` nunca los lee ✅ | "fotos de la boda" no filtra a fotos; "marzo 2025" no filtra nada |
| **4** | Normalización **min–max dentro del result set**: un canal con un solo candidato le da 1.0 | `normalize()`: `guard span > 1e-9 else { return 1 }` ✅ | un OCR basura solitario puntúa perfecto en su canal |
| **5** | `agreementBonus` se suma **fuera del techo** usado para normalizar | `score()` vs `ceiling` en `build()` ✅ | dos señales mediocres muestran 100% |
| **6** | Piso de similitud **global y fijo** (0.14) | `MobileCLIPVariant.similarityFloor` | consultas largas o mal traducidas caen enteras bajo el piso |
| **7** | **No hay re-ranking.** Un solo pase, `channelDepth = 300`, y a fusionar | `SearchEngine.Options` | el orden lo decide el modelo más barato del sistema |
| **8** | El español depende de un **léxico de ~300 pares** cuando no hay Apple Intelligence | `Lexicon.spanishToEnglish` | "el chavo del pato en el muelle" se traduce a medias |
| **9** | OCR sin `recognitionLanguages` ni `customWords` | `TextRecognizer.Options` ✅ | nombres propios y jerga se leen mal |
| **10** | **Sin evaluación de calidad automatizada** | `Benchmarks/` sólo tiene latencia; `verify-release.sh` tiene 6 casos | ninguna mejora es demostrable |
| **11** | Muestreo de keyframes con umbral dHash fijo (12/64) sobre 9×8 grises | `KeyframeSampler.Options.changeThreshold` | plano fijo donde alguien entra en cuadro → momento perdido |
| **12** | La evidencia visual muestra `visualPhrases.first` aunque el vector sea el **promedio** del ensemble | `visualCandidates()` ✅ | la explicación no describe lo que realmente se buscó |

### 1.2 La conclusión del diagnóstico

Hay **tres arreglos gratis** (3, 4, 5) que son bugs de ranking, no rediseños.
Hay **un arreglo barato y enorme** (2: `ClassifyImageRequest` sobre los mismos
frames ya decodificados). Y hay **un rediseño necesario** (7: recuperación en
etapas con re-ranking), que es exactamente la arquitectura *coarse-to-fine* de tu
lista.

Y antes de todo eso: **(10) sin banco de evaluación, nada de esto es
demostrable.** Es la primera tarea del plan, no la última.

---

## 2. Objetivo A — Mac Intel i9

### 2.1 Qué es cierto sobre Intel hoy

| Hecho | Evidencia |
|---|---|
| **macOS 26 Tahoe es la última versión con soporte Intel**; macOS 27 ya no. | 📄 Apple + prensa |
| Los Intel soportados son 2019+: MacBook Pro 16" 2019 (el i9), MacBook Pro 13" 2020 de 4 puertos, iMac 2020, iMac Pro, Mac Pro 2019 | 📄 Apple |
| **No hay Neural Engine en Intel.** `.cpuAndNeuralEngine` significa, literalmente, *sólo CPU* | 📄 + ✅ (`MLComputeDevice.allComputeDevices` existe para comprobarlo en runtime) |
| **Apple Intelligence no existe en Intel** → `SystemLanguageModel.default.isAvailable == false` | 📄; el código ya degrada correctamente ✅ |
| El framework `FoundationModels` **sí tiene slice `x86_64`** en el SDK, así que enlazarlo no rompe el arranque | ✅ verificado en `FoundationModels.tbd` |
| `Translation.framework` **también tiene slice `x86_64`** y expone `TranslationSession(installedSource:target:)` sin SwiftUI | ✅ verificado en el `.swiftinterface` |
| `SpeechTranscriber` está construido alrededor del Neural Engine; **`SpeechTranscriber.isAvailable` es la única fuente de verdad** | 📄 + ✅ (la propiedad existe en el SDK) |
| Existe `DictationTranscriber`, documentado como **el fallback para dispositivos/idiomas no soportados**, con preset `timeIndexedLongDictation` y atributo `audioTimeRange` | ✅ verificado en el SDK |
| `Vision` permite **fijar el dispositivo de cómputo por etapa**: `setComputeDevice(_:for:)` con `ComputeStage.main/.postProcessing` | ✅ verificado |
| FluidAudio (la red de seguridad de transcripción del plan v1) se anuncia para **Apple Silicon** | 📄 — no sirve de fallback en Intel |

### 2.2 La consecuencia honesta

En una Mac Intel:

- **La búsqueda seguirá siendo rápida.** Es SQLite + HNSW + un encode de texto.
  Lo caro es indexar, y eso ya se paga una sola vez.
- **Indexar será mucho más lento.** Sin ANE, MobileCLIP corre en CPU o GPU. La
  magnitud exacta 🔬 **hay que medirla**; no voy a citar el número de un blog.
- **La transcripción probablemente cambie de motor** (a `DictationTranscriber`),
  con otra calidad y otro juego de idiomas.
- **El planificador de consultas pierde el nivel 1** (Apple Intelligence) y pasa
  a depender de `Translation` + léxico. Esto es un argumento *fuerte* a favor de
  la mejora 3.2 de este plan, que beneficia a las dos plataformas.

Eso no es un fracaso: es exactamente el diseño en niveles con degradación limpia
que ya tiene el producto. Lo que falta es **hacerlo explícito y medible**.

### 2.3 Trabajo A1 — `MachineProfile`: una sola pieza que sabe en qué máquina corre

Nuevo archivo `Sources/WhereFilmCore/Support/MachineProfile.swift`.

```swift
public struct MachineProfile: Sendable {
    public enum Silicon: String, Sendable { case appleSilicon, intel }

    public let silicon: Silicon              // #if arch(x86_64) + sysctl hw.optional.arm64
    public let cores: Int                    // activeProcessorCount
    public let performanceCores: Int         // sysctl hw.perflevel0.logicalcpu
    public let memoryGB: Double              // physicalMemory
    public let hasNeuralEngine: Bool         // MLComputeDevice.allComputeDevices contiene .neuralEngine ✅
    public let gpuDevices: [String]          // .gpu(...) de la misma lista
    public let isTranslated: Bool            // sysctl sysctl.proc_translated (Rosetta)

    public static let current: MachineProfile
}
```

Todo lo demás del sistema **consulta esta pieza** en vez de asumir. Es la misma
filosofía que `VectorEngineInfo`: preguntar al hardware, no adivinar.

`wherefilm doctor` gana una sección:

```
Machine
  Apple Silicon: no (x86_64, not translated)
  Cores: 16 (8 performance)     Memory: 32 GB
  Neural Engine: absent
  GPU: AMD Radeon Pro 5500M
  Core ML plan: cpuAndGPU when idle, cpuOnly with an editor open
  Speech: SpeechTranscriber unavailable → DictationTranscriber (es-MX installed)
  Foundation Models: unavailable — this Mac does not support Apple Intelligence
  Translation: es → en available (installed)
  USearch acceleration: avx2, avx512  ← lo que reporte la librería en x86
```

### 2.4 Trabajo A2 — Política de cómputo por máquina

Hoy hay un único valor quemado: `.cpuAndNeuralEngine` en dos inicializadores de
[`MobileCLIP.swift`](../Sources/WhereFilmML/MobileCLIP.swift). Se sustituye por
una política:

```swift
enum ComputePolicy {
    static func forImageEncoding(_ p: MachineProfile,
                                 editorRunning: Bool) -> MLComputeUnits {
        guard !p.hasNeuralEngine else { return .cpuAndNeuralEngine }   // sin cambio en ARM
        // Intel: no hay ANE. La GPU es el único acelerador — y es justo la que
        // Resolve castiga. Así que la GPU se usa sólo cuando nadie más la quiere.
        return editorRunning ? .cpuOnly : .cpuAndGPU
    }
}
```

Detalles que importan:

- `computeUnits` **se fija al cargar el modelo**. Cambiar de política implica
  soltar y recargar el encoder — el diseño de "workers desechables" ya lo hace
  gratis (`releaseModelsIfIdle`).
- La política se consulta **en el mismo lugar que el governor**, para que
  "Resolve al frente" ya no sólo baje concurrencia sino también saque a
  WhereFilm de la GPU.
- Vision recibe el mismo trato con `setComputeDevice(_:for: .main)` ✅ — hoy no
  se usa en absoluto, y en Intel es la diferencia entre OCR en CPU y OCR en GPU.

🔬 **Medir antes de fijar los valores:** 40 keyframes reales de 1024 px, mismo
archivo, en Intel: `cpuOnly` vs `cpuAndGPU` vs `.all`, para MobileCLIP y para
`RecognizeTextRequest` por separado. La tabla resultante va a `docs/`.

### 2.5 Trabajo A3 — Recalibrar los guardias para Intel

Los tres guardias derivan sus límites de `activeProcessorCount`, que en un i9 de
8 núcleos/16 hilos da números pensados para otra máquina.

| Guardia | Hoy | En Intel |
|---|---|---|
| `VisionGate.crashCeiling` | 2 (medido en M4) | 🔬 **re-medir**. El fallo está en TextRecognition; su comportamiento en x86 es una incógnita, y bajarlo a 1 puede ser lo correcto |
| `WorkBudget.recommendedCapacity` | `cores × 2`, 12–32 | escalar por **memoria**, no sólo por núcleos: un MBP 2019 de 16 GB con Resolve abierto no tiene el mismo aire que un M4 |
| `DecodeGate.recommendedLimit` | `cores / 3`, 2–4 | igual, más el hecho de que en Intel el decode compite con el encode por la misma CPU |
| `ResourceGovernor.maxConcurrency` | `min(12, cores)` | los i9 de 2019 **throttlean muy temprano**; `.serious` debe llegar antes y bajar más |

Añadir además una señal que hoy no existe: en Intel, `thermalState` es mucho más
informativa y debería **modular la concurrencia de forma continua**, no sólo en
dos escalones.

### 2.6 Trabajo A4 — La cadena de transcripción, explícita

Refactor de [`Transcriber.swift`](../Sources/WhereFilmIndex/Transcriber.swift) a
un protocolo con tres implementaciones y selección en runtime:

```
SpeechTranscriber            si SpeechTranscriber.isAvailable && locale soportado
  ↓ si no
DictationTranscriber         preset .timeIndexedLongDictation,
  ↓ si no                    attributeOptions [.audioTimeRange, .transcriptionConfidence]
SFSpeechRecognizer           requiresOnDeviceRecognition = true (red de seguridad)
  ↓ si no
(sin transcripción)          y el índice lo dice, no lo esconde
```

Los tres producen `[TranscriptSegment]`, así que **nada aguas abajo cambia**. Se
guarda además `transcript_chunks.engine` para que una biblioteca transcrita con
el motor pobre pueda re-transcribirse cuando la máquina mejore, igual que los
embeddings con `modelID`.

### 2.7 Trabajo A5 — Verificación real en x86, hoy, sin comprar una Mac

Se puede probar **casi todo** desde el M4:

```bash
# 1. compilar sólo la slice x86_64
WHEREFILM_ARCHS="x86_64" ./Scripts/make-app.sh

# 2. ejecutar el CLI x86 bajo Rosetta 2
arch -x86_64 .build-x86_64/x86_64-apple-macosx/release/wherefilm doctor
arch -x86_64 … scan /tmp/testlib --index
arch -x86_64 … search "atardecer en la playa" --explain
```

Qué prueba y qué no:

- ✅ **Prueba**: que la slice x86 arranca, enlaza `FoundationModels`, `Speech`,
  `Translation` y `Vision` sin morir; que USearch funciona; que las rutas de
  degradación (sin Apple Intelligence, sin ANE) se toman de verdad.
- ❌ **No prueba**: rendimiento. Rosetta traduce, y su soporte de instrucciones
  SIMD anchas es limitado 🔬 — un número de velocidad bajo Rosetta no dice nada
  de un i9 nativo.

`Scripts/verify-release.sh` gana un modo `--arch x86_64` que corre los seis casos
bajo Rosetta. Es la única forma de que un cambio no rompa Intel en silencio.

### 2.8 Trabajo A6 — Empaquetado seguro para máquinas ajenas

Hoy `make-app.sh` copia `.mlmodelc` **ya compilado en la máquina de desarrollo**.
El propio código documenta que eso falla en otras Macs ("ANE model load has
failed… Must re-compile the E5 bundle") y por eso existe el fallback a `cpuOnly`.
En Intel ese fallback se volvería la ruta normal, no la excepción.

Cambio: **empaquetar el `.mlpackage`** y compilarlo en el primer arranque hacia
`~/Library/Application Support/WhereFilm/Models`, guardando el resultado. Coste:
unos segundos una vez, en la máquina correcta, con la arquitectura correcta.
Beneficio: el modelo se compila *para esa Mac*, que es lo que Core ML quiere.

---

## 3. Objetivo B — Precisión

Cinco frentes, en orden estricto de dependencia. **El primero no es opcional.**

### 3.1 B0 — Un banco de evaluación, antes que nada

Sin esto, cada mejora siguiente es una opinión.

**Entregable:** `wherefilm eval --set Benchmarks/quality-v1.json`

```jsonc
{
  "version": 1,
  "library": "manu-real-2026-09",     // hash del índice contra el que es válido
  "queries": [
    {
      "id": "q001",
      "text": "el chavo de playera azul que habló del presupuesto",
      "lang": "es",
      "relevant": [                    // momentos, no archivos
        { "asset": "INTERVIEW_JUAN_03.MOV", "at": 854, "grade": 3 },
        { "asset": "INTERVIEW_JUAN_03.MOV", "at": 1180, "grade": 1 }
      ]
    },
    {
      "id": "q044",
      "text": "un plato de espagueti",
      "lang": "es",
      "relevant": [],                  // NEGATIVO: cero es la respuesta correcta
      "expect": "empty"
    }
  ]
}
```

**Métricas que reporta:** Recall@10, Recall@50, MRR, nDCG@10, y dos que importan
más que las anteriores en este producto:

- **Tasa de falsos positivos en negativos** — cuántas consultas absurdas
  devuelven algo. Ya hay filosofía de esto en `verify-release.sh`; aquí se mide.
- **Calibración**: ¿el 94% que muestra la interfaz corresponde a resultados
  buenos el 94% de las veces? Un gráfico de confiabilidad, no un número.

**Tamaño mínimo útil:** 120–150 consultas sobre material real de Manu, mitad
español mitad inglés, cubriendo: escena, objeto concreto, texto en pantalla,
diálogo, nombre de persona, fecha, tipo de medio, y ~20 negativos.

**Coste:** una tarde de etiquetado, y es la inversión de mayor retorno del plan
completo. Todo lo que sigue se reporta como *delta contra esta línea base*.

> Recordatorio del proyecto: la calidad **jamás** se mide con `bench-fixture`.
> Ese fixture sintetiza vectores a distancia coseno elegida; sirve para latencia,
> memoria y escalado, y para nada más.

### 3.2 B1 — Entender la consulta (el arreglo más barato)

#### a) `Translation.framework` como nivel 2 real

✅ Verificado en el SDK: `TranslationSession(installedSource:target:)` existe
fuera de SwiftUI, y `LanguageAvailability.status(from:to:)` dice si el par está
instalado. Esto sustituye al léxico de 300 palabras por el traductor del sistema,
offline, gratis, y **disponible también en Intel**.

Nueva jerarquía del `QueryPlanner`:

```
1. Foundation Models        (Apple Silicon con Apple Intelligence)
     descompone en {visual_en, spoken_es, filtros} — ya existe
2. Translation framework    (NUEVO — Apple Silicon e Intel)
     traduce sólo la mitad visual; la hablada nunca se traduce
3. Léxico de dominio        (siempre — ahora como *override*, no como traductor)
     "plano cerrado" → "close-up shot" gana sobre lo que diga el traductor
4. Literal
```

El léxico no se borra: se convierte en un **diccionario de jerga audiovisual**
que corrige al traductor general, que es donde un traductor general falla.

#### b) Prompt ensembling estilo CLIP

📄 Documentado: envolver la clase en plantillas ("a photo of a {}", "a photo of
the {}", …) y promediar los embeddings de texto mejora zero-shot de forma
consistente (~+3,5% con 80 plantillas en ImageNet; ~+5% con ingeniería de
prompt). No es universal — hay datasets donde la plantilla resta.

Ya existe la infraestructura: `MobileCLIPTextEncoder.encodeEnsemble(_:)`. Falta
que el planner genere el ensemble:

```
"pato amarillo nadando"
  → "a photo of a yellow duck swimming"
  → "a video frame of a yellow duck swimming"
  → "yellow duck swimming"
```

🔬 Medir con B0 y **quedarse con el conjunto que gane**, no con el que suene
bien. Coste: ~3 encodes de texto por consulta (milisegundos, y cacheados en
`QueryEmbeddingCache`).

#### c) Aplicar los filtros que ya se calculan

Bug #3 del diagnóstico. `plan.mediaType` y `plan.dateRange` existen y se
descartan. Se aplican como **filtro duro previo** (SQL en `assets`) y, en el
canal visual, con el `filteredSearch` que USearch ya expone — mencionado en
`docs/PLAN.md` §1 como verificado y hoy sin usar.

Añadir además al planner, con `NSDataDetector` y reglas:

- fechas relativas: "el año pasado", "en marzo", "hace dos semanas"
- duración: "clips cortos", "las tomas largas"
- volumen: "en el Samsung T7"
- tipo: "fotos", "videos", "audios"

#### d) Nombres y typos: tokenizador trigram

✅ Verificado en esta máquina: SQLite 3.51.0 soporta `tokenize='trigram'` y
`unicode61 remove_diacritics 2` encuentra "Álvarez" buscando "alvarez".

Se añade una **segunda tabla FTS5 con tokenizador trigram** sólo para nombres
propios y códigos (personas, marcas, claquetas). Resuelve "Jorge Alvares" →
"Jorge Álvarez" sin ningún modelo, y es lo que hace que el bug de dedo no cueste
una búsqueda fallida.

⚠️ Nota: SQLite del sistema **no permite `load_extension`** ✅ verificado — así
que `spellfix1` y `sqlite-vec` quedan descartados como extensiones cargables. El
trigram es la vía nativa.

### 3.3 B2 — Más señales sobre los mismos píxeles (el arreglo de mayor recall)

El keyframe ya está decodificado a 1024 px, ya pasó por Core ML y por Vision. Los
siguientes análisis son casi gratis en I/O — su coste es sólo cómputo, y entra
por el mismo `VisionGate`.

| Señal nueva | API | Coste | Qué desbloquea |
|---|---|---|---|
| **Clasificación de escena/objeto** | `ClassifyImageRequest` ✅ (`supportedIdentifiers` da la taxonomía completa) | bajo | "pato", "micrófono", "perro", "playa" como **texto indexado**, no como vector |
| **Documentos estructurados** | `RecognizeDocumentsRequest` ✅ (con `customWords`, `recognitionLanguages`) | medio | cotizaciones, tablas, actas — hoy salen como sopa de líneas |
| **Huella visual de Apple** | `GenerateImageFeaturePrintRequest` ✅ + `distance(to:)` | muy bajo | near-duplicates, colapso de resultados, y **re-ranking barato** |
| **Personas en cuadro** | `DetectHumanRectanglesRequest` ✅ | bajo | "hay gente" / "está solo"; recorte para Re-ID |
| **Caras** | `DetectFaceRectanglesRequest` + `DetectFaceCaptureQualityRequest` ✅ | bajo | base del objetivo C |
| **Códigos** | `DetectBarcodesRequest` ✅ | muy bajo | QR y códigos de claqueta |
| **Estética** | `CalculateImageAestheticsScoresRequest` ✅ | bajo | elegir **buen** póster, no el primer frame |

**El más importante es el primero.** `ClassifyImageRequest` convierte objetos
concretos en filas de FTS5 con puntaje, que es justo donde S0 es débil. Y como es
texto, el traductor del punto 3.2a lo hace funcionar en español sin tocar el
modelo visual.

Diseño: una tabla `labels(momentID, identifier, confidence)` + filas en
`search_index` con `kind = 'label'`, con un umbral de confianza y un tope de
etiquetas por frame (🔬 medir: probablemente top-5 sobre 0.3).

**Coste real a vigilar:** cada request nuevo pasa por `VisionGate`, cuyo techo es
2 por el fallo de TextRecognition. Añadir cuatro análisis por frame **multiplica
el tiempo de indexado** si se hacen en serie dentro del mismo cupo. Por eso el
punto 5.2 (OCR y compañía fuera de proceso) deja de ser "el siguiente paso" y
pasa a ser **prerrequisito** de esta sección.

### 3.4 B3 — Recuperación en etapas (coarse-to-fine)

Esta es la arquitectura de tu lista, aterrizada a esta biblioteca. Hoy hay un
solo pase; la propuesta son cuatro:

```
  ~5.000.000 momentos              biblioteca de Manu, ilustrativo
        │
        │  1) ROUTING            filtros duros: tipo, fecha, volumen, persona
        ↓                        (SQL + USearch filteredSearch)
    ~800.000
        │
        │  2) CANDIDATOS         ANN visual (S0) top-800
        ↓                        + FTS5 bm25 por canal top-800
     ~2.000
        │
        │  3) FUSIÓN             RRF ponderado + acuerdo temporal
        ↓                        (reemplaza min–max — ver 3.5)
       ~100
        │
        │  4) RE-RANKING         modelo fuerte sobre los previews ya cacheados
        ↓                        (S2 / SigLIP2 / feature print) — sólo 100 imágenes
        20
        │
        │  5) VERIFICACIÓN       el momento existe, el archivo se puede abrir,
        ↓                        el timecode cae dentro de la duración
     resultados
```

**Por qué esto sí cabe aquí:** el paso 4 es el caro, y sólo toca ~100 imágenes
que **ya están en la caché de previews**. No hay que volver a abrir el video ni
volver a decodificar. Un re-rank de 100 miniaturas con S2 son unos cientos de
milisegundos en ARM 🔬, y es exactamente donde el usuario está dispuesto a
esperar: después de ver los primeros resultados.

Encaja con `searchProgressively` tal como está: hoy emite `.fast` (texto) y
`.refined` (visual). Pasaría a emitir `.fast` → `.refined` → **`.reranked`**.

### 3.5 B4 — Arreglar el ranking

#### a) RRF en vez de min–max

📄 Reciprocal Rank Fusion (Cormack, Clarke, Büttcher, SIGIR 2009): la posición
importa, el puntaje crudo no.

```
score(d) = Σ_canales  w_c / (k + rank_c(d))          k ≈ 60
```

Ventajas para este caso concreto:

- **Elimina el bug #4**: un canal con un solo candidato ya no regala 1.0; regala
  `w/(k+1)`, que es poco.
- **No requiere que bm25 y coseno sean comparables** — que es justamente lo que
  hoy se intenta arreglar a mano.
- Es una línea de código y se puede A/B contra el sistema actual con B0.

⚠️ Con un matiz importante: **el coseno visual sí es una escala absoluta**, y ese
conocimiento (piso 0.14, techo 0.26 medidos) no se debe tirar. Diseño propuesto:
RRF para ordenar, y la **calibración absoluta del canal visual como filtro de
admisión y como confianza mostrada**. Lo mejor de los dos.

#### b) Centrado por consulta (arregla el "mejor de nueve malas")

El piso fijo de 0.14 es un parche a un problema conocido de CLIP: la brecha entre
modalidades hace que la escala de similitud dependa de la consulta, no sólo del
acierto.

Arreglo barato y sin modelo nuevo: al calcular el embedding de una consulta,
comparar también contra una **muestra fija de N=2.000 vectores de la biblioteca**
(precalculada y cacheada) y restar esa media:

```
sim_centrada = cos(q, v) − media(cos(q, muestra))
```

Una consulta que "se parece a todo" (típica de las traducciones flojas) tiene una
media alta y sus resultados bajan solos. Coste: 2.000 productos punto con
Accelerate = microsegundos, una vez por consulta.

#### c) Bonus de acuerdo, acotado y dentro del techo

Bugs #5. El bonus se suma fuera del `ceiling`, así que dos señales flojas pueden
llegar a 100%. Se acota a un máximo explícito y se incluye en la normalización.
Y se exige que las señales que "concuerdan" sean de **canales distintos** (ya lo
hace en el bucketing) **y** que ambas superen su propio umbral de calidad.

#### d) Momentos, no frames

Colapsar momentos consecutivos del mismo plano con `GenerateImageFeaturePrint`
antes de mostrar. Hoy `suppressDuplicates` limita a 3 por asset — es un techo,
no una agrupación. La diferencia se nota en un videoclip con cortes rápidos.

### 3.6 B5 — El modelo visual: qué se puede cambiar y qué cuesta

Estado del arte verificado en septiembre 2026:

| Modelo | Multilingüe | Core ML oficial | Licencia | Nota |
|---|---|---|---|---|
| **MobileCLIP-S0 v1** (hoy) | ❌ inglés | ✅ `apple/coreml-mobileclip` | apple-ascl (no comercial) | el más rápido |
| **MobileCLIP-S2 / B(LT)** | ❌ inglés | ✅ mismo repo ✅ | apple-ascl | +recall, ~2,4× coste de imagen |
| **MobileCLIP2** | ❌ inglés | ❌ **no hay export oficial** ✅ confirmado en el repo de Apple | apple-ascl | requiere conversión propia |
| **SigLIP 2** | ✅ 109 idiomas 📄 | ❌ conversión propia | Apache-2.0 (Google) | multilingüe nativo |
| **MetaCLIP 2** | ✅ 300+ idiomas, SOTA multilingüe 📄 | ❌ conversión propia | permisiva (Meta) | supera a mSigLIP y SigLIP-2 en multilingüe |

**Recomendación en dos tiempos:**

1. **Corto plazo, sin conversiones:** `S0` para indexar (barato, es lo que corre
   millones de veces) y **`S2` sólo como re-ranker** sobre los ~100 finalistas
   (paso 4 de 3.4). Los dos ya existen exportados a Core ML, en el mismo repo,
   con el mismo tokenizer. Es la ganancia más grande por el menor riesgo, y
   `modelID` ya soporta convivencia de dos modelos.

2. **Medio plazo, con conversión propia:** SigLIP 2 o MetaCLIP 2 convertidos con
   `coremltools`, detrás de la abstracción `VisualEncoder` que el plan v1 ya
   previó. Esto **elimina el problema del español en la raíz** en vez de
   traducirlo. Riesgos reales: tamaño (mucho mayor que 11 M de parámetros),
   velocidad en Intel sin ANE, y que el tokenizer ya no es el CLIP BPE que
   `CLIPTokenizer.swift` implementa (SigLIP usa SentencePiece).

🔬 **La decisión se toma con B0**, comparando en el mismo dataset: S0, S0+S2
re-rank, y SigLIP2 si la conversión funciona.

### 3.7 B6 — Cuantización y escala del índice

Hoy: int8 en SQLite (con escala) y f16 dentro de USearch. Para 5 M de momentos
eso está bien 📄 (int8 con re-scoring conserva ~99% del rendimiento con un
multiplicador de re-score de 4–5).

Lo que sí conviene añadir cuando la biblioteca crezca: **búsqueda binaria +
re-scoring**. Primero una pasada con vectores de 1 bit (64 bytes por vector),
luego re-puntuar los top-K con los int8 reales. Es la misma idea de
coarse-to-fine, aplicada al vector.

No es urgente: la medición del `SCALE-PASS` dice que **HNSW responde en 1,6–1,8 ms
sobre 208.801 vectores y que el costo está en FTS5**, no en el ANN. Primero se
optimiza donde duele.

---

## 4. Objetivo C — Personas: caras, voces y "apareció en el minuto X"

Esto es una **reversión explícita** de una decisión del plan v1
([`PLAN.md` §7](PLAN.md), `RESEARCH-NOTES.md`), que dejó el reconocimiento facial
deliberadamente fuera del núcleo. Merece un ADR nuevo (§9), no un cambio
silencioso.

### 4.1 La cadena completa

```
 FRAME (1024 px, ya decodificado, ya en el gate)
   │
   ├─ DetectFaceRectanglesRequest ✅          ¿hay caras? ¿dónde?
   │        ↓
   ├─ DetectFaceCaptureQualityRequest ✅      ¿vale la pena esta cara?
   │        ↓  (descartar borrosas, muy pequeñas, muy de perfil)
   ├─ DetectFaceLandmarksRequest ✅           alinear (ojos horizontales, 112×112)
   │        ↓
   ├─ FaceEmbedder (Core ML propio)           → vector 512d por cara
   │        ↓
   ├─ faces(faceID, momentID, assetID, bbox, quality, vector)
   │        ↓
   ├─ USearch índice aparte: faces-<model>.usearch
   │        ↓
   ├─ CLUSTERING incremental                  cara → ¿centroide conocido?
   │        ↓                                  sí → person_id ; no → nuevo cluster
   ├─ people(personID, displayName?, isNamed, centroid, faceCount)
   │        ↓
   └─ person_appearances(personID, assetID, startS, endS, confidence)
                                              ↑ esto es "apareció en el minuto X"
```

### 4.2 El modelo de caras

Vision **detecta** caras pero **no expone un embedding de identidad** ✅
verificado: la lista completa de requests de macOS 26 no incluye ninguno que
devuelva un *faceprint*. Hay que traer un modelo.

| Candidato | Tamaño | Precisión | Licencia | Veredicto |
|---|---|---|---|---|
| **EdgeFace-XS/S** (Idiap) | **1,77 M parámetros** | LFW 99,73%, IJB-C 94,85% 📄 | **CC BY-NC-SA 4.0** | ✅ **recomendado**: diminuto, corre bien incluso sin ANE, y su licencia no comercial *coincide* con la que ya tiene MobileCLIP en esta edición |
| InsightFace / ArcFace `buffalo_l` | ~100 MB | mejor | modelos **no comerciales**, licencia empresarial aparte | alternativa si hace falta más precisión |
| FaceNet | medio | menor | código MIT, pesos ambiguos | no aporta sobre EdgeFace |

⚠️ **Consecuencia de licencia, dicha claramente:** WhereFilm ya es una "vista
previa experimental no comercial" por MobileCLIP (apple-ascl). EdgeFace
(CC BY-NC-SA) **no empeora esa situación**, pero sí la fija: si algún día quieres
vender o integrar comercialmente, hay que cambiar **los dos** modelos. Está en el
mismo cajón, no en uno nuevo.

### 4.3 Clustering: cómo se agrupa sin saber nombres

Dos niveles, igual que el resto del sistema:

**Online (durante el indexado, barato).** Cada cara nueva se compara contra los
centroides existentes en el índice de caras. Si `cos ≥ 0.62` 🔬 → se une al
cluster y actualiza el centroide incrementalmente. Si no → cluster nuevo. Es O(1)
amortizado con HNSW y no bloquea nada.

**Offline (pase de consolidación, en idle).** El online produce clusters
fragmentados: la misma persona con gorra, de perfil, en otra iluminación. Un pase
periódico corre un clustering de grafo sobre los centroides —**Chinese Whispers**
es la recomendación clásica para esto porque es lineal en el tiempo 📄, y es lo
que dlib usa para exactamente este problema— y **fusiona** clusters. Se ejecuta
como un `JobTask` nuevo, con QoS background, gobernado igual que todo lo demás.

**Regla de oro:** el pase offline **nunca deshace un nombre puesto por el
usuario**. Si dos clusters nombrados distinto se parecen, no se fusionan: se
marca la ambigüedad y se pregunta.

### 4.4 De cluster a "Jorge Álvarez"

La UI mínima que hace que esto sea un producto y no una demo:

```
 Personas                                        124 sin nombre

  ┌────┐  ┌────┐  ┌────┐            ┌────┐
  │ 😐 │  │ 😐 │  │ 😐 │            │ 🙂 │  Jorge Álvarez
  └────┘  └────┘  └────┘            └────┘  312 momentos · 47 archivos
   87      54      31                       ▸ ver apariciones
  ¿Quién es?  ────────────────────

  [ Jorge Álvarez            ]  ⏎          ← autocompletar sobre nombres ya usados
```

Y tres acciones que la gente **va a necesitar**, así que se diseñan desde el
principio:

- **Fusionar** dos personas ("este también es Jorge").
- **Separar** ("estas 12 caras no son él") — mueve esas caras a un cluster nuevo
  y las marca como *no reagrupables* con el original.
- **Ignorar** ("esto no es una cara" / "es un extra irrelevante").

Cada corrección se guarda en `people_feedback` y **alimenta el objetivo E**:
umbral de cluster ajustado con las correcciones reales del usuario, no con un
número quemado.

### 4.5 Video: apariciones con timecode

El muestreo actual (cada 5 s, con supresión por dHash) es **demasiado grueso para
personas**. Una persona puede aparecer 3 segundos y desaparecer.

Diseño:

1. **Muestreo denso condicional.** En el pase visual, si un keyframe tiene caras,
   se marca el intervalo como "interesante" y se muestrean frames adicionales
   dentro de él (cada 1 s) **sólo para caras** — sin embeddings CLIP, sin OCR.
   Coste: un decode más y un detector barato.
2. **Seguimiento entre muestras.** `TrackObjectRequest` ✅ existe en macOS 26 y
   permite propagar una caja entre frames sin volver a detectar. Convierte
   detecciones sueltas en **tracks**.
3. **Intervalos, no puntos.** Un track de la misma persona se guarda como
   `person_appearances(personID, assetID, 852.0, 871.4, 0.91)`.

Resultado en la interfaz:

```
Jorge Álvarez  ·  ENTREVISTA_JUAN_03.MOV
   14:12 – 14:31   ██████                  92%
   22:04 – 22:09   ██                      78%
   41:55 – 43:10   ████████████            95%   ← habla aquí (voz confirmada)
```

### 4.6 Voces: quién habla, no sólo qué se dijo

Complemento natural, y lo que convierte "Jorge aparece" en "Jorge **dice**".

- **Diarización + embeddings de hablante** con FluidAudio (SDK Apache-2.0;
  modelo pyannote CC-BY-4.0 📄). Produce segmentos `[inicio, fin, hablante_N]`.
- Los `hablante_N` se clusterizan igual que las caras → `voices` / `voice_prints`.
- **El puente:** cuando un cluster de voz y un cluster de cara **coinciden en el
  tiempo repetidamente** en varios archivos, se propone el enlace. Nombrar la
  cara nombra la voz, y viceversa. Eso es lo que permite responder *"¿dónde habla
  Jorge?"* aunque esté fuera de cuadro.
- ⚠️ **En Intel:** FluidAudio se anuncia para Apple Silicon 📄. En una Mac Intel
  esta capa probablemente no exista; el sistema debe decirlo, no fingir.

### 4.7 Re-identificación por cuerpo (opcional, nivel D)

Cuando la cara no se ve — de espaldas, muy lejos, con casco. `GeneratePersonInstanceMaskRequest`
y `DetectHumanRectanglesRequest` ✅ dan el recorte; un modelo de Re-ID (OSNet y
similares) da el vector. Es útil **dentro del mismo archivo o la misma sesión de
grabación** (la ropa no cambia), y muy poco fiable entre días distintos.

**Recomendación: dejarlo fuera del alcance inicial.** Alto coste, beneficio
estrecho, y compite por el mismo cupo de Vision que ya es el cuello de botella.
Se anota como Nivel D, no como fase.

---

## 5. Objetivo D — Escala: muchos discos, sin castigar la máquina

### 5.1 Índices por volumen (sharding), con un índice global

Hoy hay **un** `index.sqlite` y **un** `.usearch` globales. Para 20 discos eso
significa que conectar un disco nuevo es un evento en el índice de todos.

Diseño propuesto, alineado con `asset ≠ location`:

```
~/Library/Application Support/WhereFilm/
    index.sqlite                 ← catálogo GLOBAL: assets, personas, jobs
    Vectors/
        global.usearch           ← índice caliente: discos conectados
        shards/
            <volumeUUID>.usearch ← un grafo por volumen
            <volumeUUID>.bloom   ← filtro Bloom de términos del volumen
```

Y, opcionalmente, el **sidecar por disco** que el plan v1 ya contempla
(`.wfindex`): un disco indexado en la Mac de Manu llega ya indexado a otra Mac.
Es la idea de los `.prmi` de Adobe, y es lo que evita reprocesar 30 TB dos veces.

**Enrutamiento de consulta:** el filtro Bloom responde *"¿puede existir este
término aquí?"* en microsegundos. Un disco cuyo Bloom dice **no** se salta
entero. Es el `search-space pruning` de tu lista, y encaja porque los discos
desconectados **ya** tienen que responder desde el índice.

⚠️ **Con honestidad:** con 208.801 momentos el ANN ya responde en 1,6 ms. El
sharding **no es una optimización de velocidad hoy** — es de gestión: poder
desconectar un disco y que su parte del índice se pueda archivar, mover o
reconstruir sin tocar el resto. Y es la única forma de que el sidecar funcione.

### 5.2 Sacar Vision del proceso principal (prerrequisito de todo B2)

El README ya lo identifica como *"el siguiente paso real"*, y las notas del
proyecto lo confirman: el techo de indexado no es el código propio, es que
`RecognizeTextRequest` corrompe memoria arriba de ~3 peticiones concurrentes ✅.

```
 WhereFilm.app                        proceso principal, siempre vivo
   │  XPC                             SQLite, búsqueda, UI, governor
   ├──► wherefilm-vision-helper #1    Vision a profundidad 2 · muere y renace
   ├──► wherefilm-vision-helper #2
   └──► wherefilm-vision-helper #3    (N = f(núcleos, memoria, MachineProfile))
```

Dos ganancias, no una:

1. **Rendimiento**: tres ayudantes a profundidad 2 son 6 peticiones concurrentes
   totales, contra las 2 de hoy. Vision escala 4,6× hasta profundidad 8 ✅ medido;
   este es el camino para cobrarlo sin el segfault.
2. **Contención del fallo**: si Apple revienta, muere un ayudante de 30 MB y el
   trabajo se reintenta. Hoy muere la aplicación entera, y con ella el indexado
   de la noche.

Y es **lo que hace viable** añadir clasificación, documentos y caras (§3.3, §4):
sin esto, cada análisis nuevo compite por los mismos 2 cupos.

### 5.3 Ser aún mejor vecino

Añadidos concretos al `ResourceGovernor`:

- **Prioridad de E/S**: `setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)`
  en los workers de indexado. Hoy el governor cuida CPU y acelerador, pero un
  escaneo de 30 TB también castiga el disco que Resolve está leyendo.
- **Fijar dispositivo de cómputo en Vision** con `setComputeDevice` ✅, para sacar
  el OCR de la GPU cuando hay un editor abierto (crítico en Intel, donde la GPU
  es el único acelerador).
- **Presupuesto de tiempo, no sólo de recursos**: "indexar sólo entre 11 pm y
  7 am" es una opción que la gente con archivos grandes realmente quiere.

---

## 6. Objetivo E — Que aprenda de ti

Dos cosas distintas se esconden en "que aprenda de ti", y ambas valen:

### 6.1 Aprender identidades (ya cubierto en §4)

Nombrar una cara, fusionar dos clusters, separar una equivocación. Eso es
conocimiento que **sólo tú tienes** y que el sistema no puede derivar solo. Se
guarda en `people` y `people_feedback` y **jamás se sobrescribe** por un pase
automático.

### 6.2 Aprender qué resultados sirven

Señales que la app puede recoger localmente **sin ningún servidor**:

| Señal | Qué significa | Peso |
|---|---|---|
| Abrir un resultado | relevante | fuerte |
| Saltar al timecode y quedarse | muy relevante | muy fuerte |
| Marcar/fijar un momento | relevante permanente | máximo |
| Reformular la consulta sin abrir nada | los resultados fallaron | negativo |
| Bajar mucho en la lista antes de abrir | el ranking se equivocó de orden | negativo suave |

Con eso, dos usos honestos y explicables:

1. **Ajuste de pesos por biblioteca.** Los pesos `0.45 / 0.35 / 0.12 / 0.08` son
   una suposición razonable. Con 200 interacciones reales se puede ajustar por
   biblioteca con una regresión logística de 6 features — un modelo tan pequeño
   que **se puede imprimir**, lo cual importa: el producto promete explicabilidad.
2. **Expansión de consulta aprendida.** Si buscas "boda" y siempre abres archivos
   de la carpeta `2025/GARCIA_WEDDING`, esa asociación se guarda como pista de
   metadatos, no como magia.

⚠️ **Límites que hay que respetar para que esto no arruine el producto:**

- El aprendizaje **nunca** debe hacer que una consulta deje de encontrar algo que
  encontraba antes. Sólo reordena; no filtra.
- Debe ser **reseteable** con un botón, y **exportable** para inspección.
- Debe seguir siendo explicable: "subí este resultado porque abriste 4 como este
  esta semana" es aceptable; un puntaje sin razón, no.

---

## 7. Esquema de base de datos: migraciones v5 → v11

Todas aditivas. Ninguna toca `assets`, `locations`, `moments` ni `embeddings`;
ninguna invalida un índice existente.

```sql
-- v5: etiquetas de clasificación de escena/objeto
CREATE TABLE labels (
    labelID     INTEGER PRIMARY KEY,
    momentID    INTEGER NOT NULL REFERENCES moments(momentID) ON DELETE CASCADE,
    assetID     INTEGER NOT NULL REFERENCES assets(assetID)   ON DELETE CASCADE,
    identifier  TEXT NOT NULL,          -- taxonomía de Vision
    confidence  REAL NOT NULL,
    source      TEXT NOT NULL           -- 'vision-classify-v2'
);
CREATE INDEX idx_labels_moment ON labels(momentID);
-- + filas en search_index con kind='label'

-- v6: caras
CREATE TABLE faces (
    faceID      INTEGER PRIMARY KEY,
    momentID    INTEGER NOT NULL REFERENCES moments(momentID) ON DELETE CASCADE,
    assetID     INTEGER NOT NULL REFERENCES assets(assetID)   ON DELETE CASCADE,
    seconds     REAL NOT NULL,
    x REAL, y REAL, w REAL, h REAL,     -- bbox normalizado
    quality     REAL,                   -- DetectFaceCaptureQuality
    roll REAL, yaw REAL, pitch REAL,
    modelID     TEXT NOT NULL,          -- 'edgeface-s-v1' — misma regla que embeddings
    dimensions  INTEGER NOT NULL,
    quantization TEXT NOT NULL,
    vector      BLOB NOT NULL,
    personID    INTEGER REFERENCES people(personID) ON DELETE SET NULL,
    assignedBy  TEXT NOT NULL DEFAULT 'auto'   -- 'auto' | 'user'
);
CREATE INDEX idx_faces_person ON faces(personID);
CREATE INDEX idx_faces_asset  ON faces(assetID, seconds);

-- v7: personas
CREATE TABLE people (
    personID    INTEGER PRIMARY KEY,
    displayName TEXT,                   -- NULL = sin nombre todavía
    isNamed     BOOLEAN NOT NULL DEFAULT 0,
    centroid    BLOB,
    faceCount   INTEGER NOT NULL DEFAULT 0,
    coverFaceID INTEGER,
    createdAt   DATETIME NOT NULL,
    updatedAt   DATETIME NOT NULL
);
CREATE TABLE people_feedback (            -- lo que el usuario corrigió, para siempre
    id        INTEGER PRIMARY KEY,
    kind      TEXT NOT NULL,            -- 'merge' | 'split' | 'name' | 'ignore'
    aPersonID INTEGER, bPersonID INTEGER, faceID INTEGER,
    createdAt DATETIME NOT NULL
);
CREATE TABLE person_appearances (
    id         INTEGER PRIMARY KEY,
    personID   INTEGER NOT NULL REFERENCES people(personID) ON DELETE CASCADE,
    assetID    INTEGER NOT NULL REFERENCES assets(assetID)  ON DELETE CASCADE,
    startS     REAL NOT NULL, endS REAL NOT NULL,
    confidence REAL NOT NULL,
    source     TEXT NOT NULL            -- 'face' | 'voice' | 'both'
);
CREATE INDEX idx_appear_person ON person_appearances(personID, assetID, startS);

-- v8: voces
CREATE TABLE voice_segments (
    id        INTEGER PRIMARY KEY,
    assetID   INTEGER NOT NULL REFERENCES assets(assetID) ON DELETE CASCADE,
    startS    REAL NOT NULL, endS REAL NOT NULL,
    voiceID   INTEGER REFERENCES voices(voiceID) ON DELETE SET NULL,
    modelID   TEXT NOT NULL,
    vector    BLOB
);
CREATE TABLE voices (
    voiceID   INTEGER PRIMARY KEY,
    personID  INTEGER REFERENCES people(personID) ON DELETE SET NULL,
    centroid  BLOB, segmentCount INTEGER NOT NULL DEFAULT 0
);

-- v9: búsqueda por nombre tolerante a errores (verificado: trigram existe en SQLite 3.51)
CREATE VIRTUAL TABLE name_index USING fts5(
    name, personID UNINDEXED, kind UNINDEXED, tokenize='trigram'
);

-- v10: aprendizaje de uso
CREATE TABLE interactions (
    id        INTEGER PRIMARY KEY,
    queryHash TEXT NOT NULL,            -- hash, no la consulta: es privado por defecto
    assetID   INTEGER, momentID INTEGER,
    action    TEXT NOT NULL,            -- 'open' | 'seek' | 'pin' | 'reformulate'
    rank      INTEGER, dwellMs INTEGER,
    createdAt DATETIME NOT NULL
);

-- v11: procedencia por motor, para poder re-hacer trabajo hecho con el motor pobre
ALTER TABLE transcript_chunks ADD COLUMN engine TEXT;
ALTER TABLE ocr_texts        ADD COLUMN engine TEXT;
```

**Decisión de diseño repetida a propósito:** igual que `embeddings.modelID`,
tanto `faces` como `voice_segments` guardan su `modelID`. Cambiar de modelo de
caras es un reindexado en background, nunca una migración destructiva. Es la
misma lección, aplicada al mismo problema.

---

## 8. Fases, entregables y criterios de aceptación

Orden pensado para que **cada fase sea demostrable por sí sola** y ninguna
dependa de que la siguiente exista.

### Fase 7 — Medir (1 semana)

| | |
|---|---|
| **Entregables** | `Benchmarks/quality-v1.json` (120–150 consultas etiquetadas) · `wherefilm eval` · documento de línea base |
| **Aceptación** | `wherefilm eval` corre sobre el índice real y reporta Recall@10, MRR, nDCG@10, falsos positivos en negativos y curva de calibración. Reproducible dos veces con el mismo número. |
| **Riesgo** | Etiquetar cansa. Mitigación: empezar con 60 consultas y crecer; el harness no cambia. |

### Fase 8 — Arreglos de ranking y consulta (1–2 semanas)

| | |
|---|---|
| **Entregables** | Filtros `mediaType`/`dateRange` aplicados · RRF ponderado · centrado por consulta · bonus acotado · `Translation.framework` como nivel 2 · prompt ensembling · FTS5 trigram para nombres |
| **Aceptación** | **+15% Recall@10** y **cero regresión** en los negativos, contra la línea base de la Fase 7. Cada cambio, medido por separado, con su delta anotado. |
| **Riesgo** | RRF puede empeorar consultas donde el coseno absoluto era buena señal. Mitigación: híbrido (RRF ordena, coseno admite y calibra) y bandera para volver atrás. |

### Fase 9 — Intel (2 semanas)

| | |
|---|---|
| **Entregables** | `MachineProfile` · `ComputePolicy` · cadena de transcripción con `DictationTranscriber` · guardias recalibrados · `verify-release.sh --arch x86_64` · `doctor` con la sección Machine · empaquetar `.mlpackage` |
| **Aceptación** | La slice x86_64 pasa los 6 casos de `verify-release.sh` bajo Rosetta; `doctor` reporta correctamente ausencia de ANE, de Apple Intelligence y de `SpeechTranscriber`; una biblioteca de prueba se indexa de punta a punta sin caídas. |
| **Riesgo** | El techo de `VisionGate` en x86 es una incógnita. Mitigación: empezar en 1 y subir sólo con la prueba de estrés de 20 corridas. |
| **Nota** | Lo ideal es cerrar esta fase **en la Mac Intel real**. Rosetta valida corrección, no rendimiento. |

### Fase 10 — Vision fuera de proceso (2 semanas)

| | |
|---|---|
| **Entregables** | `wherefilm-vision-helper` (XPC) · reintento por trabajo · N ayudantes derivado de `MachineProfile` · métricas de caídas contenidas |
| **Aceptación** | 20 reindexados consecutivos de la misma biblioteca sin que la app muera **ni una vez**, y throughput de OCR ≥2× el actual en la M4. |
| **Riesgo** | Complejidad de IPC. Mitigación: el ayudante recibe una ruta de imagen y devuelve texto; nada de estado compartido. |

### Fase 11 — Señales nuevas (1–2 semanas)

| | |
|---|---|
| **Entregables** | `ClassifyImageRequest` → tabla `labels` + FTS · OCR con `recognitionLanguages` y `customWords` · `RecognizeDocumentsRequest` para frames con mucho texto · feature print para colapso de duplicados |
| **Aceptación** | **+20% Recall@10** en el subconjunto de consultas de objeto concreto; tiempo de indexado por minuto de video no más de **1,3×** el de la Fase 10. |

### Fase 12 — Re-ranking coarse-to-fine (1 semana)

| | |
|---|---|
| **Entregables** | Etapa `.reranked` en `searchProgressively` · re-rank con MobileCLIP-S2 sobre previews cacheados · verificación exacta final |
| **Aceptación** | **+10% nDCG@10** y p95 de la fase de re-rank **< 400 ms** sobre la máquina de desarrollo. |

### Fase 13 — Personas: caras (3 semanas)

| | |
|---|---|
| **Entregables** | Detección + calidad + alineación + `FaceEmbedder` (EdgeFace convertido a Core ML) · índice de caras · clustering online + pase offline · tablas v6–v7 · UI de personas · búsqueda por nombre · `person_appearances` con tracking |
| **Aceptación** | Sobre un set etiquetado de ~30 personas del archivo real: **pureza de cluster ≥0,9** y **≤3 clusters por persona** antes de nombrar; buscar un nombre devuelve sus apariciones con timecode correcto en ≥90% de los casos verificados a mano. |
| **Riesgo** | Coste de indexado. Mitigación: nivel D separado, encolado aparte, gobernado, y **apagable**. Prerrequisito real: Fase 10. |

### Fase 14 — Personas: voces (2 semanas)

| | |
|---|---|
| **Entregables** | Diarización con FluidAudio · `voices` · puente cara↔voz por co-ocurrencia · "¿dónde habla X?" |
| **Aceptación** | En 10 entrevistas reales, el hablante correcto se identifica en ≥85% del tiempo hablado. |
| **Nota** | Apple Silicon únicamente, y la app debe decirlo. |

### Fase 15 — Escala y aprendizaje (2–3 semanas)

| | |
|---|---|
| **Entregables** | Shards por volumen + Bloom · sidecar `.wfindex` · `interactions` · ajuste de pesos por biblioteca · prioridad de E/S · ventana horaria de indexado |
| **Aceptación** | Un disco indexado se puede llevar a otra Mac y quedar buscable **sin reprocesar**; el ajuste de pesos mejora nDCG@10 en el set de evaluación sin empeorar ninguna consulta más de 5%. |

**Total estimado: 16–19 semanas** de trabajo enfocado. Las fases 7 y 8 son las
que más precisión dan por semana invertida; la 13 es la que más cambia lo que el
producto *es*.

---

## 9. Licencias, privacidad y decisiones que hay que documentar

### 9.1 ADRs nuevos que este plan requiere

| ADR | Título | Qué decide |
|---|---|---|
| **0007** | *Face recognition, reversed* | Por qué se revierte la exclusión de §7 del plan v1, qué salvaguardas la hacen aceptable, y qué se prometió que no se haría |
| **0008** | *Machine profile over assumptions* | El sistema pregunta al hardware; ni una constante de rendimiento queda quemada |
| **0009** | *Vision out of process* | Contener un fallo de terceros en vez de convivir con él |
| **0010** | *Rank fusion: RRF con calibración absoluta* | Por qué no es ni RRF puro ni min–max |

### 9.2 Privacidad: lo que hay que construir, no sólo escribir

El reconocimiento facial y de voz es **información biométrica**. El plan v1 lo
dejó fuera precisamente por eso, y revertir la decisión obliga a construir las
protecciones, no a mencionarlas:

1. **Opt-in explícito y por biblioteca.** Apagado por defecto. Una pantalla que
   explica qué se calcula, dónde se guarda y qué se puede borrar.
2. **Todo local, siempre.** Ni un vector de cara sale de la máquina. Ya es cierto
   para todo lo demás; aquí es innegociable.
3. **Botón de borrado real.** "Eliminar todos los datos de personas" borra
   `faces`, `people`, `voices` y `person_appearances`, y deja el resto del índice
   intacto y funcionando. Debe estar probado, no supuesto.
4. **Sin exportación por defecto.** El sidecar `.wfindex` **no** incluye vectores
   de cara salvo que se active aparte: un SSD que se presta no debe llevar la
   biometría de nadie.
5. **Nombres son del usuario.** No se derivan de OCR ni de metadatos de terceros
   automáticamente. Que un gafete diga "Jorge Álvarez" no nombra un cluster; lo
   propone.
6. **El material de otras personas.** El archivo de Manu contiene caras de gente
   que no está en la conversación. Vale la pena decirlo en la UI una vez, con
   claridad, y dejar que quien use la app decida.

### 9.3 Licencias, en una tabla

| Componente | Licencia | Implicación |
|---|---|---|
| Código WhereFilm | MIT | sin cambios |
| MobileCLIP v1 (S0/S2) | apple-ascl | **no comercial** — ya vigente |
| EdgeFace | CC BY-NC-SA 4.0 | **no comercial** + share-alike; requiere atribución |
| FluidAudio SDK | Apache-2.0 | libre |
| Modelo pyannote (vía FluidAudio) | CC-BY-4.0 | atribución |
| SigLIP 2 | Apache-2.0 | libre — argumento a favor si algún día importa lo comercial |
| MetaCLIP 2 | permisiva (verificar antes de adoptar) | idem |

**Lectura práctica:** mientras esto sea el regalo para Manu, todo encaja. Si
alguna vez deja de serlo, la ruta de salida es SigLIP2/MetaCLIP2 + un modelo de
caras con licencia comercial — y como todo guarda su `modelID`, ese cambio es un
reindexado, no una reescritura.

---

## 10. Tu lista de técnicas: qué adoptar, qué adaptar, qué descartar

Tu lista era buena y casi toda aplica. Lo que sigue es el veredicto, con el
porqué.

### Adoptar tal cual

| Técnica | Dónde entra |
|---|---|
| Face Detection / Embeddings / Recognition / Clustering | §4 — el corazón del objetivo C |
| Object Detection / Image Classification | §3.3 — vía `ClassifyImageRequest`, sin traer un modelo |
| OCR | ya existe; se mejora con idiomas y `customWords` |
| Speech-to-Text | ya existe; se le añade cadena de fallback para Intel |
| Speaker Diarization | §4.6 |
| Multimodal / CLIP-style embeddings | ya es el corazón del sistema |
| Temporal Chunking / Keyframe Extraction / Adaptive Sampling | ya existe en `KeyframeSampler`; se le añade muestreo denso para caras |
| Vector Search / ANN / HNSW | ya existe (USearch) |
| Scalar Quantization | ya existe (int8 + f16) |
| Inverted Index / Full-Text / BM25 / Hybrid Search | ya existe (FTS5); mejora con RRF |
| Perceptual Hashing | ya existe (dHash); se refuerza con feature print |
| Multi-Stage / Coarse-to-Fine / Re-ranking | §3.4 — **la mejora estructural principal** |
| Query Expansion / Semantic Query Expansion | §3.2 |
| Caching (query, embedding, metadata) | parcial hoy (`QueryEmbeddingCache`); se amplía |
| mmap | ya existe (`USearchIndex.view`) |
| Offline / Incremental / Background Indexing, File System Watching | ya existe (jobs + FSEvents) |
| Worker Pool / Task Queue / Pipeline Parallelism | ya existe; mejora con §5.2 |

### Adaptar con cuidado

| Técnica | Adaptación |
|---|---|
| **Person Re-ID** | Sólo dentro de una misma sesión de grabación. Entre días distintos la ropa miente. Nivel D. |
| **Binary Quantization / PQ / IVF-PQ** | Vale la pena **cuando** el ANN sea el cuello de botella. Hoy responde en 1,6 ms sobre 208 k vectores; el costo está en FTS5. |
| **Sharding / Local + Global Index / Bloom Filters** | §5.1 — se adopta por **gestión de discos**, no por velocidad. Es honesto decirlo así. |
| **Cross-Encoder Re-ranking / Late Interaction** | La versión que cabe aquí es re-rank con un CLIP más fuerte sobre previews cacheados. Un cross-encoder real (ColBERT/ColPali) no cabe en el presupuesto de una app de barra de menús. |
| **Video Embeddings** | Un vector por clip pierde el momento, que es justo lo que el producto vende. Sirve como capa **adicional** para "busca clips parecidos a este", no como reemplazo. |
| **Image/Video Captioning** | Un VLM generando descripciones daría recall enorme… a un costo de indexado que rompe la promesa de convivir con Resolve. Posible como acción bajo demanda sobre un archivo concreto, nunca en la cola general. |
| **Audio/Video Fingerprinting** | Útil para detectar el mismo material re-exportado. Encaja como refuerzo del `content_key`, no como señal de búsqueda. |
| **Two-Tower / Collaborative Filtering** | Sin muchos usuarios no hay filtrado colaborativo. La parte utilizable es §6.2: aprender de **un** usuario. |

### Descartar, y por qué

| Técnica | Por qué no |
|---|---|
| **Distributed / Federated Search entre máquinas** | El producto es una app local en una Mac. Federar entre máquinas trae red, autenticación y sincronía — es otro producto. Los "nodos" aquí son discos, y eso ya está cubierto por el sharding. |
| **MapReduce** | Es el nombre de un patrón para clústeres. Aquí ya existe su versión correcta: cola de trabajos + pool de workers. |
| **Work Stealing** | La cola de SQLite con `claimNextJob` ya reparte por demanda; los workers libres toman el siguiente trabajo. Ya lo tienes. |
| **Semantic / Instance Segmentation** | Coste alto por píxel para una ganancia que la clasificación + detección ya dan en búsqueda. |
| **Recommendation System / Learning to Rank grande** | El *learning to rank* que cabe es una regresión de 6 features (§6.2). Un sistema de recomendación completo optimiza una métrica que este producto no tiene. |
| **Content-Addressable Storage como almacén** | Ya se usa la identidad por contenido para *identificar*; mover los originales a un almacén direccionado por hash violaría "no copia ni mueve tus originales", que es una promesa central. |

---

## 11. Referencias

**Verificado en esta máquina (SDK macOS 26, Xcode 26):** lista completa de
requests de `Vision`; `setComputeDevice(_:for:)` y `ComputeStage`;
`RecognizeDocumentsRequest.TextRecognitionOptions` con `customWords` y
`recognitionLanguages`; `DictationTranscriber` con preset
`.timeIndexedLongDictation` y `ResultAttributeOption.audioTimeRange`;
`SpeechTranscriber.isAvailable`; `MLComputeDevice.allComputeDevices`;
`Translation.framework` con `TranslationSession(installedSource:target:)` y slice
`x86_64`; `FoundationModels` con slice `x86_64`; SQLite 3.51.0 con FTS5
`trigram` y sin `load_extension`.

**Fuentes públicas:**

- Apple — [macOS Tahoe 26 compatibility](https://support.apple.com/en-us/122867)
- Apple Developer — [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) · [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber) · [Bring advanced speech-to-text to your app with SpeechAnalyzer (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/277/)
- Apple — [`coreml-mobileclip`](https://huggingface.co/apple/coreml-mobileclip) · [`ml-mobileclip`](https://github.com/apple/ml-mobileclip)
- Google DeepMind — [SigLIP 2](https://arxiv.org/abs/2502.14786) · [anuncio](https://huggingface.co/blog/siglip2)
- Meta — [MetaCLIP 2: A Worldwide Scaling Recipe](https://arxiv.org/html/2507.22062v1) · [sitio](https://meta-clip.github.io/)
- Idiap — [EdgeFace: Efficient Face Recognition Model for Edge Devices](https://ieeexplore.ieee.org/document/10388036/) · [EdgeFace-XXS](https://huggingface.co/Idiap/EdgeFace-XXS)
- FluidInference — [FluidAudio](https://github.com/FluidInference/FluidAudio) · [speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)
- Cormack, Clarke, Büttcher (SIGIR 2009) — Reciprocal Rank Fusion; resumen práctico en [ParadeDB](https://www.paradedb.com/learn/search-concepts/reciprocal-rank-fusion) y [BigData Boutique](https://bigdataboutique.com/blog/reciprocal-rank-fusion-how-it-works-and-when-to-use-it)
- Prompt ensembling en CLIP — [Pinecone](https://www.pinecone.io/learn/series/image-search/zero-shot-image-classification-clip/) · [A Simple Zero-shot Prompt Weighting Technique](https://arxiv.org/pdf/2302.06235)
- Cuantización de embeddings — [Hugging Face](https://huggingface.co/blog/embedding-quantization) · [Qdrant, Binary Quantization](https://qdrant.tech/articles/binary-quantization/)
- Clustering de caras — [dlib, face clustering (Chinese Whispers)](https://dlib.net/face_clustering.py.html)

**Documentos internos que este plan continúa:**
[`docs/PLAN.md`](PLAN.md) · [`docs/RESEARCH-NOTES.md`](RESEARCH-NOTES.md) ·
[`docs/PERFORMANCE-PASS-2026-09-02.md`](PERFORMANCE-PASS-2026-09-02.md) ·
[`docs/SCALE-PASS-2026-09-02.md`](SCALE-PASS-2026-09-02.md) ·
[`docs/decisions/`](decisions/)

---

## Una última cosa, sin adornos

Si sólo se pudiera hacer **una** de todas estas cosas, sería la **Fase 7**: el
banco de evaluación. No porque sea la más interesante, sino porque es la única
que convierte "siento que no funciona" en un número que se puede bajar.

Y si se pudieran hacer **tres**, serían: Fase 7 (medir), Fase 8 (arreglar el
ranking, que son bugs reales y baratos) y Fase 11 (`ClassifyImageRequest`, que es
la señal más barata y más ausente del sistema). Esas tres, juntas, probablemente
resuelvan la mayor parte de lo que hoy se siente mal — antes de tocar una sola
cara.
