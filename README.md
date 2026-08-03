# uhtc-aperiodic-cooling-engine
Quasicrystals 6D / UHTC Aperiodic insulation. Lattice of tantalum microfibers in zirconium matrix and modified boron silicate to block diffusive oxygen percolation. Cooling System ActivoLEAP71_LatticeLibrary Orchestration of heat exchange networks.

uhtc-aperiodic-cooling-engine/
├── .devcontainer/
│ └── devcontainer.json # VSCode Codespaces Environment (C# 12, C++20, Xilinx XRT)
├── docs/
│ ├── books/ # PDF References (De Graef & McHenry, ECSS Design)
│ ├── materials/ # Notes on UHTC, Modified Boron Silicate, ZrB2/Ta
│ └── architecture/ # Software and Data Flow Diagrams
├── src/
│ ├── Core/
│ │ ├── Quasicrystals/ # Generators of 6D aperiodic geometries and Golden Rhombohedra
│ │ └── Materials/ # Models of O₂ degradation, tortuosity, and CTE gradient
│ ├── Cooling/
│ │ └── Lattice/ # Integration with LEAP71_LatticeLibrary (Gyroids/TPMS)
│ ├── Macro/
│ │ └── ShapeKernel/ # Integration with LEAP71_ShapeKernel (Aerothermal envelopes)
│ ├── Runtime/
│ │ ├── PikoGK/ # Implicit volumetric engine and Voxel rendering
│ │ └── OpenDVB/ # C++ runtime abstraction layer for continuous geometry
│ └── Acceleration/
│ ├── XRT/ # Xilinx Runtime Layer (C++ Host Code)
│ ├── Kernels/ # PL acceleration kernels (Vivado/HLS)
│ └── AIE/ # Parallelized algorithms for Vitis AI Engine (Versal ACAP)
├── tests/
│ ├── Physics/ # Monte Carlo for O₂ tortuosity and thermomechanical analysis (∇T)
│ ├── Geometry/ # Testbenches for airtightness and 0% error chordal
│ └── Hardware/ # XRT/AIE Performance Benchmarks
├── slices/ # Direct Bitmap Export (PNG 16-bit/CLI)
├── LICENSE
└── README.md # Main Project Documentation
