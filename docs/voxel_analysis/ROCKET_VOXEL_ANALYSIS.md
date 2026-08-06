# ============================================================================
# Voxel Analysis for Large UHTC Structures — Rocket / >3000 K
# ============================================================================
#
# This document covers the NanoVDB/OpenVDB voxel engine for large robust
# UHTC structures such as rocket motor chambers, re-entry heat shields,
# and hypersonic leading edges operating above 3000 K.
#
# 1. Problem definition
# 2. Geometry model
# 3. Material model
# 4. Thermal solver (>3000 K)
# 5. Oxygen barrier / lattice insulation
# 6. Mesh / slicer export
# 7. Commands
# 8. Validation
# ============================================================================

## 1. Problem definition

UHTC ceramics (ZrB2, TaC, HfC) are used in extreme thermal environments:
- Rocket motor chambers: 3000–4200 K
- Re-entry heat shields: 2500–3500 K
- Hypersonic leading edges: >3000 K

Key engineering constraints:
- T_melt ZrB2 = 3519 K
- T_melt TaC  = 4215 K
- T_melt HfC  = 4231 K
- Oxygen percolation must be blocked by aperiodic lattice walls
- Thermal gradients can exceed 1000 K/mm in chamber walls

The voxel engine must:
1. Represent large geometries (100–1000 mm scale)
2. Resolve fine lattice features (0.05–0.5 mm wall thickness)
3. Track temperature, material, tortuosity, and wall thickness per voxel
4. Export temperature fields and meshes for downstream slicers

## 2. Geometry model

### 2.1 Rocket chamber SDF

The chamber is constructed from signed distance fields (SDFs):

```
d_nose(x,y,z)    = sdCone(x, y, z - L_nose*0.5, L_nose, R_nose, 0)
d_chamber(x,y,z) = sdCylinder(x, y, z - L_nose, R_outer, L)
d_lattice(x,y,z) = sdGyroid(x, y, z, freq, wall)
d = min(d_nose, d_chamber)
if lattice enabled:
    d = max(d, -d_lattice)   # subtract lattice from solid
```

Where:
- `sdCone` / `sdCylinder` / `sdGyroid` are analytic SDF primitives
- `d < 0` = inside the solid
- `d >= 0` = outside (free space / powder bed)

### 2.2 Voxel grid

| Parameter | Default | Notes |
|-----------|---------|-------|
| voxel_size_mm | 0.5 | 0.05–1.0 mm depending on feature scale |
| chamber_length_mm | 200 | 100–500 mm for motor chambers |
| chamber_radius_mm | 50 | 20–200 mm |
| nose_length_mm | 80 | ogive tip |
| wall_thickness_mm | 5 | structural wall |
| lattice_freq_mm | 2.0 | gyroid frequency (0 = disabled) |
| lattice_wall_thickness | 0.15 | 0.05–0.5 mm |

### 2.3 NanoVDB grid layout

```
Grid dimensions: nx × ny × nz
nx = ceil(2*(R_outer) / dx) + 1
ny = ceil(2*(R_outer) / dx) + 1
nz = ceil((L_nose + L) / dx) + 1

Voxel memory (float32):
  T field:        nx*ny*nz * 4 bytes
  material ID:    nx*ny*nz * 4 bytes
  tortuosity:     nx*ny*nz * 4 bytes
  wall thickness: nx*ny*nz * 4 bytes
  Total:          4 * nx*ny*nz * 4 = 16 * nx*ny*nz bytes

For 256×256×256 grid: ~4.2 GB host, ~4.2 GB device
```

## 3. Material model

Per-voxel material assignment:

| Material ID | Material | T_melt [K] | Use |
|-------------|----------|------------|-----|
| 0 | ZrB2 powder | 3519 | Chamber wall base |
| 1 | TaC | 4215 | Nose cap |
| 2 | HfC | 4231 | Hot spots |
| 3+ | Modified boron silicate | 1900 | Oxidation coating |

Temperature-dependent properties (300–3500 K):

```
k(T)   = max(k_min, a + b*T + c*T²)   [W/(m·K)]
ρ(T)   = ρ_0 / (1 + β*(T - T_0))      [g/cm³]
c_p(T) = a + b*T                        [J/(g·K)]
ε(T)   = ε_0 + ε_1*(T - T_ref)          [0-1]
```

