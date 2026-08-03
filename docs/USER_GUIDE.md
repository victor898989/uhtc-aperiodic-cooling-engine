# UHTC Aperiodic Cooling Engine — User Guide

## Overview

This engine simulates and controls laser powder-bed fusion (L-PBF) of ultra-high-temperature ceramics (UHTC) with aperiodic lattice oxygen barriers. The aperiodic geometry is the primary defence against oxygen ingress during the high-temperature build.

The software stack has three layers:

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
│  - 3D kinetic solver        │  │  - /dev/uio0 memory-mapped │
│  - O2 diffusion field       │  │  - AXI4-Lite control       │
└─────────────────────────────┘  └─────────────┬──────────────┘
                                                 │
                                                 ▼
                                   ┌────────────────────────────┐
                                   │  HLS Kernel (PL ZCU104)    │
                                   │  - AXI4-Stream laser input │
                                   │  - PWM galvo output        │
                                   └────────────────────────────┘
```

## Prerequisites

| Component | Minimum version | Purpose |
|---|---|---|
| .NET SDK | 8.0 | C# geometry engine |
| CUDA Toolkit | 12.x | Thermal and O₂ diffusion kernels |
| CMake | 3.18 | Native library build |
| Vitis HLS | 2024.1 | FPGA kernel compilation (optional) |
| ZCU104 board | — | Real-time laser control (optional) |
| NVIDIA GPU | Compute Capability 7.0 | CUDA acceleration |

## Quick Start

### 1. Clone and restore

```bash
git clone https://github.com/your-org/uhtc-aperiodic-cooling-engine.git
cd uhtc-aperiodic-cooling-engine
dotnet restore src/CSharp/UhtcAperiodicCoolingEngine.csproj
```

### 2. Build the native library

```bash
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

Output: `build/lib/libuhtc_native_accel.so` (Linux) or `build/bin/UhtcNativeEngine.dll` (Windows).

### 3. Run a thermal simulation from C#

```csharp
using UhtcAperiodicCoolingEngine.Interop;

// 1. Initialise the native engine (auto-selects CUDA, then CPU)
NativeBridge.Initialize(UhcBackend.Auto);

// 2. Define material parameters (ZrB2-SiC baseline)
var parameters = new UhcParams
{
    GeometryType   = 0,           // Gyroid
    Freq           = 0.8f,        // 1/mm
    WallThickness  = 0.25f,
    Tortuosity     = 3.5f,
    TMeltK         = 3523.0f,     // ZrB2 melting point [K]
    MaterialId     = 0,           // ZrB2
    LaserPowerW    = 500.0f,
    LaserEta       = 0.35f,       // absorptivity
    ScanSpeedMmS   = 5.0f,
    EllipseX       = 2.5f,
    EllipseY       = 2.5f,
    EllipseZ       = 1.0f
};

// 3. Generate lattice points (from C# geometry engine)
ReadOnlySpan<float> points = GenerateLatticePoints(shape, resolution: 32);

// 4. Evaluate the SDF field on GPU
Span<float> sdf     = new float[points.Length / 3];
Span<float> barrier = new float[points.Length / 3];
Span<float> kCond   = new float[points.Length / 3];
Span<float> laserQ  = new float[points.Length / 3];
Span<float> o2Time  = new float[points.Length / 3];

NativeBridge.EvaluateSdf(points, sdf, barrier, kCond, laserQ, o2Time,
                         points.Length / 3, in parameters);

// 5. Check oxygen barrier integrity
int sealedVoxels = barrier.Count(b => b > 0.5f);
Console.WriteLine($"O₂-sealed voxels: {sealedVoxels}/{points.Length/3}");

// 6. Run the thermal diffusion solver on CUDA
IntPtr thermalHandle = NativeBridge.ThermalCreate(voxelSizeMm: 0.5f);
NativeBridge.ThermalSetLaser(thermalHandle, in laserSource);
NativeBridge.ThermalSetChamber(thermalHandle, in chamberParams);
NativeBridge.ThermalInitialiseMaterial(thermalHandle, materialId: 0);
NativeBridge.ThermalStep(thermalHandle, nSteps: 100);

// 7. Read back the temperature field
Span<float> temperature = new float[nVoxels];
NativeBridge.ThermalReadTemperature(thermalHandle, temperature, nVoxels);
NativeBridge.ThermalDestroy(thermalHandle);
```

### 4. FPGA real-time laser control (ZCU104)

```csharp
// Open the ZCU104 device
var config = new UhcFpgaConfig
{
    XclbinPath    = "/path/to/uhtc_laser.xclbin",
    DeviceIndex   = 0,
    AxiLiteAddr   = 0x80000000,   // physical base of AXI Lite IP
    ClockMHz      = 100.0f,
    Flags         = 0x1            // enable thermal feedback
};

IntPtr fpga = NativeBridge.FpgaOpen(in config);

// Stream laser commands (AXI4-Stream packet format)
Span<UhcLaserCommand> cmds = stackalloc UhcLaserCommand[nSegments];
for (int i = 0; i < nSegments; i++)
{
    cmds[i] = new UhcLaserCommand
    {
        PowerW   = (ushort)P_eff[i],
        GalvoX   = (ushort)path[i].X,
        GalvoY   = (ushort)path[i].Y,
        ModFreq  = 0
    };
}
NativeBridge.FpgaWriteLaserStream(fpga, cmds, nSegments);

// Read thermal feedback
Span<UhcThermalReading> readings = stackalloc UhcThermalReading[64];
NativeBridge.FpgaReadThermal(fpga, readings, readings.Length);

// Check emergency stop
if (NativeBridge.FpgaGetEmergencyStop(fpga) != 0)
    Console.WriteLine("EMERGENCY STOP: thermal runaway detected");

NativeBridge.FpgaClose(fpga);
```

