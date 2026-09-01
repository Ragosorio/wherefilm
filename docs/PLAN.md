# WhereFilm — Plan de construcción

**Spotlight semántico local para video y foto, nativo de macOS.**

Documento maestro: qué se construye, con qué, en qué orden y por qué.
Derivado de la investigación profunda (`docs/RESEARCH-NOTES.md`) más verificación
directa contra el SDK de macOS 26.5 y contra los repos/modelos reales (agosto 2026).

---

## 0. Resumen en una página

| | |
|---|---|
| **Qué es** | Un índice local de todo tu material audiovisual que responde a frases humanas y devuelve **momentos**, no archivos. |
| **Qué NO es** | No es un chatbot, no es un MAM en la nube, no es una biblioteca que copia tus originales. |
| **Consulta típica** | *"la entrevista donde el chavo tenía playera azul y habló del presupuesto"* |
| **Respuesta típica** | `INTERVIEW_JUAN_03.MOV · 14:12–14:31 · 94% · Samsung T7 (offline)` |
| **Lenguaje** | Swift 6.2 / SwiftUI. Cero Python, cero Docker, cero Electron, cero servidor. |
| **Almacén** | Un `.sqlite` (GRDB + FTS5) + un `.usearch` (HNSW mmap). |
| **IA** | MobileCLIP (Core ML/ANE) + SpeechAnalyzer (sistema) + Vision OCR (sistema) + Foundation Models (opcional). |
| **Coste recurrente** | US$0. Solo US$99/año de Apple Developer Program si se quiere notarizar para distribuir. |
| **Objetivo de convivencia** | Que puedas indexar 30 TB mientras editas en DaVinci Resolve y no lo notes. |

**La tesis técnica central:** *indexar es caro; buscar es baratísimo.* Todo el diseño
sale de ahí. Los 30 GB de un video se leen **una vez**; después la búsqueda solo
compara vectores pequeños ya calculados.

---

## 1. Decisiones ya tomadas (y verificadas en esta máquina)

Estas no son suposiciones del documento de investigación: las comprobé contra el
SDK instalado y compilando código real en este Mac (MacBook Air M4, 16 GB,
macOS 26.5.2, Xcode 26.6, Swift 6.3.3).

