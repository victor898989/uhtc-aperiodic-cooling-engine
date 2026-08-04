# TASKS.md

## Plan de análisis y pruebas (4 días)

### Día 1 — Archive.cc: estado de stream, metadatos y archivo mapeado
- [ ] Revisar `StreamMetadata` como registro de control AXI-Lite.
- [ ] Revisar `StreamState` como puntero de buffer circular.
- [ ] Revisar `MappedFile` (boost::interprocess) como MMU/scatter-gather.
- [ ] Documentar hallazgos en `docs/architecture/openvdb_io_analysis.md`.

### Día 2 — Compresión volumétrica y carga diferida
- [ ] Analizar `PopulateDelayedLoadMetadataOp` (descriptores DMA por hoja).
- [ ] Analizar `writeCompressedValuesSize` (planificación de bursts AXI).
- [ ] Verificar que los tamaños de bloque coinciden con ancho de datos AXI (64/128 bits).
- [ ] Documentar hallazgos en `docs/architecture/openvdb_io_analysis.md`.

### Día 3 — Interconexión AXI
- [ ] Cargar diseño implementado en Vivado.
- [ ] Ejecutar `src/Native/FPGA/axi_dtpi/analyze_axi_interconnect.tcl`.
- [ ] Verificar FIFOs, RegSlices, convertidores de protocolo/reloj/ancho de datos.
- [ ] Verificar longitudes de burst ≥ tamaño de bloque NanoVDB.
- [ ] Documentar resultados en `docs/architecture/axi_interconnect_analysis.md`.

### Día 4 — Conectar OpenVDB → NanoVDB → AXI DMA → FPGA → XRT
- [ ] Validar pipeline: OpenVDB produce `geometry_voxels.bin` y `thermal_field.bin`.
- [ ] Validar conversión NanoVDB `GridHandle` → buffer lineal en GPU.
- [ ] Validar AXI DMA transfiere bloques de 64KB.
- [ ] Validar núcleo XRT procesa voxeles en PL.

## Módulo 1 — Geometría y voxelización
- [ ] Importar mallas STL/OBJ y convertir a campo de densidad implícita.
- [ ] Verificar error de cuerda < 1 voxel en conversión implícita.
- [ ] Exportar `geometry_voxels.bin` desde `src/io/bin`.

## Módulo 2 — Térmica
- [ ] Implementar gradiente térmico ∇T en `src/core/math/`.
- [ ] Acoplar solver térmico a campos de densidad y porosidad.
- [ ] Exportar `thermal_field.bin`.

## Módulo 3 — Slicing
- [ ] Generar rebanadas 16-bit en `src/slicing/png16/`.
- [ ] Implementar Marching Cubes/Tetrahedra en `src/slicing/marching/`.
- [ ] Validar secuencia `slice_XXXX.png` para FPGA.

## Módulo 4 — CUDA / NanoVDB
- [ ] Mover kernels CUDA a `src/cuda/kernels/`.
- [ ] Gestionar memoria GPU y streams en `src/cuda/runtime/`.
- [ ] Verificar dilatación/erosión volumétrica con NanoVDB.

## Pruebas obligatorias
- [ ] `tests/geometry` — error de cuerda y cierre topológico.
- [ ] `tests/thermal` — gradiente y conservación de energía.
- [ ] `tests/cuda` — humo de kernels y rendimiento.
- [ ] `tests/geometry/openvdb_io_smoke_test` — humo OpenVDB IO.
- [ ] `tests/cuda/nanovdb_smoke_test` — humo NanoVDB CUDA.
- [ ] `tests/printing` — materiales, perfiles de impresora, Woven II.

## Módulo 5 — Motor de Impresión 3D (src/printing/)

### Perfiles de impresora
- [x] EOS M400-4 (LPBF)
- [x] SLM Solutions NXG XII 600 (LPBF)
- [x] Renishaw RenAM 500Q (LPBF)
- [x] Arcam EBM Q20+ (EBM)
- [x] DMG Mori Lasertec 4300 (DED)
- [x] Lithoz CeraFab S65 (Ceramic)

### Modelos de material
- [x] Inconel 718
- [x] Ti-6Al-4V (Ti64)
- [x] UHTC (ZrB2/TaC)
- [x] Monolithic Woven II
- [x] Advanced Ceramic (modified boron silicate)

### Pipeline de fabricación
- [ ] `src/printing/pipeline/Pipeline.h` — etapas del pipeline
- [ ] `src/printing/pipeline/Pipeline.cpp` — implementación
- [ ] Integración con OpenVDB para voxelización
- [ ] Integración con CUDA para slicing acelerado
- [ ] Export de `geometry_voxels.bin`, `thermal_field.bin`, `slice_XXXX.png`

### Woven II específico
- [x] Generador de estructura aperiódica 6D
- [x] Cálculo de tortuosidad
- [x] Cálculo de eficiencia de bloqueo de oxígeno
- [ ] Validación con Monte Carlo de difusión O2

### Pruebas end-to-end
- [ ] Mesh → Voxels → NanoVDB → Dilatación → Export binario
- [ ] CUDA kernel launch + memory round-trip
- [ ] Pipeline completo: geometry → slices → thermal → export
