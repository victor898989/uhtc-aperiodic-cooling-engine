# UHTC Aperiodic Cooling Engine — Testing Guide

## Quick Reference

```bash
# Run all tests (requires .NET 8, CUDA 12.x, CMake 3.18+)
./scripts/master_test.sh

# Run fast tests only (no FPGA, no CUDA compile)
./scripts/master_test.sh --quick

# Run specific suites
./scripts/run_tests.sh --csharp    # C# xUnit tests only
./scripts/run_tests.sh --native    # CUDA + C API tests only
./scripts/run_tests.sh --cmake     # CMake configure smoke test only
```

---

## 1. Environment Prerequisites

### 1.1 Required Tools

| Tool | Minimum Version | Install Command (Ubuntu 22.04) | Purpose |
|---|---|---|---|
| .NET SDK | 8.0 | `wget https://dot.net/v1/dotnet-install.sh && bash dotnet-install.sh --channel 8.0` | C# compilation + xUnit tests |
| CMake | 3.18 | `sudo apt install cmake` | Native build system |
| GCC/G++ | 9.0 | `sudo apt install build-essential` | C++ compilation |
| CUDA Toolkit | 12.0 | [NVIDIA CUDA Download](https://developer.nvidia.com/cuda-downloads) | GPU kernel compilation |
| NVIDIA Driver | >= 525 | `sudo apt install nvidia-driver-525` | GPU runtime |
| Python 3 | 3.8 | `sudo apt install python3` | Validation scripts |
| Git | 2.0 | `sudo apt install git` | Version control |

### 1.2 Optional FPGA Tools

| Tool | Version | Install | Purpose |
|---|---|---|---|
| Vitis HLS | 2024.1+ | [Xilinx Download](https://www.xilinx.com/support/download/index.html) | FPGA kernel synthesis |
| XRT | 2024.1+ | `sudo apt install xrt` | Alveo/ZCU104 runtime |
| ZCU104 UIO drivers | — | Pre-loaded on ZCU104 | `/dev/uio0` memory-mapped access |

### 1.3 Verify Installation

```bash
# Check all tools
dotnet --version          # Should show 8.0.x
cmake --version          # Should show 3.18+
nvcc --version           # Should show Cuda 12.x
nvidia-smi               # Should show GPU model and driver
gcc --version            # Should show 9.x or later
python3 --version        # Should show 3.8+
vitis_hls --version      # Optional: shows Vitis version
xbutil examine           # Optional: shows FPGA devices
```

---

## 2. Complete Test Process (All Components)

### 2.1 Step 1 — Clone and Restore

```bash
cd /workspace
git clone https://github.com/your-org/uhtc-aperiodic-cooling-engine.git
cd uhtc-aperiodic-cooling-engine

# Restore C# dependencies
cd src/CSharp
dotnet restore UhtcAperiodicCoolingEngine.csproj
dotnet restore Tests/UhtcEngine.Tests.csproj
cd ../..
```

### 2.2 Step 2 — Build Native Library (CUDA)

```bash
# Configure
mkdir -p build && cd build
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DUHC_BUILD_BRIDGE=ON \
  -DCMAKE_CUDA_ARCHITECTURES="70;75;80;86"

# Build
cmake --build . --config Release --parallel $(nproc)

# Verify output
ls -lh libuhtc_native_accel.so
# Expected: libuhtc_native_accel.so (10-50 MB)
```

### 2.3 Step 3 — Build and Run CUDA Kernel Tests

```bash
# Build test harness
cmake --build . --config Release --target uhc_cuda_test_harness --parallel $(nproc)

# Run
./src/Native/uhc_cuda_test_harness

# Expected output:
# ============================================
#   UHTC CUDA Kernel Unit Tests
# ============================================
# [TEST] material_properties
#   PASS: ZrB2 k @ 300 K
#   PASS: TaC k @ 300 K
#   ...
# ============================================
#   ALL TESTS PASSED
# ============================================
```

### 2.4 Step 4 — Build and Run C API Smoke Test

```bash
# Build
cmake --build . --config Release --target uhc_api_smoke_test --parallel $(nproc)

# Run
./src/Native/uhc_api_smoke_test

# Expected output:
# === UHC API Smoke Test ===
#   PASS: uhc_initialize(AUTO) returns 0
#   PASS: k_ZrB2(300K) in [50, 200] W/m·K
#   PASS: uhc_evaluate_sdf(3 points) returns 0
#   PASS: uhc_pid_laser_scan returns 0
# === Results ===
#   ALL CHECKS PASSED
```

### 2.5 Step 5 — Run C# xUnit Tests

```bash
cd src/CSharp

# Build tests
dotnet build Tests/UhtcEngine.Tests.csproj --no-restore

# Run tests
dotnet test Tests/UhtcEngine.Tests.csproj --no-build --logger "console;verbosity=detailed"

# Expected output:
# Passed!  - Failed:     0, Passed:    38, Skipped:     0, Total:    38
```

### 2.6 Step 6 — FPGA Vitis HLS Compile (Alveo/ZCU104)

```bash
# Find Vitis include path
VITIS_INC=$(find /opt -name "ap_axi_sdata.h" 2>/dev/null | head -1 | xargs dirname)

# Compile HLS kernel
vitis_hls \
  -I src/Native/FPGA/hls \
  -I src/Native/FPGA/Bridge \
  -I "$VITIS_INC" \
  -std=c++17 \
  -D__SYNTHESIS__ \
  -c -o build/laser_controller_hls.o \
  src/Native/FPGA/hls/laser_controller.cpp

# Expected: laser_controller_hls.o (no errors)
```

### 2.7 Step 7 — Build FPGA Bitstream (Vitis v++)

```bash
# For ZCU104
v++ -t hw -k laser_controller_kernel \
    --platform xilinx_zcu104_base \
    -I src/Native/FPGA/hls \
    -I src/Native/FPGA/Bridge \
    -c src/Native/FPGA/hls/laser_controller.cpp \
    -o build/laser_controller.o

# Link xclbin
v++ -t hw -l build/laser_controller.o \
    --platform xilinx_zcu104_base \
    -o build/xclbin/uhtc_laser.xclbin

# For Alveo U250
v++ -t hw -k laser_controller_kernel \
    --platform xilinx_u250_gen3x16_xdma_2_1_202010_1 \
    -c src/Native/FPGA/hls/laser_controller.cpp \
    -o build/laser_controller_alveo.o

v++ -t hw -l build/laser_controller_alveo.o \
    --platform xilinx_u250_gen3x16_xdma_2_1_202010_1 \
    -o build/xclbin/uhtc_laser_alveo.xclbin
```

### 2.8 Step 8 — FPGA Hardware Test (ZCU104)

```bash
# Verify device is detected
xbutil examine
# Should show: Device[0000]:03:00.0 (xilinx_zcu104_base)

# Program FPGA
xbutil program -p build/xclbin/uhtc_laser.xclbin

# Verify AXI Lite registers via /dev/uio0
sudo devmem 0x80000000 32 0x1   # Write LASER_ENABLE = 1
sudo devmem 0x80000004 32 0x1F4 # Write POWER_SETPOINT = 500 W
sudo devmem 0x8000000C 32        # Read THERMAL_FEEDBACK (temperature)
```

### 2.9 Step 9 — Integration Test (C# → Native → FPGA)

```bash
# Set library path
export LD_LIBRARY_PATH=$PWD/build/lib:$LD_LIBRARY_PATH

# Run from C#
cd src/CSharp
dotnet run --project UhtcAperiodicCoolingEngine.csproj

# Or run the integration test directly
dotnet test Tests/UhtcEngine.Tests.csproj --filter "FullyQualifiedName~Integration"
```

---

## 3. Test Commands Cheat Sheet

### C# Tests

```bash
# Restore
dotnet restore src/CSharp/UhtcAperiodicCoolingEngine.csproj
dotnet restore src/CSharp/Tests/UhtcEngine.Tests.csproj

# Build
dotnet build src/CSharp/Tests/UhtcEngine.Tests.csproj --no-restore

# Run all tests
dotnet test src/CSharp/Tests/UhtcEngine.Tests.csproj --no-build

# Run specific test class
dotnet test src/CSharp/Tests/UhtcEngine.Tests.csproj --filter "FullyQualifiedName~StructLayoutTests"

# Run with detailed output
dotnet test src/CSharp/Tests/UhtcEngine.Tests.csproj --logger "console;verbosity=detailed"
```

### CUDA Tests

```bash
# Configure
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DUHC_BUILD_BRIDGE=ON

# Build test harness
cmake --build build --config Release --target uhc_cuda_test_harness -j$(nproc)

# Run
./build/src/Native/uhc_cuda_test_harness

# Build API smoke test
cmake --build build --config Release --target uhc_api_smoke_test -j$(nproc)

# Run
./build/src/Native/uhc_api_smoke_test

# Run all ctest tests
cd build && ctest --output-on-failure
```

### CMake Tests

```bash
# Configure smoke test
cmake -B build/cmake_smoke -S . -DCMAKE_BUILD_TYPE=Release

# List all targets
cmake --build build/cmake_smoke --target help

# Build specific target
cmake --build build --config Release --target uhtc_native_accel -j$(nproc)
```

### FPGA Tests

```bash
# Check FPGA device
xbutil examine
xbutil2 examine --dump

# Program FPGA
xbutil program -p build/xclbin/uhtc_laser.xclbin

# Verify kernel loaded
xbutil examine --device 0000:03:00.0 --format json | grep -i "uuid"

# Run host driver test
./build/src/Native/FPGA/drivers/zcu104_host_test
```

---

## 4. Environment Variables

```bash
# Required for C# to find native library
export LD_LIBRARY_PATH=$PWD/build/lib:${LD_LIBRARY_PATH:-}

# Required for CUDA
export PATH=/usr/local/cuda/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}

# Required for Vitis HLS
export PATH=/opt/Xilinx/Vitis/2024.1/bin:${PATH}
source /opt/Xilinx/Vitis/2024.1/settings64.sh

# Required for XRT
export LD_LIBRARY_PATH=/opt/xilinx/xrt/lib:${LD_LIBRARY_PATH:-}
export XILINX_XRT=/opt/xilinx/xrt
```

---

## 5. Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `dotnet: command not found` | .NET SDK not installed | Install from https://dotnet.microsoft.com/download |
| `nvcc: command not found` | CUDA not installed or PATH wrong | `export PATH=/usr/local/cuda/bin:$PATH` |
| `libuhtc_native_accel.so: cannot open` | LD_LIBRARY_PATH missing | `export LD_LIBRARY_PATH=$PWD/build/lib:$LD_LIBRARY_PATH` |
| `CMAKE_CUDA_COMPILER not found` | CMake can't find nvcc | Install CUDA toolkit, ensure nvcc is in PATH |
| `xbutil: command not found` | XRT not installed | `sudo apt install xrt` |
| `/dev/uio0: Permission denied` | User not in gpio group | `sudo usermod -aG gpio $USER` (log out/in) |
| `vitis_hls: command not found` | Vitis not installed or PATH wrong | `source /opt/Xilinx/Vitis/2024.1/settings64.sh` |
| CUDA kernel launch failure | Insufficient GPU memory | Reduce grid resolution in test parameters |
| `DllNotFoundException` at runtime | Native .so not in LD_LIBRARY_PATH | Set LD_LIBRARY_PATH before running C# |

---

## 6. CI/CD Reference

The GitHub Actions workflow (`.github/workflows/build.yml`) runs these steps automatically on every push:

```yaml
# C# tests
- dotnet restore src/CSharp/UhtcAperiodicCoolingEngine.csproj
- dotnet build src/CSharp/UhtcAperiodicCoolingEngine.csproj --no-restore
- dotnet restore src/CSharp/Tests/UhtcEngine.Tests.csproj
- dotnet build src/CSharp/Tests/UhtcEngine.Tests.csproj --no-restore
- dotnet test src/CSharp/Tests/UhtcEngine.Tests.csproj --no-build

# Native tests (CUDA)
- cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DUHC_BUILD_BRIDGE=ON
- cmake --build build --config Release --parallel
- ./build/src/Native/uhc_cuda_test_harness
- ./build/src/Native/uhc_api_smoke_test

# CMake smoke
- cmake --build build --config Release --target help
```

---

## 7. Test Coverage Map

| Component | Test File | Test Method | Tool |
|---|---|---|---|
| Struct layout (P/Invoke ABI) | `StructLayoutTests.cs` | `Marshal.SizeOf`, `Marshal.OffsetOf` | xUnit |
| Material properties | `MaterialPropertyTests.cs` | `MatThermalConductivity`, `MatSpecificHeat`, etc. | xUnit + native bridge |
| SDF geometry | `SdfGeometryTests.cs` | Gyroid, Lidinoid, SplitVoid, `EvaluateSdf` | xUnit |
| Bridge lifecycle | `ThermalBridgeTests.cs` | `Initialize`, `Shutdown`, `OpenFpgaDevice` | xUnit |
| CUDA material functions | `uhc_test_kernels.cu` | `test_material_properties()` | CUDA kernel harness |
| CUDA laser source | `uhc_test_kernels.cu` | `test_laser_gaussian()` | CUDA kernel harness |
| CUDA O₂ diffusion | `uhc_test_kernels.cu` | `test_oxygen_diffusion()` | CUDA kernel harness |
| CUDA thermal stencil | `uhc_test_kernels.cu` | `test_thermal_stencil()` | CUDA kernel harness |
| CUDA deposition states | `uhc_test_kernels.cu` | `test_deposition_state_machine()` | CUDA kernel harness |
| C API smoke | `test_api_smoke.c` | All `uhc_*` functions | C executable |
| CMake targets | `master_test.sh` | `--target help` parsing | Bash + CMake |
| FPGA HLS compile | `master_test.sh` | `vitis_hls` invocation | Vitis HLS |

---

## 8. One-Liner Quick Test

```bash
# Full test suite (all components)
./scripts/master_test.sh

# Quick smoke test (no FPGA, no CUDA build — fastest)
./scripts/master_test.sh --quick

# Equivalent to CI's native test job
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DUHC_BUILD_BRIDGE=ON && \
cmake --build build --config Release --parallel && \
cd build/src/Native && \
./uhc_cuda_test_harness && \
./uhc_api_smoke_test
```
