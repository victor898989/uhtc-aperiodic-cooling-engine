# UHTC Aperiodic Cooling Engine — Architecture

## Global Integration Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    C# Engine Layer                          │
│  - Aperiodic lattices / geometric generation (ShapeKernel) │
│  - ThermalSimulationBridge (managed Span<T> memory)        │
└──────────────────────────────┬──────────────────────────────┘
                                 │ P/Invoke (unsafe pointers)
                                 ▼
┌─────────────────────────────────────────────────────────────┐
│              UhtcNativeEngine.dll (C++ Bridge)              │
└──────────────┬──────────────────────────────┬───────────────┘
                 │                              │
                 ▼                              ▼
┌─────────────────────────────┐  ┌────────────────────────────┐
│  CUDA Engine (GPU Host)     │  │  ZCU104 Driver (Embedded)  │
│  - 3D kinetic solver        │  │  - /dev/uio0 memory mapped │
│  - O₂ diffusion–reaction    │  │  - AXI4-Lite control       │
└─────────────────────────────┘  └─────────────┬──────────────┘
                                                 │
                                                 ▼
                                   ┌────────────────────────────┐
                                   │  HLS Kernel (PL ZCU104)    │
                                   │  - AXI4-Stream laser input │
                                   │  - PWM galvo output        │
                                   └────────────────────────────┘
```

## Layer responsibilities

### C# Engine Layer
- **Engine.Cooling**: Gyroid, Lidinoid, and split-void TPMS lattice generation.
- **Engine.Crystallography**: Aperiodic quasicrystal SDFs (Penrose, Ammann-Beenker).
- **Engine.ShapeKernel**: LEAP 71 modulation utilities (splines, surface modulation).
- **Interop.ThermalSimulationBridge**: Managed facade over all native calls; owns native
  handle lifetimes; exposes `Span<T>`-based APIs with no heap allocation for hot paths.

### UhtcNativeEngine.dll (C++ Bridge)
- Single C-linkage ABI (`NativeEngineAPI.h`) shared by all backends.
- Routes calls to CUDA when a GPU is present, otherwise to a scalar CPU fallback.
- Owns the opaque handle store (`UhcThermalHandle`, `UhcDepositHandle`, etc.).
- Compiled as `libuhtc_native_accel.so` (Linux) or `UhtcNativeEngine.dll` (Windows).

### CUDA Engine
- **`uhc_kinetic_solver.cu`** — 3D transient heat diffusion with Gaussian laser source,
  Newtonian convection, and Stefan-Boltzmann radiation at the top surface.
- **`uhc_oxygen_diffusion.cu`** — Arrhenius O₂ diffusion–reaction equation on the
  temperature field returned by the kinetic solver. Produces a time-to-breach map.
- **`uhc_material_properties.h`** — Polynomial fits for ZrB₂, TaC, HfC (k, ρ, c_p, ε)
  valid 300 K – 3500 K.
- **`uhc_deposition.cu`** — Layer-by-layer powder activation and density tracking.
- NanoVDB grids store all fields compactly on GPU; 7-point Laplacian stencil.

### ZCU104 Driver (Embedded)
- Opens the FPGA PL via XRT (`xrt::kernel` / `xrt::bo`) and `/dev/uio0` UIO mmap.
- AXI4-Lite register map at physical address 0x80000000 (configurable via `UhcFpgaConfig`).
- Streams `UhcLaserCommand` packets to the PL AXI4-Stream interface.
- Polls `UhcThermalReading` from the PL at up to 1 kHz.
- Asserts emergency stop when the FPGA raises the thermal-runaway flag.

### HLS Kernel (PL ZCU104)
- `laser_controller_kernel`: PID-controlled laser power with hard-wired safety limits.
- AXI DTPI debug probes (`dp_laser_power`, `dp_galvo_x/y`, `dp_temperature`) for
  real-time waveform capture in Vitis HLS debugger.
- Rate limiter prevents dP/dt > 200 W/s to avoid shock-loading the optics.

## Data flow

```
C# geometry engine
    │  UhcParams, lattice points, scan-path segments
    ▼
ThermalSimulationBridge
    │  P/Invoke → libuhtc_native_accel.so
    ▼
NativeEngineAPI (C-linkage)
    ├──► uhc_evaluate_sdf()        → barrier_flag, k_cond, o2_time
    ├──► uhc_pid_laser_scan()      → P_eff [W], e_stop flag
    ├──► uhc_thermal_create/step() → T_field [K] on CUDA
    ├──► uhc_o2barrier_evaluate()  → t_breach [s]
    └──► uhc_fpga_write_laser_stream() → AXI4-Stream → ZCU104 PL
                                              │
                                        laser_controller_kernel
                                              │
                                        DAC → galvo mirrors
                                        PWM → laser driver
