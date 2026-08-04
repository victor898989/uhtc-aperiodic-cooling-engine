# Análisis de interconexión AXI (script TCL)

Objetivo: verificar que la interconexión AXI del sistema puede mover bloques NanoVDB sin cuellos de botella.

## Día 3 — Ejecutar análisis AXI

### 3.1 Preparación
- Tener un diseño implementado en Vivado/Vitis.
- Exportar el diseño `.xsa` o `.bit`.
- Abrir Vivado TCL Console o usar `vivado -mode batch`.

### 3.2 Script de análisis
Ejecutar el script `src/Native/FPGA/axi_dtpi/analyze_axi_interconnect.tcl`.

El script:
- Inspecciona la interconexión AXI
- Lista amos/esclavos
- Detecta: FIFOs, RegSlices, convertidores de protocolo, convertidores de reloj, muestras, convertidores de ancho de datos
- Imprime tablas con la configuración AXI

### 3.3 Verificaciones obligatorias
- [ ] FIFO presente entre AXI DMA y memoria
- [ ] RegSlice en el camino de datos
- [ ] Convertidor de protocolo si hay AXI4-Lite ↔ AXI4-Stream
- [ ] Convertidor de reloj si hay dominios diferentes
- [ ] Longitud de burst ≥ tamaño de bloque NanoVDB / ancho de datos
- [ ] No hay ráfagas estrechas ( Narrow Burst ) que degraden el ancho de banda

### 3.4 Diagnóstico rápido
| Síntoma | Causa probable | Solución |
|---------|----------------|----------|
| Ancho de banda bajo | Falta RegSlice | Insertar RegSlice en el camino |
| Datos corruptos | Falta convertidor de reloj | Agregar clock domain crossing |
| Timeout | FIFO pequeño | Aumentar depth del FIFO |
| Burst cortos | Configuración por defecto | Ajustar `max_burst_len` en AXI DMA |

## Día 4 — Conexión con el pipeline CUDA

### Mapeo de datos
```
NanoVDB GridHandle
    → device pointer
    → AXI DMA (buffer lineal)
    → FPGA (procesamiento)
    → resultado → host
```

### Checklist final
- [ ] Script TCL pasa sin errores
- [ ] AXI DMA puede transferir bloques de 64KB (típico para NanoVDB)
- [ ] Clock domains están aislados correctamente
- [ ] No hay overflow en FIFOs con carga máxima
