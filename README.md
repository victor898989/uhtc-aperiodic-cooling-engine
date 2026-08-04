# uhtc-aperiodic-cooling-engine
Quasicrystals 6D / UHTC Aperiodic insulation. Lattice of tantalum microfibers in zirconium matrix and modified boron silicate to block diffusive oxygen percolation. Cooling System ActivoLEAP71_LatticeLibrary Orchestration of heat exchange networks.

# Book-of-crystalography:https://www.xray.cz/kryst/struktury.pdf

# UHTC Aperiodic Cooling Engine

![C# 12](https://img.shields.io/badge/C%23-12-blue)
![C++ 20](https://img.shields.io/badge/C%2B%2B-20-blue)
![Xilinx XRT](https://img.shields.io/badge/Xilinx-XRT-red)
![Vitis AIE](https://img.shields.io/badge/Vitis-AI_Engine-orange)
![PikoGK](https://img.shields.io/badge/Runtime-PikoGK-green)
![LEAP71](https://img.shields.io/badge/Framework-LEAP71-purple)

**UHTC Aperiodic Cooling Engine** es un framework de diseño computacional y aceleración hardware diseñado para la generación de estructuras monolíticas cerámicas de ultra-alta temperatura (UHTC). 

El sistema combina **geometrías aperiódicas cuasicristalinas en 6D** para bloquear la percolación difusiva del oxígeno atómico ($O_2$), redes **TPMS/Giroides** para refrigeración activa regenerativa, y un motor de **voxelización implícita nativa (0% error de cordal)** paralelizado mediante la capa de runtime **Xilinx XRT** y **Vitis AI Engines (AIE)**.

---

## 📁 Repository Structure

```text
uhtc-aperiodic-cooling-engine/
├── .devcontainer/
│   └── devcontainer.json        # VSCode Codespaces Environment (C# 12, C++20, Xilinx XRT)
├── docs/
│   ├── books/                   # PDF References (De Graef & McHenry, ECSS Design)
│   ├── materials/               # Notes on UHTC, Modified Boron Silicate, ZrB2/Ta
│   └── architecture/            # Software and Data Flow Diagrams
├── src/
│   ├── CSharp/                  # C# orchestration (LEAP71, PikoGK bridge, physics)
│   ├── Native/                  # Existing CUDA/FPGA runtime and kernels
│   ├── Slices/                  # Legacy slice/bits-map tooling
│   ├── core/
│   │   ├── fields/              # Campos escalares: densidad, temperatura, porosidad
│   │   ├── geometry/            # Import/export de mallas, volúmenes
│   │   └── math/                # Kernels matemáticos: gradientes, divergencia, laplaciano
│   ├── cuda/
│   │   ├── kernels/             # Kernels CUDA: voxelización, dilatación, erosión, ∇T
│   │   ├── runtime/             # Gestión de memoria GPU, streams, pipelines
│   │   └── nanovdb/             # Integración con NanoVDB (OpenVDB en GPU)
│   ├── slicing/
│   │   ├── png16/               # Export slices 16-bit
│   │   └── marching/            # Marching cubes / marching tetrahedra
│   └── io/
│       ├── json/                # Configuración
│       └── bin/                 # Formatos binarios (OpenVDB IO)
├── configs/
│   ├── voxel_config.json
│   ├── thermal_config.json
│   └── slicing_config.json
├── tests/
│   ├── geometry/
│   ├── thermal/
│   └── cuda/
├── tasks/
│   └── TASKS.md
├── cmake/
├── build/
├── LICENSE
└── README.md                    # Main Project Documentation
```