```

## Build system

| Target | Toolchain | Output |
|---|---|---|
| `uhtc_native_accel` | CMake + NVCC (CUDA 12.x) | `build/lib/libuhtc_native_accel.so` |
| `uhtc_xrt_kernels` | Vitis v++ (OBJECT) | `uhtc_laser.o` for linking |
| `uhtc_laser.xclbin` | Vitis v++ (link) | `build/xclbin/uhtc_laser.xclbin` |
| `UhtcAperiodicCoolingEngine` | `dotnet build` | `bin/Debug/net8.0/*.dll` |

## Repository layout

```
uhtc-aperiodic-cooling-engine/
├── src/
│   ├── CSharp/
│   │   ├── Engine.Cooling/          # TPMS lattices (Gyroid, Lidinoid, etc.)
│   │   ├── Engine.Crystallography/  # Aperiodic quasicrystal SDFs
│   │   ├── Engine.ShapeKernel/      # LEAP 71 modulation utilities
│   │   └── Interop/
│   │       ├── UnsafeNativeMethods.cs  # DllImport declarations
│   │       └── ThermalSimulationBridge.cs  # Managed facade
│   ├── Native/
│   │   ├── Common/                  # FindOpenVDB, FindJemalloc cmake modules
│   │   ├── Cuda/
│   │   │   ├── uhc_material_properties.h   # k(T), ρ(T), c_p(T), ε(T)
│   │   │   ├── uhc_kinetic_solver.cu        # 3D transient heat diffusion
│   │   │   ├── uhc_oxygen_diffusion.cu       # O₂ Arrhenius diffusion–reaction
│   │   │   ├── uhc_deposition.cu             # Powder-bed layer activation
│   │   │   ├── uhc_oxygen_barrier.cu         # Tortuosity + barrier metric
│   │   │   ├── uhc_native_api.h              # C-linkage API header
│   │   │   ├── uhc_native_api.cu             # C-linkage API implementation
│   │   │   ├── nanovdb.cu                    # NanoVDB particle benchmark
│   │   │   ├── dilate_nanovdb_cuda.cpp       # Grid morphology benchmark
│   │   │   ├── OpenDB_Examples/              # Coarsening benchmark
│   │   │   └── [OpenVDB math headers]        # Vec3, Mat, Maps, Operators, DDA
│   │   ├── FPGA/
│   │   │   ├── Bridge/
│   │   │   │   ├── NativeEngineAPI.h         # Unified C contract
│   │   │   │   └── NativeEngineAPI.cpp       # CUDA/FPGA/CPU routing
│   │   │   ├── hls/
│   │   │   │   ├── laser_controller.cpp      # HLS kernel (AXI DTPI + PID)
│   │   │   │   ├── kernel.cpp               # SDF evaluation kernel (HLS)
│   │   │   │   └── uhc_fpga_types.h         # UHTCParams POD struct
│   │   │   └── drivers/
│   │   │       ├── zcu104_driver.cpp         # UIO mmap + XRT host driver
│   │   │       └── xrt_host_driver.cpp       # Alveo XRT host driver
│   │   └── PikoGK/                  # PicoGK voxelisation runtime
│   ├── Docs/
│   │   └── USER_GUIDE.md            # End-user documentation
│   └── Slices/                      # Bitmap export CLI
├── build/                           # cmake build artefacts
├── CMakeLists.txt                   # Top-level CMake (add_subdirectory)
├── src/Native/CMakeLists.txt        # Unified native build
├── UHTCEngine.sln                   # .NET solution
└── .devcontainer/
    └── devcontainer.json            # Codespace / devcontainer config
```

## Physics summary

| Phenomenon | Equation | Solver location |
|---|---|---|
| Heat diffusion | ρ·c_p·∂T/∂t = ∇·(k∇T) + Q_laser − Q_conv − Q_rad | CUDA `uhc_kinetic_solver.cu` |
| O₂ transport | ∂C/∂t = ∇·(D(T)∇C) − k₀·exp(−Ea_r/RT)·[O₂]^n | CUDA `uhc_oxygen_diffusion.cu` |
| Oxygen barrier | t_pen = (t_wall·τ)² / D_eff > t_layer | CUDA `uhc_oxygen_barrier.cu` |
| Aperiodic SDF | Gyroid / Lidinoid / SplitVoid | CPU fallback + FPGA HLS |
| Laser PID | P = Kp·e + Ki·Σe + Kd·Δe | FPGA PS or CPU fallback |