| Decisión | Estado de verificación |
|---|---|
| GRDB 7 sobre SQLite del sistema con **FTS5 disponible** | ✅ compilado y ejecutado — SQLite 3.51.0, `unicode61 remove_diacritics 2` funciona |
| **USearch 2.26.2** vía SPM, con `save`/`load`/**`view` (mmap)** y `filteredSearch` | ✅ compilado y ejecutado — aceleración `neon, neonhalf, neonsdot, neonfhm` |
| MobileCLIP Core ML: `image` RGB **256×256** → `final_emb_1` **[1,512] FP32**; `text` INT32 **[1,77]** → **[1,512]** | ✅ leído del protobuf real de `apple/coreml-mobileclip` |
| `SpeechAnalyzer` + `SpeechTranscriber` con `attributeOptions: [.audioTimeRange, .transcriptionConfidence]` y `SpeechAnalyzer.Options(priority:.background)` | ✅ leído del `.swiftinterface` de macOS 26.5 |
| `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`, `reserve(locale:)`, `supportedLocales` | ✅ existe en el SDK |
| Vision `RecognizeTextRequest` (API Swift moderna) con `perform(on: CGImage)` | ✅ existe en el SDK |
| Tokenizer CLIP en Swift, contrastado contra `openai/clip-vit-base-patch32` | ✅ ground truth capturado: `"man wearing a blue shirt"` → `[49406, 786, 3309, 320, 1746, 2523, 49407]` |

### 1.1 Hallazgo que corrige la investigación original

El documento propone **MobileCLIP2** como modelo visual. Verifiqué el hub:
Apple publica MobileCLIP2 (S0/S2/S3/S4/B/L-14) **solo en PyTorch/OpenCLIP**.
El repositorio `apple/coreml-mobileclip` contiene **únicamente MobileCLIP v1**
(`s0`, `s1`, `s2`, `blt`).

**Consecuencia práctica:** v1 del producto usa **MobileCLIP-S0 v1** (listo, exportado
por Apple, 256×256→512d). MobileCLIP2 y SigLIP 2 quedan como *conversiones propias*
con `coremltools` en la Fase 5, detrás de la misma abstracción `VisualEncoder`.
Como cada embedding guarda su `model_id`, cambiar de modelo nunca invalida la
biblioteca: se reindexa en paralelo y se hace swap.

### 1.2 El problema del español, resuelto sin modelo más pesado

MobileCLIP v1 es un modelo entrenado en inglés. `"hombre con camisa azul"` da peor
recall que `"man wearing a blue shirt"` — y el tokenizer lo delata: parte *hombre*
en `hom`+`bre</w>`, mientras *man* es un token único.

La solución **no** es cargar un modelo multilingüe de 1 GB. Es normalizar la
consulta antes del text encoder, en tres niveles con degradación limpia:

1. **Foundation Models on-device** (si hay Apple Intelligence): traduce y descompone
   la frase en `{visual: en, spoken: es, filtros}` con salida estructurada.
2. **Diccionario de dominio + `NLLanguageRecognizer`** (siempre disponible):
   ~300 pares es→en de vocabulario audiovisual (`playera azul` → `blue shirt`,
   `de noche` → `at night`, `plano cerrado` → `close-up shot`).
3. **Consulta literal** como último recurso.

Importante: la parte hablada (`presupuesto`) **nunca se traduce** — va a FTS5 en
español directo, porque la transcripción está en español.

---

## 2. El modelo de datos: `asset ≠ location`

Esta es la decisión que salva el producto. La ruta **nunca** es la identidad.

```
ASSET  (lo que el sistema sabe — sobrevive a todo)
│
├── content_key      identidad por contenido, en dos niveles
├── metadata         duración, códec, dimensiones, fecha, cámara
├── moments          segmentos con tiempo de inicio/fin
├── embeddings       vector + model_id + quantization
├── transcript       chunks con timestamps
├── ocr              texto en pantalla por momento
└── LOCATIONS  (dónde podría estar — mutable, plural, desechable)
    ├── Samsung_T7  : /Entrevistas/A.mov   ONLINE
    ├── Backup_8TB  : /2025/A.mov          OFFLINE
    └── NAS         : /Archive/A.mov       MISSING
```

### 2.1 Identidad de contenido en dos niveles

Hashear 810 TB completos es inviable. Estrategia por niveles:

**QUICK-ID (siempre, milisegundos)** — BLAKE3/SHA-256 sobre:
`file_size ‖ duración ‖ códec ‖ primeros 1 MiB ‖ 1 MiB del centro ‖ últimos 1 MiB`.
Colisión práctica ≈ 0 para material de cámara, y no toca los 30 GB del medio.

**STRONG-ID (solo si hay ambigüedad, y solo en idle)** — hash completo del stream.
Se dispara cuando dos QUICK-ID coinciden pero difiere algo, o cuando el usuario
pide verificación explícita.

Señales auxiliares que se guardan pero **no** son identidad:
- `volumeUUIDString` — persistente por volumen, resuelve el remontaje `/Volumes/Media 1`.
- `fileContentIdentifierKey` — APFS, útil como pista, no universal (falla en exFAT/NAS).
- `fileResourceIdentifier` — Apple documenta que **no persiste entre reinicios**. Nunca como clave.

### 2.2 Los cuatro estados de una localización

Confundir *desconectado* con *borrado* arruinaría el producto. Son estados distintos:

| Estado | Cómo se detecta | Qué hace la UI |
|---|---|---|
| `online` | volumen montado + `stat` OK | reproduce y salta al timecode |
| `offline` | volumen no está en `FileManager.mountedVolumeURLs` | muestra preview + "Samsung T7 — desconectado" |
| `moved` | volumen montado, ruta ausente, `content_key` aparece en otra ruta | reescribe la ruta en silencio |
| `missing` | volumen montado, ruta ausente, no aparece en ningún lado | ⚠ *Original missing* — **conserva todo el índice** |

Un asset `missing` sigue siendo buscable y sigue mostrando su transcripción, su
match visual y su última ubicación conocida. *Aunque lo borren, no perdemos lo que sabíamos.*

---

## 3. Esquema SQLite

Fuente de verdad única. USearch es un índice **derivado y reconstruible**.

```sql
volumes(volume_uuid PK, name, fs_type, last_seen_at, is_online, bookmark BLOB)
assets(asset_id PK, content_key UNIQUE, strong_key, media_type, duration_s,
       width, height, created_at, camera_make, camera_model, indexed_levels, …)
locations(location_id PK, asset_id→, volume_uuid→, relative_path, file_size,
          modified_at, availability, last_seen_at, UNIQUE(volume_uuid, relative_path))
moments(moment_id PK, asset_id→, start_s, end_s, kind, poster_ref)
embeddings(moment_id→, model_id, dimensions, quantization, vector BLOB,
           PRIMARY KEY(moment_id, model_id))
transcript_chunks(chunk_id PK, asset_id→, start_s, end_s, text, confidence, locale)
ocr_texts(ocr_id PK, moment_id→, text, confidence)
previews(moment_id→ PK, cache_path, bytes, last_used_at)
jobs(job_id PK, asset_id→, task, state, priority, attempts, last_error, updated_at)
search_index  -- FTS5 externo: transcript ‖ ocr ‖ filename ‖ folder ‖ camera ‖ notas
model_registry(model_id PK, kind, revision, dimensions, quantization, created_at)
```

Notas de diseño:
- FTS5 con `tokenize='unicode61 remove_diacritics 2'` → *"presupuesto"* encuentra *"Presupuesto"* y *"presupuestó"*.
- `embeddings.vector` guarda **int8 cuantizado + escala**, no float32. 4.86 M vectores × 512d = **~2.5 GB** en lugar de ~10 GB.
- `model_id` en cada embedding es obligatorio. Embeddings de modelos distintos **nunca** se comparan.
- USearch se puede borrar y regenerar entero desde `embeddings` sin perder nada.

### 3.1 El enemigo real del disco: los previews

| Concepto | Tamaño en el escenario ilustrativo (27.000 × 30 GB) |
|---|---|
| Originales | ~810 TB |
| Vectores int8 | **~2,5 GB** |
| Transcripciones + OCR + metadata | ~1–3 GB |
| Miniaturas si guardáramos una por momento | **~97 GB** ← el problema |

Por eso los previews son una **cache con presupuesto**, no un almacén:
- 1 póster por asset → siempre.
- Previews de resultados recientes y de momentos marcados → se conservan.
- Todo lo demás → regenerable, LRU con techo configurable (5/10/25 GB/ilimitado).

---

## 4. Pipeline de indexado por niveles

La inteligencia de un asset **no tiene que aparecer de golpe**. Cuatro niveles
independientes, encolados por separado, cada uno con su propia QoS.

```
LEVEL A — instantáneo    filename · ruta · volumen · duración · códec · fecha · póster
LEVEL B — barato         detección de tomas · keyframes · embeddings visuales
LEVEL C — caro           transcripción completa · OCR de keyframes
LEVEL D — opcional       diarización · clustering de caras · captions · VLM
```

Un SSD nuevo es parcialmente buscable minutos después de conectarlo, y va mejorando
solo durante horas. La UI lo refleja honestamente:

```
Drive: Client Archive 4TB
Files discovered     4,281 / 4,281  ✓
Visual search        3,912 / 4,281
Transcript             847 / 4,281
Deep analysis                disabled
```

### 4.1 Selección de momentos (nunca frame a frame)

30 min a 30 fps = 54.000 frames, y casi todos redundantes. El muestreo adaptativo:

1. Muestreo base cada **N segundos** (por defecto 5 s) con `AVAssetImageGenerator`
   en modo batch (`images(for:)`), `maximumSize` 256×256, tolerancias amplias
   (barato: deja que el decoder use el keyframe más cercano).
2. Sobre cada frame ya reducido, **firma perceptual barata** (dHash 8×8 en gris).
3. Se conserva el frame solo si la distancia de Hamming contra el anterior supera
   un umbral → material estático guarda poquísimos momentos, un videoclip con
   cortes guarda muchos.
4. Cada momento se cierra cuando entra el siguiente → `[start_s, end_s)`.

Resultado típico en entrevista: de 54.000 frames a ~40–180 momentos.

### 4.2 Transcripción

Jerarquía con degradación, en este orden:

```
SpeechAnalyzer + SpeechTranscriber        ← macOS 26+, modelo del sistema,
  (.audioTimeRange, .transcriptionConfidence)  no pesa en el bundle ni en la RAM de la app
       ↓ locale no soportado / no instalable
FluidAudio (Parakeet TDT v3, Apache-2.0)  ← Core ML/ANE, 25 idiomas, evita GPU
       ↓
whisper.cpp                                ← red de seguridad para casos raros
```

El audio se lee del track con AVFoundation, se convierte a 16 kHz mono Float32,
se transcribe y **se descarta**. Nunca se guarda una copia del audio.

Los `Result` de `SpeechTranscriber` traen `range: CMTimeRange` y un `AttributedString`
con runs marcados por `\.audioTimeRange`. De ahí salen los `transcript_chunks`
agrupados a ~8–15 s con solape, que es la granularidad correcta para saltar al momento.

### 4.3 OCR

`RecognizeTextRequest` de Vision, **solo sobre los keyframes que ya elegimos**
(no sobre frames extra). Añade recall gratis para rótulos, gafetes, pizarras,
números de claqueta y pantallas. `recognitionLevel: .accurate`,
`automaticallyDetectsLanguage: true`.

---

## 5. Búsqueda: fusión de evidencias, no un embedding mágico

```
"el chavo de playera azul que habló del presupuesto"
              │
      ┌───────┴────────┐  Query Planner
      │  Foundation Models (opcional) / diccionario / literal
      ↓
  { visual_en: "man wearing a blue shirt",
    spoken_es: ["presupuesto", "no había dinero", "fondos"],
    filters:   { media_type: video } }
              │
   ┌──────────┼──────────┬──────────┐
   ↓          ↓          ↓          ↓
 CLIP txt   FTS5      FTS5 OCR   metadata
 →USearch   transcript            SQL
   ↓          ↓          ↓          ↓
   └──────────┴──────────┴──────────┘
              ↓
   FUSIÓN TEMPORAL + SCORE
   mismo asset + señales a <30 s → boost fuerte
              ↓
   Samsung T7 · INTERVIEW_041.MOV · 14:12→14:31 · 94%
```

### 5.1 Ranking

Score normalizado por canal (`z-score` dentro de los top-K de cada canal), luego
combinación ponderada, más un **bonus de coincidencia temporal**:

```
score = w_v·visual + w_t·transcript + w_o·ocr + w_m·metadata
      + bonus_temporal(Δt entre señales del mismo asset)
```

Pesos por defecto `0.45 / 0.35 / 0.12 / 0.08`, ajustables. El bonus temporal es
lo que convierte dos señales mediocres en un resultado excelente: *visual a 14:10*
+ *transcripción a 14:16* en el mismo archivo es muchísimo más fiable que
cualquiera de las dos por separado.

### 5.2 Explicabilidad obligatoria

Nunca `Resultado: 91%`. Siempre:

```
94% match
✓ visual      "man wearing a blue shirt"      0.31 sobre la media
✓ diálogo     "…no tenemos presupuesto para…"  14:16
✓ fecha       marzo 2025
Samsung T7 — offline
Entrevistas/Juan/A0045.mov  ·  14:12
```

Cuando la IA se equivoca ligeramente, ver *por qué* hizo match es lo que
convierte un fallo en algo utilizable.

---

## 6. Ser un buen ciudadano junto a DaVinci Resolve

Honestidad primero: **ningún análisis de IA es gratis**. No se puede prometer que
indexar 30 TB sea invisible. Lo que sí se puede es que el indexador tenga prioridad
mínima y sea agresivamente educado.

### 6.1 Coordinador pequeño, workers desechables

```
App / MenuBar          decenas de MB + SQLite abierto     siempre viva
      │ hay trabajo?
      ↓
Inference Worker       carga modelo → procesa lote → guarda
      ↓
      unload           la RAM vuelve al sistema
```

Mantener el índice **listo para buscar** no requiere tener el image encoder cargado.
Una búsqueda necesita el text encoder unos milisegundos; el pipeline de video
desaparece por completo cuando no trabaja.

### 6.2 Resource Governor

Una sola pieza decide si se puede trabajar, releyendo el estado del sistema:

| Señal | Fuente | Efecto |
|---|---|---|
| Estado térmico | `ProcessInfo.thermalState` | `.serious` → concurrencia 1; `.critical` → pausa |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | pausa inferencia pesada |
| Alimentación | IOPMPowerSource | con batería → solo Level A |
| App de edición al frente | `NSWorkspace` bundle IDs | Resolve/Premiere/FCP/AE → pausa o mínimo |
| Modo manual | menú | `Smart` / `Paused` / `Full speed` |

Y QoS explícita por tarea:

```
búsqueda            → .userInitiated
preview de resultado → .userInitiated
escanear disco nuevo → .utility
keyframes+embeddings → .utility
transcribir archivo  → .background
reindexar modelo viejo → .background
```

### 6.3 Evitar la GPU deliberadamente

`MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`. No garantiza cero
contención, pero mantener PyTorch/MPS fuera del sistema mientras Resolve castiga
la GPU es infinitamente más sensato que competir por ella. FluidAudio toma la misma
decisión de diseño para sus pipelines de background.

### 6.4 El botón de la barra de menús es un governor real

```
Media Search                    Paused
INDEXER
 ● Smart    ○ Paused    ○ Full speed
PAUSE FOR   ∞  15m  30m  1h  2h  4h
─────────────────────────────────────
12,814 assets indexed
2 drives offline
46 files pending
Open Search…              ⌘⇧Space
Preferences…
Quit
```

`MenuBarExtra` de SwiftUI + `SMAppService` para el login item (sin hacks de
LaunchAgents). Cuando abras Resolve: *Pause → 2h*, y se reactiva solo.

**Nota de privacidad importante:** indexar los videos existentes **no requiere el
micrófono**. La app lee pistas de audio de archivos. El permiso de micrófono solo
haría falta para el botón de dictado. El switch del menú no significa "deja de
espiarme"; significa literalmente *pausa el indexador*.

---

## 7. Permisos y sandbox

- **Security-scoped bookmarks** por carpeta/volumen que el usuario elige explícitamente.
- **Nada de Full Disk Access.** "Add Library → elegir carpeta o disco" y se guarda el bookmark.
- Read-only sobre los originales. La app **nunca escribe** en el material del usuario…
- …excepto el **sidecar opcional** (`VIDEO.wfindex`, ~180 KB–pocos MB), desactivado
  por defecto, que permite llevar un SSD ya indexado a otra Mac sin reprocesar.
  Es la idea de los `.prmi` de Adobe, y es lo que hace que reinstalar no cueste días.
- Reconocimiento facial **fuera del núcleo**: implica datos biométricos y obligaciones
  legales/de consentimiento, y *"el chavo de playera azul"* se resuelve sin saber quién es.

---

## 8. Arquitectura de módulos

```
WhereFilmCore    esquema, migraciones, identidad, volúmenes, bookmarks, cache
WhereFilmML      VisualEncoder (Core ML) · CLIPTokenizer · VectorIndex (USearch)
WhereFilmIndex   discovery · shot detection · keyframes · transcripción · OCR
                 · job queue · ResourceGovernor
WhereFilmSearch  QueryPlanner · canales de búsqueda · fusión · ranking · explicación
wherefilm (CLI)  todo lo anterior sin UI — es el banco de pruebas real
WhereFilmApp     MenuBarExtra · ventana de búsqueda · preferencias
```

El CLI no es un extra: es la forma de probar el motor completo sin depender de la UI,
y de medir de verdad en hardware real (que es la única forma válida de evaluar Core ML/ANE).

---

## 9. Fases

| Fase | Entregable | Estado |
|---|---|---|
| **1 · Esqueleto** | Package, esquema+migraciones, identidad de contenido, volúmenes, CLI `add`/`scan`/`status` | ✅ implementado |
| **2 · Visión** | Keyframes adaptativos, MobileCLIP Core ML, tokenizer CLIP, USearch, `wherefilm search` | ✅ implementado |
| **3 · Audio y texto** | SpeechAnalyzer con timestamps, FTS5, OCR de keyframes, fusión temporal | ✅ implementado |
| **4 · App** | MenuBarExtra, ventana de búsqueda, governor, `SMAppService`, previews con presupuesto | ✅ implementado |
| **5 · Calidad** | Evaluación es/en sobre material real, MobileCLIP2/SigLIP2 convertidos, sidecar, FSEvents incremental | ▢ siguiente |
| **6 · Distribución** | Sandbox + bookmarks, notarización Developer ID, `.dmg` | ▢ requiere US$99/año |

### 9.1 Lo que hay que medir antes de la Fase 5

No se decide por teoría; se mide en este Mac con el material de Manu:

1. **Recall es vs en** — 50 consultas reales en ambos idiomas sobre el mismo dataset.
   Si el gap es grande, sube SigLIP 2 en la prioridad; si es pequeño, MobileCLIP-S0 se queda.
2. **Coste real de indexado** — segundos por minuto de video, por nivel (B y C separados).
3. **Contención con Resolve** — reproducción de timeline con y sin indexador a full speed.
4. **Tamaño del índice** — bytes por hora de video indexada, con y sin previews.
5. **Latencia de búsqueda** — p50/p95 con 100 k, 1 M y 5 M de momentos.

---

## 10. Riesgos y cómo se mitigan

| Riesgo | Mitigación construida |
|---|---|
| Recall pobre en español | Query planner de 3 niveles; `model_id` permite cambiar de modelo sin perder la biblioteca |
| MobileCLIP2 no tiene Core ML oficial | Se arranca con v1; conversión propia detrás de la abstracción `VisualEncoder` |
| USearch es pre-1.0 en algunas plataformas | El índice es **derivado**: se puede borrar y regenerar desde SQLite en cualquier momento |
| `sqlite-vec` sigue pre-v1 (0.1.10-alpha) | Por eso no es la dependencia principal; USearch + fallback de escaneo lineal con Accelerate |
| Apple Intelligence no está en todos los Macs | Foundation Models es **mejora opcional**, nunca ruta crítica |
| Discos que se remontan con otro path | Identidad por `content_key` + `volumeUUID`, nunca por ruta absoluta |
| Índice crece sin control | Presupuesto de cache de previews + cuantización int8 de vectores |
| El indexador molesta al editar | ResourceGovernor + `.cpuAndNeuralEngine` + workers desechables + pausa manual |

---

## 11. Coste

| Componente | Coste recurrente |
|---|---|
| Búsqueda visual, transcripción, OCR, LLM on-device | **US$0** |
| SQLite, USearch, almacenamiento, backend, API | **US$0** |
| Desarrollo y ejecución local con Xcode | **US$0** |
| Developer ID + notarización (solo para regalar el `.dmg` pulido) | **US$99/año** |

---

## 12. Referencias que valen la pena

**Producto:** Peakto (búsqueda conversacional + discos desconectados), Adobe
Media Intelligence (análisis local cacheable en sidecar `.prmi`, prioriza la
reproducción), Axle AI e Iconik (*catalog in place*: el registro del asset es
independiente de la capa de almacenamiento).

**Código:** `openara-ai/media-search-agent` (MIT — la mejor especificación
ejecutable del producto: shots, keyframes, momentos, ADRs), `chn-lee-yumi/MaterialSearch`
(demuestra que buscar es baratísimo una vez calculados los embeddings),
Fennec Search (fusión CLIP+Whisper+escenas), `fguzman82/CLIP-Finder2` (la ruta
Swift→Core ML→MobileCLIP→ANE), PrivateLens (filosofía sidecar read-only + explicabilidad).

**Modelos:** `apple/coreml-mobileclip`, `apple/ml-mobileclip`,
`FluidInference/FluidAudio`, `unum-cloud/usearch`, `groue/GRDB.swift`.