Sources:
- Upadhya et al., JACS 80(11), 1997 (ZrB2)
- Fahrenholtz et al., JACS 90(1), 2007
- Pierson, Handbook of Refractory Carbides, 1996

## 4. Thermal solver (>3000 K)

### 4.1 Governing equation

```
ρ·c_p · ∂T/∂t = ∇·(k ∇T) + Q_combustion - Q_conv - Q_rad
```

Where:
- Q_combustion = volumetric heat source [W/mm³]
- Q_conv = h_conv · (T - T_ambient) [W/m²]
- Q_rad = ε·σ·(T⁴ - T_amb⁴) [W/m²]

### 4.2 Discretisation

- Explicit Euler with adaptive sub-stepping
- 7-point Laplacian stencil
- CFL constraint: dt < dx² / (2 · α_max)
- For dx=0.5 mm, α=1e-5 m²/s → dt < 1.25e-5 s

### 4.3 CUDA kernel

```cuda
__global__ void kernel_rocket_thermal_step(
    float* d_T_new, const float* d_T_old,
    const float* d_k, d_rho, d_cp, d_eps, d_tort, d_thk,
    const int* d_active,
    float T_ambient, float h_conv, float dx,
    int dimX, dimY, dimZ, float dt,
    float Q_combustion)
```

Block size: 8×8×4 = 256 threads/block
Grid size: ceil(dim/8)³

## 5. Oxygen barrier / lattice insulation

### 5.1 Aperiodic gyroid

The lattice is parameterised by:
- Frequency f = 1 / lattice_freq_mm [1/mm]
- Wall thickness w = lattice_wall_thickness [mm]
- Tortuosity τ ≈ 3.5 (measured for gyroid)

### 5.2 Barrier criterion

```
t_diff = (t_wall · τ)² / D_O2
safe   ⇔  t_diff > t_layer

Where:
  D_O2 @ 2000 °C in ZrB2 ≈ 1e-9 mm²/s
  t_layer = layer time [s] (typical 2 s for L-PBF)
```

### 5.3 Thermal penalty

If barrier fails, the kernel applies a 15% increase in heat loss:

```cuda
float barrier_factor = uhc::oxygen_barrier(thk, tort, 2.0f) ? 1.0f : 1.15f;
dT_dt *= barrier_factor;
```

## 6. Mesh / slicer export

### 6.1 OpenVDB mesh extraction

```cpp
openvdb::tools::volumeToMesh(*sdf_grid,
                             points, triangles, quads,
                             0.0, 0.0, false);
```

Output:
- `points`: vertex positions [mm]
- `triangles`: triangle indices
- `quads`: quad faces (converted to triangles)

### 6.2 Slicer integration

The mesh can be exported to:
- STL (via openvdb io)
- 3MF (via PikoGK)
- PNG slices (via marching cubes)

## 7. Commands

### 7.1 Build

```bash
# Full build (requires CUDA 12.x, OpenVDB, NanoVDB)
mkdir -p build && cd build
cmake .. \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.4/bin/nvcc \
  -DNANOVDB_USE_CUDA=ON \
  -DNANOVDB_USE_OPENVDB=ON
make -j$(nproc)

# Or build rocket test standalone
cd /workspaces/uhtc-aperiodic-cooling-engine
nvcc -std=c++17 -DNANOVDB_USE_CUDA \
     -I./src/Native/Cuda \
     -I./third_party/nanovdb/include \
     -I./third_party/openvdb/include \
     src/Native/Cuda/uhc_rocket_structure_api.cu \
     src/Native/Cuda/uhc_rocket_structure.cu \
     tests/cuda/rocket_structure_smoke.cu \
     -o build/bin/rocket_structure_smoke
```

### 7.2 Run

```bash
# Default config
./build/bin/rocket_structure_smoke configs/rocket_structure_config.json

# Custom config
./build/bin/rocket_structure_smoke configs/rocket_structure_config.json \
   2>&1 | tee rocket_log.txt

# Expected output:
# [Rocket] Config loaded: L=200.0 mm R=50.0 mm dx=0.500 mm lattice=ON
# [Rocket] Solver created: 32x32x32
# [Rocket] t=0.001s  T_peak=3100 K (2827 °C)
# [Rocket] t=0.002s  T_peak=3500 K (3227 °C)
# [Rocket] T_field exported -> rocket_T_final.nvdb
# [Smoke] Result: PASS
```