## Configuration Reference

### UhcParams (geometry + material)

| Field | Unit | Typical value | Description |
|---|---|---|---|
| GeometryType | enum | 0 | 0=Gyroid, 1=Lidinoid, 2=SplitVoidGyroid |
| Freq | 1/mm | 0.8 | Unit-cell spatial frequency |
| WallThickness | unitless | 0.25 | SDF offset |
| Tortuosity | — | 3.5 | Aperiodic path-length factor |
| TCriticalMm | mm | 0.08 | Minimum wall to block O₂ |
| TMeltK | K | 3523 | Melt-pool target temperature |
| LaserPowerW | W | 500 | Nominal laser power |
| LaserEta | 0-1 | 0.35 | Absorptivity at 1070 nm |
| ScanSpeedMmS | mm/s | 5 | Scan speed |
| EllipseX/Y/Z | mm | 2.5 | Gaussian spot radii |

### UhcChamberParams (boundary conditions)

| Field | Unit | Typical value |
|---|---|---|
| TSubstrateK | K | 300 |
| TAmbientK | K | 300 |
| HConv | W/m²·K | 10 |
| LayerTimeS | s | 2.0 |
| DtFixed | s | 1e-5 |

### O₂ diffusion equation

The oxygen transport model solved on the CUDA grid:

```
∂C_O2/∂t = ∇·(D(T) ∇C_O2) − R_ox(T, C_O2)

where:
  D(T)   = D₀ · exp(−Ea / (R·T))      Arrhenius diffusivity
  R_ox   = k₀ · exp(−Ea_r / (R·T)) · [O₂]^n   oxidation rate
  D₀     = 0.209 cm²/s  (O₂ in Ar at 273 K)
  Ea     = 15.2 kJ/mol  (activation energy for O₂ in UHTC)
  k₀     = 1.5e8 s⁻¹    (pre-exponential oxidation rate)
  Ea_r   = 285 kJ/mol   (activation energy for ZrB₂ oxidation)
  n      = 0.5          (reaction order)
```

### Oxygen barrier criterion

The aperiodic lattice blocks oxygen ingress when:

```
t_penetration = (t_wall · τ)² / D_eff  >  t_layer

where:
  D_eff = D₀ · φ / τ²
  φ     = void fraction (0.35 for Gyroid)
  τ     = tortuosity
  t_wall = minimum wall thickness [mm]
```

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `NativeLibraryNotFound` | `libuhtc_native_accel.so` not on `LD_LIBRARY_PATH` | `export LD_LIBRARY_PATH=$PWD/build/lib:$LD_LIBRARY_PATH` |
| CUDA kernel launch fails | Insufficient GPU memory | Reduce grid resolution or voxel count |
| FPGA e-stop triggers | Thermal runaway threshold exceeded | Lower `LaserPowerW` or increase scan speed |
| Low O₂ barrier score | Wall thickness below `TCriticalMm` | Increase `WallThickness` or `Tortuosity` |
| Poor surface finish | Excessive scan speed | Reduce `ScanSpeedMmS` or increase `LaserPowerW` |

## Material Database

| Material | ID | T_melt [K] | k @ 25°C [W/m·K] | cp [J/g·K] | ρ [g/cm³] |
|---|---|---|---|---|---|
| ZrB₂ | 0 | 3519 | 120 | 0.42 | 6.09 |
| TaC | 1 | 4215 | 30 | 0.32 | 14.5 |
| HfC | 2 | 4231 | 28 | 0.33 | 12.0 |
| ZrB₂ powder | 3 | 3519 | ~3 | 0.42 | 3.3 |
| TaC powder | 4 | 4215 | ~2 | 0.32 | 7.9 |
| HfC powder | 5 | 4231 | ~1.5 | 0.33 | 6.6 |

Powder values are at 55 % theoretical density after spreading.

## FPGA Register Map (ZCU104 AXI Lite)

| Offset | Register | Access | Description |
|---|---|---|---|
| 0x00 | LASER_ENABLE | R/W | Bit 0 = laser on/off |
| 0x04 | POWER_SETPOINT | R/W | float: commanded laser power [W] |
| 0x08 | T_CRITICAL | R/W | float: thermal runaway threshold [K] |
| 0x0C | THERMAL_FEEDBACK | R | float: last temperature reading [K] |
| 0x10 | EMERGENCY_STOP | R | bit 0 = e-stop active |
| 0x14 | PID_KP | R/W | float: PID proportional gain |
| 0x18 | PID_KI | R/W | float: PID integral gain |
| 0x1C | PID_KD | R/W | float: PID derivative gain |
| 0x20 | GALVO_X | R/W | uint16: galvo X DAC count |
| 0x24 | GALVO_Y | R/W | uint16: galvo Y DAC count |
| 0x30 | STATUS | R | uint32: bit0=e-stop, bit1=thermal, bit2=FPGA ready |

## Building the FPGA Bitstream (Vitis)

```bash
# 1. Prepare the HLS kernel object
v++ -t hw -k laser_controller_kernel \
    --platform xilinx_zcu104_base \
    -I src/Native/FPGA/hls \
    -I src/Native/FPGA/Bridge \
    -c src/Native/FPGA/hls/laser_controller.cpp \
    -o uhtc_laser.o

# 2. Link the xclbin
v++ -t hw -l uhtc_laser.o \
    --platform xilinx_zcu104_base \
    -o build/xclbin/uhtc_laser.xclbin

# 3. Program the device from C#
var config = new UhcFpgaConfig { XclbinPath = "build/xclbin/uhtc_laser.xclbin", ... };
NativeBridge.FpgaOpen(in config);
```

## License

Apache-2.0. See `LICENSE`.
