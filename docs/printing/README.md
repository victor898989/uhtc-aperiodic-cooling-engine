# 3D Printing Engine

## Overview

The 3D Printing Engine is the **heart of the manufacturing system**. It defines how parts are fabricated, generates voxels, slices, thermal fields, and produces the files that industrial printers actually use.

> If OpenVDB is not working, you cannot manufacture anything—no matter how good your FPGA or rocket design is.

## Supported Industrial Printers

| Printer | Type | Build Volume (mm³) | Lasers | Max Power |
|---------|------|-------------------|--------|-----------|
| EOS M400-4 | LPBF | 400×400×400 | 4 | 400 W |
| SLM Solutions NXG XII 600 | LPBF | 600×600×600 | 12 | 1000 W |
| Renishaw RenAM 500Q | LPBF | 250×250×300 | 4 | 500 W |
| Arcam EBM Q20+ | EBM | 200×200×380 | 1 | 3000 W |
| DMG Mori Lasertec 4300 | DED | 500×500×430 | 1 | 4000 W |
| Lithoz CeraFab S65 | Ceramic Vat | 65×65×75 | - | UV 385nm |

## Supported Materials

| Material | Type | Density (kg/m³) | Melting Point (°C) | Application |
|----------|------|-----------------|-------------------|-------------|
| Inconel 718 | Superalloy | 8190 | 1336 | Hot section, turbine blades |
| Ti-6Al-4V | Titanium alloy | 4420 | 1660 | Aerospace structures |
| UHTC (ZrB2/TaC) | Ceramic composite | 6100 | 3245 | Leading edges, nose cones |
| Monolithic Woven II | Aperiodic CMC | 7500 | 3200 | Oxygen barrier, thermal protection |
| Modified Boron Silicate | Ceramic | 2200 | 1650 | Insulation, thermal barrier |

## Architecture

```text
src/printing/
├── printers/          # Printer profiles and machine parameters
│   ├── EOS_M400_4.h
│   ├── SLM_NXG_XII_600.h
│   ├── Renishaw_RenAM_500Q.h
│   ├── Arcam_EBM_Q20_Plus.h
│   ├── DMG_Mori_Lasertec_4300.h
│   └── Lithoz_CeraFab_S65.h
├── materials/         # Material models and properties
│   ├── Inconel718.h
│   ├── Ti64.h
│   ├── UHTC.h
│   ├── MonolithicWovenII.h
│   └── AdvancedCeramic.h
├── pipeline/          # Manufacturing pipeline stages
│   ├── Pipeline.h
│   └── Pipeline.cpp
└── wov2/             # Monolithic Woven II material implementation
    └── WovenII.h
```

## Manufacturing Pipeline

```text
Geometry Input (STL/OBJ/VDB)
    ↓
Voxelization (FloatGrid/NanoVDB)
    ↓
Thermal Simulation (∇T, heat transfer)
    ↓
Slicing (16-bit PNG, marching cubes)
    ↓
Path Planning (laser trajectories, scan strategy)
    ↓
Export (printer-ready files)
```

### Stage 1: Geometry Input
- Import STL, OBJ, or VDB files
- Validate mesh quality (watertight, manifold)
- Compute bounding box and voxel grid resolution

### Stage 2: Voxelization
- Convert triangle mesh to scalar field
- Generate FloatGrid with density values
- Apply narrow band for memory efficiency
- Convert to NanoVDB for GPU processing

### Stage 3: Thermal Simulation
- Apply material thermal properties
- Simulate laser heat input
- Compute temperature gradients (∇T)
- Account for conduction, convection, radiation

### Stage 4: Slicing
- Generate 16-bit PNG slices
- Apply marching cubes for surface extraction
- Optimize slice height for printer resolution

### Stage 5: Path Planning
- Generate laser scan vectors
- Optimize hatch spacing
- Apply scan strategy (stripes, islands, chessboard)

### Stage 6: Export
- Write `geometry_voxels.bin`
- Write `thermal_field.bin`
- Write `slice_XXXX.png` sequence
- Generate printer-specific control files

## Integration with OpenVDB / NanoVDB / CUDA

```
OpenVDB (CPU)
    ↓ geometry_voxels.bin
NanoVDB (GPU)
    ↓ GridHandle, device pointer
CUDA Kernels
    ↓ voxelization, thermal, slicing
AXI DMA
    ↓ linear buffer transfer
FPGA (XRT)
    ↓ laser control, motion
Printer Hardware
```

## Monolithic Woven II

The Woven II material uses a **quasicrystal-inspired aperiodic structure** to block oxygen diffusion:

- **6D hypercube projection** → 3D density field
- **Tantalum microfibers** → reinforcement network
- **ZrB2/TaC matrix** → high-temperature stability
- **Oxygen blocking efficiency**: >99%
- **Tortuosity**: >5×

### Structure Generation

```cpp
#include "wov2/WovenII.h"

printing::wov2::WovenIIConfig cfg;
cfg.golden_ratio = 1.618033988749895;
cfg.dimension = 6;
cfg.fiber_diameter = 50.0;  // μm
cfg.fiber_spacing = 100.0;  // μm

float density = printing::wov2::aperiodic_density(x, y, z, cfg);
double tort = printing::wov2::tortuosity(cfg);
double blocking = printing::wov2::blocking_efficiency(cfg);
```

## Configuration

Printer-specific configurations are in `configs/print/`:
- `eos_m400_4_inconel718.json`
- `slm_nxg_ti64.json`
- `arcam_ebm_q20_ti64.json`
- `lithoz_cerafab_ceramic.json`

## Tests

- `tests/printing/printing_materials_smoke.cpp` - Material property validation
- `tests/printing/printer_profiles_smoke.cpp` - Printer profile validation
- `tests/printing/wov2_structure_smoke.cpp` - Woven II structure generation
