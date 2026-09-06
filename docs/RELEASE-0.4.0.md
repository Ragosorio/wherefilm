# WhereFilm 0.4.0

La release que aprende quién es quién, y la que por fin puede demostrar si
busca mejor.

## Lo nuevo

**Personas.** WhereFilm agrupa las caras que se repiten y te deja ponerles
nombre desde la app. Buscar «Jorge Álvarez» devuelve dónde aparece, con el
timecode. Aguanta acentos y errores de dedo: `Alvares` encuentra `Álvarez`.
Opcional, apagado por defecto, y con un borrado que borra de verdad — caras,
grupos, nombres y apariciones, sin tocar archivos, momentos, transcripciones ni
búsquedas.

**Quién habla, no solo quién sale.** Diarización de voces que se agrupan entre
archivos distintos, y un puente que propone qué voz corresponde a qué cara según
el tiempo que comparten en pantalla. Confirmarlo es decisión tuya. Requiere
Apple Silicon y una descarga única que se pide a mano.

**Intel de verdad.** macOS 26 es la última versión que corre en Macs Intel, y
esta es la primera que lo trata como objetivo y no como suposición. La app
pregunta a la máquina qué es en vez de deducirlo de la cuenta de núcleos, cede
la GPU cuando hay un editor abierto, y cae de `SpeechTranscriber` —ausente en
procesos x86_64— a `DictationTranscriber`, que conserva los timestamps sin los
cuales «salta al 14:16» no existe.

**Llevar un disco indexado a otra Mac.** `sidecar export` / `sidecar import`
mueven el catálogo de un volumen —momentos, vectores, transcripciones, texto en
pantalla, etiquetas y timecodes— sin volver a leer un solo original. No viajan
las caras, ni las voces, ni el historial de uso, ni los permisos de la Mac
origen.

**Se quita de en medio.** El trabajo de disco corre con prioridad reducida, y
hay una ventana horaria: «solo entre las 11 pm y las 7 am» es lo que alguien con
treinta terabytes realmente quiere.

## Lo que mejoró por dentro

- **OCR 1,4× más rápido** y, sobre todo, contenido: Vision corre en procesos
  aparte, así que el fallo conocido de `RecognizeTextRequest` mata un ayudante de
  30 MB en vez de la aplicación que llevaba indexando toda la noche. Medido sobre
  60 páginas de texto: 17,7 s → 12,6 s, con salida OCR idéntica.
- **Los filtros que se calculaban y se tiraban** ahora se aplican: «fotos de la
  boda» filtra a fotos, una fecha filtra por fecha — y solo cuando las palabras
  no pueden significar otra cosa.
- **El español ya no depende de un diccionario de 300 palabras.** Se traduce con
  el traductor del sistema, offline, que además existe en las Macs sin Apple
  Intelligence. En ese camino, las consultas sin sentido que devolvían algo
  bajaron del 88% al 38%.
- **Un resultado flojo ya no puede mostrar 100%.** Los canales se combinan de
  forma que nada puede pasar de 1, y el piso visual subió de 0,14 a 0,18: los
  falsos positivos se redujeron a la mitad.
- **Etiquetas de escena** de la propia taxonomía de Vision, sobre fotogramas que
  ya estaban decodificados.

## Medir, que era lo que faltaba

`wherefilm eval` mide **calidad** —recall, MRR, nDCG, falsos positivos y
calibración— contra un set etiquetado, y `wherefilm calibrate` mide qué vale una
similitud en tu biblioteca en vez de heredar el número de otra.

Con eso se pudo comprobar que tres ideas prometedoras **no** funcionaban, y
quedan documentadas con sus números en vez de convertirse en folclore:
re-rankear con un modelo más grande, juzgar por z-score, y centrar en ambos
lados. El informe completo está en `docs/PRECISION-PASS-2026-09-05.md`.

## Distribución

`.dmg` y `.zip` universales para `arm64` y `x86_64`, con checksums. Sigue siendo
una vista previa experimental para evaluación personal y no comercial —
MobileCLIP es el único modelo con licencia de investigación que queda— y sigue
firmada ad-hoc: en otra Mac hace falta aprobarla una vez en Privacidad y
seguridad.

Los modelos de caras y de voces **no** viajan en la descarga. Se instalan a
mano, una sola vez, porque son opcionales y porque uno de ellos es la única
petición de red que hace esta aplicación:

```bash
./Scripts/fetch-face-model.sh      # AuraFace (ArcFace R100, Apache-2.0)
wherefilm voices install           # solo Apple Silicon
```

## Validación

- 141 pruebas en 29 suites.
- `verify-release.sh` pasa los seis casos en `arm64` y, vía Rosetta, en
  `x86_64`.
- Calidad de búsqueda medida de forma determinista (`--no-llm`), sin regresión:
  Recall@10 86%, nDCG@10 0,85.
- Caras medidas sobre fotografías reales de Wikimedia Commons: 26 caras de
  cuatro personas → 16 grupos, 96% de pureza.
