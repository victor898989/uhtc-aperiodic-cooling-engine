# 3D Printing Engine

## Overview

This module is the **heart of the 3D printing system**. It defines how parts are manufactured, generates voxels, slices, thermal fields, and produces the files that industrial printers actually use.

If OpenVDB is not working, you cannot manufacture anything—no matter how good your FPGA or rocket design is.

## Supported Industrial Printers

- EOS M400-4 (LPBF)
- SLM Solutions NXG XII 600 (LPBF)
- Renishaw RenAM 500Q (LPBF)
- Arcam EBM Q20+ (EBM)
- DMG Mori Lasertec 4300 (DED hybrid)
- Lithoz CeraFab S65 (advanced ceramics)

## Supported Materials

- Inconel 718
- Ti-6Al-4V (Ti64)
- UHTC (ZrB2/TaC)
- Monolithic Woven II
- Ceramics (modified boron silicate)

## Architecture

```text
src/printing/
├── printers/          # Printer profiles and machine parameters
├── materials/         # Material models and properties
├── pipeline/          # Manufacturing pipeline stages
├── wov2/             # Monolithic Woven II material implementation
```

## Pipeline

1. **Geometry Input** → STL/OBJ/VDB
2. **Voxelization** → FloatGrid/NanoVDB
3. **Thermal Simulation** → Temperature field
4. **Slicing** → 16-bit PNG slices
5. **Path Planning** → Laser trajectories
6. **Export** → Printer-ready files