### 7.3 C API usage (from C# / Python via ctypes)

```c
// C API
void* h = rocket_solver_create(&cfg);
rocket_solver_run(h, 1000, 0.001f);
rocket_solver_export_temperature(h, "output.nvdb");
rocket_solver_destroy(h);
```

```python
# Python ctypes example
import ctypes
lib = ctypes.CDLL("./build/lib/libuhtc_native_accel.so")

cfg = RocketConfig()
cfg.chamber_length_mm = 200.0
cfg.chamber_radius_mm = 50.0
cfg.voxel_size_mm = 0.5
cfg.T_ambient_K = 300.0
cfg.dt = 1e-5
cfg.Q_combustion_W_mm3 = 50.0

h = lib.rocket_solver_create(ctypes.byref(cfg))
lib.rocket_solver_run(h, 1000, 0.001)
lib.rocket_solver_export_temperature(h, b"rocket.nvdb")
lib.rocket_solver_destroy(h)
```

### 7.4 VHDL testbench (AXI)

```bash
cd hardware/zcu104/testbenches
make ghdl_run
```

## 8. Validation

### 8.1 Smoke tests

| Test | File | Validates |
|------|------|-----------|
| Rocket config parsing | `rocket_structure_smoke.cu` | JSON load, field bounds |
| Geometry build | `uhc_rocket_structure.cu` | SDF construction, grid dims |
| Material init | `uhc_rocket_structure_api.cu` | k, ρ, c_p, ε at T_ambient |
| Thermal step | `kernel_rocket_thermal_step` | T ∈ [T_ambient, 5000 K] |
| Export | `uhc_rocket_structure.cu` | NanoVDB write succeeds |

### 8.2 Expected results

For default config (L=200 mm, R=50 mm, dx=0.5 mm, lattice ON):
- Grid: 201 × 201 × 561 ≈ 22.7 M voxels
- Peak T after 500 steps (dt=10 µs): ~3500–4200 K
- Memory: ~91 MB host, ~91 MB device
- Runtime: < 5 s on RTX 3080

### 8.3 Performance targets

| Metric | Target |
|--------|--------|
| Grid size | 256³ voxels |
| Step time | < 100 ms (CUDA) |
| Memory | < 1 GB device |
| Export | < 2 s |

## 9. Integration points

### 9.1 Existing code

| Module | Path | Role |
|--------|------|------|
| UHTC material properties | `src/Native/Cuda/uhc_material_properties.h` | k(T), ρ(T), c_p(T), ε(T), barrier |
| NanoVDB examples | `src/Native/Cuda/OpenDB_Examples/nanovdb.cu` | Device upload, particle collision |
| Kinetic solver | `src/Native/Cuda/uhc_kinetic_solver.cu` | 3D thermal step (32³ sphere demo) |
| PicoGK Voxels | `src/Native/PikoGK/.../PicoGKVdbVoxels.h` | Host-side Boolean ops, mesh export |
| PicoGK Fields | `src/Native/PikoGK/.../PicoGKVdbField.h` | ScalarField / VectorField on OpenVDB |
| UHTC material C# | `src/printing/materials/UHTC.h` | T_melt=3245°C, density=6100 kg/m³ |

### 9.2 Missing integrations (TODO)

1. **PicoGK lattice → NanoVDB**: Replace analytic gyroid SDF with PicoGK `RenderLattice` output
2. **OpenVDB IO → C#**: Expose `nanovdb::io::writeGrid` via C API for C# interop
3. **ZCU104 stream → thermal solver**: Feed AXI Stream thermal readings from PL as boundary condition
4. **Python PYNQ overlay**: Load NanoVDB grid on ZCU104 PS for real-time monitoring

## 10. References

- UG1267: ZCU104 Evaluation Board User Guide
- UG961: AXI4-Stream Protocol Reference
- Upadhya et al., JACS 80(11), 1997
- Fahrenholtz et al., JACS 90(1), 2007
- Pierson, Handbook of Refractory Carbides and Nitrides, 1996
- OpenVDB: https://www.openvdb.org/
- NanoVDB: https://github.com/AcademySoftwareFoundation/openvdb/tree/master/src/nanovdb
- PicoGK: https://picogk.org
