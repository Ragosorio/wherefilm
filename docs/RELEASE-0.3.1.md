# WhereFilm 0.3.1

Release de mantenimiento centrada en bibliotecas grandes y en trabajar sin
interrumpir el flujo de edición.

## Incluye

- Gobernador adaptativo de recursos: reduce o pausa el trabajo cuando DaVinci
  Resolve, Adobe, batería, memoria o presión térmica lo requieren, y recupera
  el procesamiento cuando la máquina vuelve a estar disponible.
- Escaneo incremental que evita volver a abrir medios sin cambios, serializa
  trabajo dentro de cada volumen y conserva paralelismo entre discos distintos.
- Reparación segura de filas derivadas huérfanas, detección de movimientos y
  límites de ruta correctos al marcar archivos ausentes.
- Búsqueda con menos trabajo FTS5, caché de embeddings y resultados agrupados,
  manteniendo la cobertura medida del fixture de medios reales.
- Índice de previsualizaciones con escritura por lotes y recuperación de errores
  sin dejar filas de catálogo apuntando a archivos inexistentes.

## Distribución

La descarga incluye un `.dmg` y un `.zip` universales para `arm64` y `x86_64`,
con sus checksums. La aplicación sigue siendo una vista previa experimental
para evaluación personal y no comercial, y continúa usando firma ad-hoc; en
otra Mac requiere la aprobación de macOS en Privacidad y seguridad.

## Validación

- 79 pruebas en 16 suites pasaron.
- La búsqueda conservó Recall@5 y Recall@10 de 100% en el fixture de calidad.
- La compilación Release universal y el smoke test de la aplicación se ejecutan
  antes de publicar esta release.
