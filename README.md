<p align="center">
  <img src="site/public/brand/icon-256.png" width="112" height="112" alt="">
</p>

<h1 align="center">WhereFilm</h1>

<p align="center">
  <strong>Spotlight semántico local para video y foto, nativo de macOS.</strong><br>
  <a href="https://github.com/Ragosorio/wherefilm/releases/latest">Descargar para Mac</a>
  · Apple Silicon + Intel · macOS 26
</p>

---

Describe una escena o una frase que alguien dijo, y encuentra el **momento**
exacto — no el archivo. Todo local, sin servidores, sin API, sin costo por
consulta. Y funciona aunque el disco esté desconectado.

> **Si solo quieres usarla:** baja el `.dmg` de la
> [última versión](https://github.com/Ragosorio/wherefilm/releases/latest),
> arrastra WhereFilm a Applications y ábrela. Trae los modelos dentro, así que
> no hay Terminal ni una segunda descarga. La primera vez macOS pedirá una
> aprobación en *Privacidad y seguridad* — está explicado
> [más abajo](#primera-apertura-y-los-99-de-apple).

```
$ wherefilm search "el chavo de playera azul que habló del presupuesto"

Found 3 moments in 112 ms

1. INTERVIEW_JUAN_03.MOV  14:12–14:31   94%
     ✓ visual · "man wearing a blue shirt" · cos 0.241
     ✓ dialogue · 14:16 · "…el problema que tuvimos fue el presupuesto…"
     ⚠ Samsung T7 · offline — Entrevistas/Juan/A0045.mov
```

---

## La idea

**Indexar es caro. Buscar es baratísimo.** Un video de 30 GB se lee **una vez**;
después cada búsqueda solo compara vectores pequeños ya calculados. Por eso este
producto se parece más a *Spotlight + Shazam visual + búsqueda de transcripciones*
que a un chatbot — y por eso cabe en una utilidad de barra de menús.

Cuatro señales independientes, fusionadas al final:

| Señal | Cómo | Responde a |
|---|---|---|
| **Visual** | MobileCLIP en Core ML / Neural Engine → USearch HNSW | qué se veía |
| **Diálogo** | `SpeechAnalyzer` con timestamps → SQLite FTS5 | qué se dijo, y en qué segundo |
| **Texto en pantalla** | Vision OCR sobre los mismos keyframes | letreros, gafetes, claquetas |
| **Metadata** | FTS5 | nombres de archivo, carpetas, cámara |

Lo que hace bueno el resultado no es un modelo gigante entendiendo 30 minutos de
video. Es que *"camisa azul" a las 14:10* y *"presupuesto" a las 14:16* coinciden
en el mismo archivo, con seis segundos de diferencia.

## Lo que no hace

- **No copia ni mueve tus originales.** Cataloga en el lugar donde ya viven.
- **No usa el micrófono.** Lee pistas de audio de archivos en disco.
  `NSMicrophoneUsageDescription` no existe en el `Info.plist`.
- **No manda nada a ningún servidor.** Cero red después de bajar los modelos.
- **No pide Full Disk Access.** Solo las carpetas o discos que elijas.
- **No olvida.** Si borras o mueves un archivo, el índice sobrevive.

---

## Empezar

La app distribuida requiere macOS 26 (Tahoe) o superior e incluye un ejecutable
universal para Apple Silicon e Intel. Para compilar el proyecto se necesita
Xcode 26.

```bash
./Scripts/fetch-models.sh          # MobileCLIP-S0 + tokenizer CLIP (~105 MB)
swift run wherefilm doctor         # verifica todo lo on-device
swift run wherefilm scan ~/Movies --index
swift run wherefilm search "atardecer en la playa"
```

Y la app de barra de menús, o el `.dmg` completo:

```bash
./Scripts/make-app.sh --open       # app en ./build
./Scripts/make-dmg.sh              # .dmg + .zip + SHA256SUMS
```

`make-app.sh` compila las slices `arm64` y `x86_64`, las une en un ejecutable
universal y copia los modelos **dentro** del bundle, así que el `.dmg` funciona
en una Mac compatible que nunca vio este repositorio.

Para probar sin tocar tu índice real, `WHEREFILM_HOME` aísla todo:

```bash
swift Scripts/make-test-library.swift /tmp/testlib
WHEREFILM_HOME=/tmp/wfhome swift run wherefilm scan /tmp/testlib --index
```

## El CLI

El CLI no es un extra: ejercita el motor completo sin UI, que es la única forma
válida de medir Core ML y el Neural Engine en hardware real.

| Comando | Qué hace |
|---|---|
| `scan <ruta> [--index]` | cataloga una carpeta o disco en su lugar |
| `index [--full-speed] [--tasks …]` | procesa la cola de trabajos |
| `search <frase> [--explain] [--benchmark-runs N]` | busca; puede explicar o medir p50/p95/p99 en proceso |
| `status` | qué sabe el índice, y por qué el indexador está o no trabajando |
| `volumes` | discos conocidos y si están conectados |
| `doctor` | modelos, locales de voz, Apple Intelligence, aceleración SIMD |
| `rebuild-index` | reconstruye el HNSW desde SQLite |
| `tokenize <texto>` | cómo se tokeniza para el text encoder |

---

## Arquitectura

```
Sources/
  WhereFilmCore     esquema · migraciones · identidad de contenido · volúmenes
  WhereFilmML       MobileCLIP Core ML · tokenizer CLIP · índice USearch
  WhereFilmIndex    keyframes · transcripción · OCR · cola · resource governor
  WhereFilmSearch   query planner · canales · fusión temporal · ranking
  WhereFilmCLI      el banco de pruebas
  WhereFilmApp      MenuBarExtra · ventana de búsqueda · reproductor por momento
```

Dos archivos son todo el almacenamiento:

```
~/Library/Application Support/WhereFilm/
    index.sqlite                    la verdad: assets, momentos, transcripciones, vectores
    Vectors/mobileclip-s0-v1.usearch  índice HNSW derivado — se puede borrar y reconstruir
~/Library/Caches/WhereFilm/Previews   miniaturas, con presupuesto y evicción LRU
```

### `asset ≠ location`

La decisión que sostiene el producto. Una ruta nunca es una identidad: las
carpetas se reorganizan, macOS remonta `/Volumes/Media` como `/Volumes/Media 1`,
y el mismo clip vive legítimamente en un SSD, un backup y un NAS a la vez.

```
ASSET   ─ identidad por contenido, transcripción, momentos, embeddings, OCR, previews
   └─ LOCATIONS
        Samsung T7 : Entrevistas/A.mov   ONLINE
        Backup 8TB : 2025/A.mov          OFFLINE   ← el disco está en un cajón
        NAS        : Archive/A.mov       MISSING   ← se borró; el índice permanece
```

`offline` y `missing` son cosas distintas, y ninguna significa *olvidado*.

### Tamaños reales

| | |
|---|---|
| Originales (27.000 × 30 GB) | ~810 TB |
| Vectores en int8 | **~2,5 GB** |
| Miniatura por momento, si no hubiera presupuesto | ~97 GB ← el riesgo real |

Por eso los previews son una cache con techo, y los vectores se guardan
cuantizados con su `modelID` — cambiar de modelo es un reindexado en segundo
plano, nunca una migración destructiva.

---

## Cómo se lee el texto dentro de las imágenes

CLIP entiende escenas; no lee. El número de una claqueta, el nombre en un gafete
o el rótulo de una tienda los lee Vision, sobre los mismos fotogramas que ya se
decodificaron. Eso hacía que el costo extra fuera casi cero — y también que
durante un tiempo no sirviera de nada.

El problema no era el reconocedor sino **el tamaño del fotograma**. Los
keyframes se decodificaban a 320×320 porque es lo que MobileCLIP necesita
(256×256), y a ese tamaño el texto de un cuadro 1080p sencillamente no existe.
Medido sobre 24 capturas reales, caracteres recuperados por el reconocedor
`.accurate`:

| Lado mayor del fotograma | Caracteres leídos |
|---|---|
| 320 px | 173 |
| 768 px | 3.172 |
| 1024 px | 3.280 |
| 1280 px | 3.244 |

Dieciocho veces más texto — y **no más lento**: en esa banda el costo por imagen
se mantuvo plano, entre 60 y 75 ms. Arriba de ~1024 px ya no hay nada que ganar.
Core ML hace su propio *resize* a 256 cuando recibe el fotograma, así que el
modelo visual conserva exactamente el mismo tamaño de entrada. Decodificar a
1024 sí usa más memoria temporal que hacerlo a 320; por eso el lote bajó de 16
a 8 fotogramas y el techo global de concurrencia sigue siendo conservador.

Sobre un video de 10 minutos, el efecto de extremo a extremo:

| | Fotogramas con texto | Caracteres indexados |
|---|---|---|
| Antes (320 px) | 11 | 378 |
| Ahora (1024 px) | **41** | **15.458** |

También se probó un pase barato `.fast` como filtro previo (≈6 ms contra ≈70 ms)
para solo pagar el caro donde hubiera algo. Se descartó: sobre una cotización
escaneada el pase rápido devolvía **cero** líneas donde el preciso encontraba
cinco. Un documento así es justo lo que alguien busca, y perderlo para ahorrar
siete segundos por cada diez minutos de video es un mal negocio. Queda como
opción (`screenVideoText`), apagada.

---

## Por qué el indexador corre a lo ancho, pero no del todo

La primera versión de esto sí paralelizaba, y **se trababa**. Una muestra de
pila lo dejó claro: todos los hilos parados en

```
-[VNControlledCapacityTasksQueue dispatchSyncByPreservingQueueCapacity:]
```

Vision despacha por una cola con capacidad limitada, y cuando se llena **bloquea
el hilo que llama**. El pool cooperativo de Swift tiene aproximadamente un hilo
por núcleo y no crece para cubrir hilos bloqueados, así que con suficientes
peticiones concurrentes no quedaba ni un hilo libre para drenar la cola que
todos esperaban.

La conclusión que se sacó entonces fue demasiado amplia, y costó cara. Se
documentó que «el reconocimiento de texto no escala» y se fijaron dos techos:
dos peticiones de Vision y cuatro trabajos a la vez. Vuelto a medir con cuidado
en una M4 de 10 núcleos, 40 fotogramas reales de 1024 px con `.accurate`:

| profundidad | tiempo | por fotograma |
|---|---|---|
| 1 | 6,16 s | 154 ms |
| 2 | 3,11 s | 78 ms |
| 4 | 2,14 s | 53 ms |
| 8 | 1,35 s | 34 ms |
| 12 | 1,46 s | 37 ms |

Vision **sí escala**, 4,6× hasta la rodilla. Y como el OCR resultó ser el 93%
del pase visual completo (14,1 s de un reel de diez minutos; 0,9 s con el OCR
apagado), aquel techo estaba estrangulando el costo dominante de la aplicación.

### Lo que sí es un límite real

Subir el techo destapó un fallo que no es nuestro. Por encima de unas tres
peticiones simultáneas, `RecognizeTextRequest` corrompe memoria dentro del
propio framework de Apple al liberar resultados:

```
EXC_BAD_ACCESS (SIGSEGV) — KERN_INVALID_ADDRESS
objc_release ← TextRecognition ← swift_release_dealloc ← Vision ×10
```

Medido reindexando los mismos seis reels y contando salidas distintas de cero:

| profundidad | corridas caídas |
|---|---|
| 2 | 0/20 |
| 3 | 0/20 |
| 4 | 2/10 |
| 8 | 5/10 |

Es dependiente de la dosis y **no** depende de cuántos workers corran: dos de
profundidad con doce workers está limpio; ocho de profundidad con cuatro workers
no. Pasar por `ImageRequestHandler` en vez de `perform(on:)` no cambia nada
(5/10 igual). Sacar MobileCLIP del Neural Engine tampoco, así que no es disputa
por el acelerador.

Y la profundidad no es el único gatillo: **el solapamiento también lo es**.
Vision a profundidad 8 sola sobrevive; Vision a profundidad 8 con Core ML
corriendo en paralelo muere. Por eso `VisionGate` hace ahora dos cosas: acota
cuántas peticiones de Vision corren a la vez, y **garantiza que la codificación
de imágenes de Core ML nunca se solape con ellas**. La exclusividad es casi
gratis — un lote de 8 embeddings son ~40 ms contra ~530 ms de OCR del mismo
lote — y es la diferencia entre un indexador que termina y uno que revienta en
una biblioteca de cada siete.

El techo, entonces, es 2. No es una preferencia de rendimiento: subirlo es un
cambio de corrección, y hay una prueba que lo fija.

### El cuello de botella que sí era nuestro

Con Vision acotada, el resto del trabajo seguía sin correr a lo ancho — y ahí el
culpable era el diseño propio. `Indexer` es un `actor`, y decodificar, embeber,
generar miniaturas y escribir en SQLite eran métodos aislados en él. Doce
workers no hacían nada que uno solo no hiciera:

```
203 fotos, sin OCR:   1 worker → 7,6 s    4 → 6,3 s    12 → 6,3 s
```

Ese es el actor serializando todo el trabajo síncrono, sin importar cuántos
workers se pidan. Sacar el pipeline del actor lo arregla:

```
203 fotos, sin OCR:   1 worker → 8,1 s    4 → 2,7 s    12 → 2,0 s
```

Sacarlo destapó, a su vez, el mismo problema de bloqueo una capa más abajo:
`MLModel.predictions(fromBatch:)` es síncrono y **estaciona su hilo** en un
semáforo esperando al Neural Engine. Doce workers aparcaron los diez hilos
cooperativos dentro de Core ML y el indexador se detuvo en seco a 0% de CPU. Por
eso Core ML pasa hoy por el mismo portón, en exclusiva.

### Las tres reglas que quedan

- **`VisionGate`** — Vision compartida hasta 2; Core ML en exclusiva. Es un
  guardia de corrección, no una perilla de velocidad.
- **`WorkBudget`** — acota los *fotogramas decodificados vivos*, no los trabajos.
  Una foto sostiene un fotograma; un pase de video sostiene un lote entero. Con
  una sola cifra de concurrencia había que elegir bando: 4 workers dejaban el
  60% de la máquina ociosa con fotos, y 8 costaban 80 MB de más con video sin
  ganar nada. Contando fotogramas, la memoria pico deja de depender de qué haya
  en la cola.
- **`DecodeGate`** — acota cuántos originales a resolución completa se
  decodifican a la vez. ImageIO tiene que materializar la imagen entera antes de
  devolver una miniatura de 1024 px, así que una foto de 12 MP ocupa unos 48 MB
  un instante; una docena de workers haciéndolo a la vez es medio giga de pico.

### Lo medido, de punta a punta

Mismo hardware, cachés derivadas borradas entre corridas, mediana de tres:

| carga | antes | ahora |
|---|---|---|
| 203 fotos de 12 MP | 17,9 s · 193 MB | **13,9 s · 221 MB** |
| 18 min de 1080p (6 archivos) | 10,9 s · 202 MB | **11,1 s · 178 MB** |

Las fotos bajan un 30%; el video queda igual en tiempo y baja 24 MB de pico. El
video no mejora porque es OCR de punta a punta, y el OCR está donde Apple lo
deja. Es un resultado honesto, no el que se buscaba: **el siguiente paso real es
sacar el OCR a procesos aparte**, donde varios ayudantes a profundidad 2
multiplican el rendimiento y además contienen el fallo de Apple en vez de
tumbar la aplicación. Nada de lo de arriba lo impide.

Ninguna de estas cifras es una promesa universal: son de esta máquina y de estas
muestras.

---

## Bibliotecas grandes y archivos de muchas horas

El tamaño en gigabytes no debe convertir cada revisión de carpeta en un nuevo
análisis. WhereFilm separa descubrir cambios de procesar contenido:

- Un archivo con la misma ruta, tamaño y fecha de modificación se reconoce sin
  abrir el contenedor, volver a calcular su identidad ni decodificar video. Una
  prueba usa un `.mov` disperso de 8 GB que no es un video válido: la segunda
  exploración termina bien precisamente porque nunca intenta abrirlo.
- FSEvents solo despierta al catálogo; una exploración incremental y acotada es
  la fuente de verdad. Un renombre en Finder actualiza nombre, ruta y búsqueda
  sin reiniciar WhereFilm.
- El límite de 4.000 fotogramas se reparte sobre toda la duración. Antes, con
  muestras cada 5 s, un video de más de 5 h 33 min quedaba silenciosamente
  truncado; ahora un archivo de 12 horas cubre las 12 horas a ~10,8 s.
- La transcripción usa una cola acotada de ocho buffers PCM. El lector espera al
  reconocedor en lugar de guardar en RAM el audio decodificado de un archivo de
  varias horas.

Medición sintética en la M4 de desarrollo: una hora de AAC silencioso se
transcribió en 9,4 s con ~35 MB de memoria máxima; diez minutos de voz en español
en 3,7 s con ~37 MB, conservando 50 bloques temporales de aproximadamente 12 s.
Son números de esta máquina y de esas muestras, no una promesa universal de
rendimiento.

---

## Convivir con DaVinci Resolve

Honestidad primero: **ningún análisis de IA es gratis.** Lo que sí se puede es
que el indexador tenga prioridad mínima y se quite de en medio.

- Core ML fijado a `.cpuAndNeuralEngine` — evita deliberadamente la GPU que el
  editor está castigando.
- Workers desechables: el modelo se carga, procesa un lote, y se libera.
- El governor se consulta **antes de cada trabajo**: estado térmico, Low Power
  Mode, batería, y si Resolve/Premiere/FCP están abiertos o al frente.
- Con batería **sigue indexando** imágenes y texto, con la mitad de workers.
  Antes bajaba a solo-metadatos, y en una laptop eso significaba un índice que
  nunca llegaba a ser buscable: archivos contados, cero momentos, para siempre.
  La transcripción, que sí es cara, espera al enchufe; por debajo del 25% de
  carga se detiene todo menos lo casi gratis.
- Sin editor abierto, con corriente y temperatura normal, Smart acelera el
  descubrimiento entre discos y deja que la cola precaliente la caché. Con un
  editor abierto conserva metadatos, visual y OCR, pero deja transcripción y
  hash completo para después.
- `Pause · 2h` en la barra de menús es real para indexado y escaneo, y se reactiva solo.

---

## Primera apertura, y los $99 de Apple

Esta edición está firmada *ad-hoc*, no con un Developer ID de pago, y no está
notarizada. La consecuencia está **medida, no supuesta**: se le pone al `.dmg`
la misma marca de cuarentena que pone un navegador y se le pregunta al sistema.

```
$ xattr -w com.apple.quarantine "0083;…;Safari;" WhereFilm.dmg
$ spctl -a -vvv WhereFilm.app
WhereFilm.app: rejected
```

Así que en otra Mac la primera apertura necesita una aprobación manual:
**Configuración del Sistema › Privacidad y seguridad › Abrir de todas formas.**
Una sola vez, y macOS lo recuerda.

No hay sustituto gratuito de Developer ID + notarización, y aquí no se intenta
desactivar ni evadir Gatekeeper: la app simplemente se aprueba una vez, por la
persona dueña de la Mac. Con una licencia de Apple, `make-dmg.sh` solo necesita
cambiar la identidad de firma y añadir `notarytool`.

## Estado

Funciona de punta a punta, verificado en un MacBook Air M4 con material real:
búsqueda visual en inglés y español, transcripción en español con timestamps,
OCR, detección de archivos movidos y borrados, previews offline. 69 pruebas
pasando.

El bundle se verifica con un comando, simulando una Mac limpia — sin modelos
instalados y con un índice vacío — y dejando que la app haga todo el recorrido
sola: escanear, indexar, buscar, dibujar.

```bash
./Scripts/verify-release.sh
```

Seis casos, y los negativos cuentan igual que los positivos: *"un plato de
espagueti"* sobre una biblioteca de paisajes tiene que devolver **cero**, no el
paisaje menos malo.

La app se autorretrata y se autoinspecciona desde su propio proceso
([`Snapshot.swift`](Sources/WhereFilmApp/Snapshot.swift)): reporta la geometría
de la ventana, los resultados y sus previews, y sale con código 1 si algo falla.
Deliberadamente no usa captura de pantalla ni las APIs de accesibilidad — una
captura fotografía lo que haya en el monitor, que es una superficie de privacidad
que una herramienta de búsqueda no tiene por qué abrir.

El benchmark versionado de español y el informe before/after viven en
[`Benchmarks/spanish-search-v1.json`](Benchmarks/spanish-search-v1.json) y
[`docs/PERFORMANCE-PASS-2026-09-02.md`](docs/PERFORMANCE-PASS-2026-09-02.md).
El trabajo futuro general sigue en [`docs/PLAN.md`](docs/PLAN.md).

## La página

`site/` es un proyecto Astro 7 + Tailwind 4, estático salvo por una mejora
progresiva pequeña que distingue Mac de otras plataformas. Si el navegador
entrega la arquitectura, también muestra Intel o Apple Silicon; la descarga es
universal y no depende de acertar esa señal. La ventana de la app en el hero no
es una captura: está reconstruida en
CSS ([`AppMockup.astro`](site/src/components/AppMockup.astro)), así que se
mantiene nítida en retina, refluye en un teléfono con container queries, pesa
kilobytes en lugar de megabytes, y no redistribuye los fondos de pantalla de
Apple que se usan como material de prueba. La consulta, los nombres y los
porcentajes que muestra son la salida real de `verify-release.sh`.

```bash
cd site
npm install
npm run dev        # http://localhost:4321
npm run build      # → site/dist
```

Para desplegarla en Vercel basta con importar el repositorio: el
[`vercel.json`](vercel.json) de la raíz instala y construye dentro de `site/` y
publica `site/dist`, así que funciona sin tocar nada en el panel. Antes esto
dependía de acordarse de poner **Root Directory = `site`** a mano, y cuando no
estaba puesto el despliegue moría con `Could not read package.json` — Vercel
buscaba un `package.json` en la raíz, donde nunca hubo uno. Si el Root Directory
*sí* está en `site`, manda [`site/vercel.json`](site/vercel.json), que lleva las
mismas cabeceras; cualquiera de los dos caminos produce el mismo sitio.

Al publicar una versión nueva, el orden importa: **primero** subir los binarios
a GitHub Releases y **después** mover `downloadURL` y `releaseURL` en
[`index.astro`](site/src/pages/index.astro). Al revés, la página queda con un
botón de descarga que devuelve 404.

Los iconos y la tarjeta de Open Graph se derivan del icono maestro con
`swift Scripts/make-brand-assets.swift` — antes la página servía el master de
1254 px como logo de 40 px, 1,4 MB para dibujar un favicon.

## Documentación

- [`docs/PLAN.md`](docs/PLAN.md) — el plan completo: decisiones, fases, riesgos, costos
- [`docs/decisions/`](docs/decisions/) — seis ADRs con el porqué de cada elección
- [`docs/RESEARCH-NOTES.md`](docs/RESEARCH-NOTES.md) — de dónde salió todo esto
- [`docs/PERFORMANCE-PASS-2026-09-02.md`](docs/PERFORMANCE-PASS-2026-09-02.md) — baseline, benchmark, calidad, recursos y límites del pase de velocidad

## Licencia y créditos

Código bajo MIT. Los pesos no se guardan en Git, pero la release descargable sí
incluye MobileCLIP para que funcione sin una segunda descarga. Apple limita ese
modelo a investigación y desarrollo académico **no comercial**; por eso esta
edición es una vista previa experimental para evaluación personal, no una
versión que se pueda vender ni integrar en un producto comercial. El acuerdo y
la atribución exigida viajan dentro de la app y están en
[`ThirdPartyLicenses/APPLE-MOBILECLIP-LICENSE.txt`](ThirdPartyLicenses/APPLE-MOBILECLIP-LICENSE.txt).
`Scripts/fetch-models.sh` obtiene MobileCLIP de `apple/coreml-mobileclip` y el
vocabulario CLIP de `openai/clip-vit-base-patch32`.

Referencias que valieron la pena estudiar: Peakto (búsqueda conversacional con
discos desconectados), Adobe Media Intelligence (análisis local cacheable),
Axle AI e Iconik (*catalog in place*), `openara-ai/media-search-agent`,
`chn-lee-yumi/MaterialSearch`, Fennec Search, CLIP-Finder2, PrivateLens.
