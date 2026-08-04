# Análisis guiado de OpenVDB IO (Archive.cc)

Objetivo: entender cómo OpenVDB prepara los voxeles para transmisión hardware, separado en 4 bloques.

## Día 1 — Estado del stream, metadatos y archivo mapeado

### 1.1 `StreamMetadata`
- Es el “registro de control” del stream.
- Guarda: versión de archivo, compresión, clase de grid, puntero a archivo mapeado, metadatos de carga diferida.
- Analogía hardware: registros AXI-Lite que configuran el DMA antes de un burst.

### 1.2 `StreamState`
- Estado interno del stream durante lectura/escritura.
- Permite hacer `seek`, `tell`, y guardar/restaurar posición.
- Analogía hardware: puntero de buffer circular en DRAM.

### 1.3 `MappedFile` (boost::interprocess)
- Mapea el archivo `.vdb` completo en memoria virtual.
- Permite acceso aleatorio sin cargar todo en RAM.
- Analogía hardware: MMU / scatter-gather para streaming volumétrico.

## Día 2 — Compresión y carga diferida

### 2.1 `PopulateDelayedLoadMetadataOp`
- Recorre cada `LeafNode`.
- Por hoja calcula:
  - Máscara de voxeles activos
  - Tamaño comprimido
  - Offset dentro del archivo
- Genera los “descriptores DMA” para cada bloque de voxeles.

### 2.2 `writeCompressedValuesSize`
- Calcula el tamaño exacto de los valores comprimidos.
- Usa `zlib`/`blosc` dependiendo de la configuración.
- Importante para planificar bursts AXI y evitar overflow de FIFO.

## Día 4 — Conexión con NanoVDB y FPGA

### Flujo esperado
1. OpenVDB produce `geometry_voxels.bin` y `thermal_field.bin`
2. NanoVDB convierte a `GridHandle` en GPU
3. AXI DMA mueve bloques desde DRAM a FPGA
4. Núcleo XRT procesa voxeles en PL

### Puntos de verificación
- [ ] Archive.cc compila con `NANOVDB_USE_OPENVDB=1`
- [ ] Los metadatos de carga diferida se generan sin errores
- [ ] El tamaño de bloque coincide con el ancho de datos AXI (64/128 bits)
