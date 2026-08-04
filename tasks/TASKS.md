# TASKS.md

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
