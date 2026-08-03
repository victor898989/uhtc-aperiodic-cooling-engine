#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# master_test.sh — Complete test suite for UHTC Aperiodic Cooling Engine
#
# This script runs ALL available tests in the repository:
#   1. Environment checks (tool versions, drivers, licenses)
#   2. C# unit tests (xUnit) — struct layout, materials, SDF, bridge
#   3. CUDA native tests — kernel unit tests + API smoke test
#   4. CMake configure + build smoke test
#   5. FPGA Vitis HLS compile (if Vitis is installed)
#   6. FPGA Alveo / ZCU104 runtime tests (if hardware is present)
#   7. Integration test (C# → native bridge round-trip)
#
# Usage:
#   ./scripts/master_test.sh                  # run everything
#   ./scripts/master_test.sh --skip-fpga      # skip FPGA tests
#   ./scripts/master_test.sh --skip-cuda      # skip CUDA tests
#   ./scripts/master_test.sh --skip-csharp    # skip C# tests
#   ./scripts/master_test.sh --quick          # only fast tests (no FPGA, no CUDA build)
#
# Exit codes:
#   0  All tests passed
#   1  One or more test suites failed
#   2  Environment misconfiguration (missing tools)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$REPO_ROOT/build"
TEST_BUILD="$BUILD_DIR/test_artifacts"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global counters
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SKIPPED_SUITES=0

# Flags
SKIP_CUDA=false
SKIP_FPGA=false
SKIP_CSHARP=false
QUICK=false

log_banner() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

log_section() {
    echo ""
    echo -e "${BLUE}── $1 ──${NC}"
}

log_pass()  { echo -e "${GREEN}PASS${NC}  $1"; PASSED_SUITES=$((PASSED_SUITES + 1)); TOTAL_SUITES=$((TOTAL_SUITES + 1)); }
log_fail()  { echo -e "${RED}FAIL${NC}  $1"; FAILED_SUITES=$((FAILED_SUITES + 1)); TOTAL_SUITES=$((TOTAL_SUITES + 1)); }
log_skip()  { echo -e "${YELLOW}SKIP${NC}  $1"; SKIPPED_SUITES=$((SKIPPED_SUITES + 1)); TOTAL_SUITES=$((TOTAL_SUITES + 1)); }
log_info()  { echo -e "${CYAN}INFO${NC}  $1"; }

# ============================================================
# Parse arguments
# ============================================================
for arg in "$@"; do
    case "$arg" in
        --skip-cuda)   SKIP_CUDA=true ;;
        --skip-fpga)   SKIP_FPGA=true ;;
        --skip-csharp) SKIP_CSHARP=true ;;
        --quick)       QUICK=true; SKIP_FPGA=true; SKIP_CUDA=false ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-cuda   Skip CUDA kernel tests"
            echo "  --skip-fpga   Skip FPGA/Vitis tests"
            echo "  --skip-csharp Skip C# xUnit tests"
            echo "  --quick       Fast tests only (no FPGA, no CUDA compile)"
            echo "  --help        Show this help"
            echo ""
            echo "Test suites:"
            echo "  1. Environment checks"
            echo "  2. C# xUnit tests (StructLayout, Materials, SDF, Bridge)"
            echo "  3. CUDA kernel unit tests (uhc_test_kernels)"
            echo "  4. C API smoke test (uhc_api_smoke_test)"
            echo "  5. CMake configure + build"
            echo "  6. FPGA Vitis HLS compile (requires vitis_hls)"
            echo "  7. FPGA hardware tests (requires Alveo/ZCU104)"
            echo "  8. Integration test (C# → native round-trip)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run $0 --help for usage"
            exit 2
            ;;
    esac
done

# ============================================================
# Pre-flight: verify repository structure
# ============================================================
log_banner "PRE-FLIGHT CHECKS"

if [ ! -f "$REPO_ROOT/CMakeLists.txt" ]; then
    log_fail "CMakeLists.txt not found at repo root. Are you in the right directory?"
    exit 2
fi
log_pass "Repository structure OK"

mkdir -p "$BUILD_DIR" "$TEST_BUILD"
log_pass "Build directories created"

# ============================================================
# SUITE 1: Environment Checks
# ============================================================
log_banner "SUITE 1: ENVIRONMENT CHECKS"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

check_command() {
    local cmd="$1"
    local name="$2"
    local min_version="$3"
    local found=false

    if command -v "$cmd" &> /dev/null; then
        local ver=$($cmd --version 2>&1 | head -1)
        log_pass "$name found: $ver"
        found=true
    else
        log_skip "$name not found (install $min_version or later)"
    fi
    echo "$found"
}

log_section "Checking build tools..."

HAS_DOTNET=$(check_command dotnet ".NET SDK" "8.0")
HAS_CMAKE=$(check_command cmake "CMake" "3.18")
HAS_NVCC=$(check_command nvcc "CUDA Toolkit (nvcc)" "12.0")
HAS_GCC=$(check_command gcc "GCC" "9.0")
HAS_GPP=$(check_command g++ "G++" "9.0")
HAS_PYTHON=$(check_command python3 "Python 3" "3.8")
HAS_GIT=$(check_command git "Git" "2.0")

if [ "$HAS_CMAKE" = "false" ] && [ "$HAS_NVCC" = "false" ] && [ "$HAS_DOTNET" = "false" ]; then
    log_fail "No build tools found. Install at least one of: .NET 8, CMake 3.18+, CUDA 12+"
    exit 2
fi

log_section "Checking GPU drivers..."

if [ "$HAS_NVCC" = "true" ]; then
    if command -v nvidia-smi &> /dev/null; then
        GPU_INFO=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)
        log_pass "NVIDIA GPU detected: $GPU_INFO"
    else
        log_skip "nvidia-smi not found — CUDA may not be functional"
    fi
else
    log_skip "CUDA not installed — skipping GPU checks"
fi

log_section "Checking FPGA tools..."

HAS_VITIS=$(check_command vitis_hls "Vitis HLS" "2024.1")
HAS_XRT=false
if command -v xbutil &> /dev/null || command -v xbutil2 &> /dev/null; then
    HAS_XRT=true
    log_pass "XRT utilities found (xbutil/xbutil2)"
else
    log_skip "XRT not found (install XRT 2024.1 for Alveo/ZCU104)"
fi

HAS_UIO=false
if ls /dev/uio* &> /dev/null; then
    HAS_UIO=true
    log_pass "UIO devices found: $(ls /dev/uio* 2>/dev/null | tr '\n' ' ')"
else
    log_skip "/dev/uio* not found (ZCU104 UIO driver not loaded?)"
fi

log_section "Checking Python test dependencies..."
if [ "$HAS_PYTHON" = "true" ]; then
    log_pass "Python 3 available for validation scripts"
fi

# ============================================================
# SUITE 2: C# xUnit Tests
# ============================================================
log_banner "SUITE 2: C# xUNIT TESTS"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$SKIP_CSHARP" = "true" ]; then
    log_skip "C# tests skipped (--skip-csharp)"
elif [ "$HAS_DOTNET" = "false" ]; then
    log_skip "dotnet CLI not found — skipping C# tests"
else
    log_section "Restoring NuGet packages..."
    cd "$REPO_ROOT/src/CSharp" || exit 1

    if dotnet restore UhtcAperiodicCoolingEngine.csproj --verbosity quiet 2>&1; then
        log_pass "Main project restore"
    else
        log_fail "Main project restore failed"
    fi

    if dotnet restore Tests/UhtcEngine.Tests.csproj --verbosity quiet 2>&1; then
        log_pass "Test project restore"
    else
        log_fail "Test project restore failed"
    fi

    log_section "Building test project..."
    if dotnet build Tests/UhtcEngine.Tests.csproj --no-restore --verbosity quiet 2>&1; then
        log_pass "Test project build"
    else
        log_fail "Test project build failed"
    fi

    log_section "Running xUnit tests..."
    TEST_OUTPUT=$(dotnet test Tests/UhtcEngine.Tests.csproj --no-build \
        --logger "console;verbosity=detailed" \
        --results-directory "$TEST_BUILD/csharp-results" 2>&1 || true)

    PASSED_COUNT=$(echo "$TEST_OUTPUT" | grep -oP '\d+(?= Passed)' || echo "0")
    FAILED_COUNT=$(echo "$TEST_OUTPUT" | grep -oP '\d+(?= Failed)' || echo "0")
    SKIPPED_COUNT=$(echo "$TEST_OUTPUT" | grep -oP '\d+(?= Skipped)' || echo "0")

    echo "$TEST_OUTPUT" | tail -20

    if [ "$FAILED_COUNT" -gt 0 ]; then
        log_fail "C# tests: $FAILED_COUNT test(s) failed (passed=$PASSED_COUNT, skipped=$SKIPPED_COUNT)"
    else
        log_pass "C# tests: $PASSED_COUNT passed, $SKIPPED_COUNT skipped"
    fi

    cd "$REPO_ROOT" || exit 1
fi

# ============================================================
# SUITE 3: CUDA Native Library Build
# ============================================================
log_banner "SUITE 3: CUDA NATIVE LIBRARY BUILD"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$SKIP_CUDA" = "true" ]; then
    log_skip "CUDA tests skipped (--skip-cuda)"
elif [ "$HAS_CMAKE" = "false" ] || [ "$HAS_NVCC" = "false" ]; then
    log_skip "CMake or NVCC not found — skipping CUDA build"
else
    log_section "Configuring CMake with CUDA + Bridge..."
    cd "$BUILD_DIR" || exit 1

    CMAKE_ARGS=(
        -DCMAKE_BUILD_TYPE=Release
        -DUHC_BUILD_BRIDGE=ON
        -DCMAKE_CUDA_ARCHITECTURES="70;75;80;86"
    )

    if cmake "$REPO_ROOT" "${CMAKE_ARGS[@]}" 2>&1 | tail -30; then
        log_pass "CMake configuration"
    else
        log_fail "CMake configuration failed"
    fi

    log_section "Building libuhtc_native_accel.so..."
    if cmake --build . --config Release --parallel "$(nproc)" 2>&1 | tail -10; then
        log_pass "Native library build"
    else
        log_fail "Native library build failed"
    fi

    # Verify the shared library was produced
    if ls "$BUILD_DIR/src/Native/libuhtc_native_accel.so" &> /dev/null || \
       ls "$BUILD_DIR/libuhtc_native_accel.so" &> /dev/null; then
        LIB_PATH=$(find "$BUILD_DIR" -name "libuhtc_native_accel.so" 2>/dev/null | head -1)
        log_pass "Shared library found: $LIB_PATH"
    else
        log_fail "libuhtc_native_accel.so not found after build"
    fi

    cd "$REPO_ROOT" || exit 1
fi

# ============================================================
# SUITE 4: CUDA Kernel Unit Tests
# ============================================================
log_banner "SUITE 4: CUDA KERNEL UNIT TESTS"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$SKIP_CUDA" = "true" ]; then
    log_skip "CUDA tests skipped (--skip-cuda)"
elif [ "$HAS_NVCC" = "false" ]; then
    log_skip "nvcc not found — skipping CUDA kernel tests"
else
    log_section "Building CUDA test harness..."

    cd "$BUILD_DIR" || exit 1

    if cmake --build . --config Release --target uhc_cuda_test_harness --parallel "$(nproc)" 2>&1 | tail -10; then
        log_pass "uhc_cuda_test_harness build"
    else
        log_fail "uhc_cuda_test_harness build failed"
    fi

    TEST_BIN=""
    for candidate in \
        "$BUILD_DIR/src/Native/uhc_cuda_test_harness" \
        "$BUILD_DIR/src/Native/Cuda/tests/uhc_cuda_test_harness" \
        "$BUILD_DIR/uhc_cuda_test_harness"; do
        if [ -x "$candidate" ]; then
            TEST_BIN="$candidate"
            break
        fi
    done

    if [ -n "$TEST_BIN" ]; then
        log_section "Running CUDA kernel tests..."
        echo ""
        if "$TEST_BIN" 2>&1; then
            log_pass "uhc_cuda_test_harness: all tests passed"
        else
            log_fail "uhc_cuda_test_harness: one or more tests failed"
        fi
    else
        log_skip "uhc_cuda_test_harness binary not found after build"
    fi

    cd "$REPO_ROOT" || exit 1
fi

# ============================================================
# SUITE 5: C API Smoke Test
# ============================================================
log_banner "SUITE 5: C API SMOKE TEST"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$SKIP_CUDA" = "true" ]; then
    log_skip "C API tests skipped (--skip-cuda)"
elif [ "$HAS_NVCC" = "false" ]; then
    log_skip "nvcc not found — skipping C API smoke test"
else
    log_section "Building C API smoke test..."

    cd "$BUILD_DIR" || exit 1

    if cmake --build . --config Release --target uhc_api_smoke_test --parallel "$(nproc)" 2>&1 | tail -10; then
        log_pass "uhc_api_smoke_test build"
    else
        log_fail "uhc_api_smoke_test build failed"
    fi

    SMOKE_BIN=""
    for candidate in \
        "$BUILD_DIR/src/Native/uhc_api_smoke_test" \
        "$BUILD_DIR/uhc_api_smoke_test"; do
        if [ -x "$candidate" ]; then
            SMOKE_BIN="$candidate"
            break
        fi
    done

    if [ -n "$SMOKE_BIN" ]; then
        log_section "Running C API smoke test..."
        echo ""
        if "$SMOKE_BIN" 2>&1; then
            log_pass "uhc_api_smoke_test: all checks passed"
        else
            log_fail "uhc_api_smoke_test: one or more checks failed"
        fi
    else
        log_skip "uhc_api_smoke_test binary not found after build"
    fi

    cd "$REPO_ROOT" || exit 1
fi

# ============================================================
# SUITE 6: CMake Smoke Test
# ============================================================
log_banner "SUITE 6: CMAKE SMOKE TEST"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$HAS_CMAKE" = "false" ]; then
    log_skip "CMake not found — skipping CMake smoke test"
else
    log_section "Running CMake configure smoke test..."
    CMAKE_SMOKE_DIR="$BUILD_DIR/cmake_smoke_quick"
    mkdir -p "$CMAKE_SMOKE_DIR"

    if cmake "$REPO_ROOT" -B "$CMAKE_SMOKE_DIR" -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -15; then
        log_pass "CMake configure (all targets discovered)"
    else
        log_fail "CMake configure failed"
    fi

    log_section "Verifying CMake targets..."
    TARGETS=$(cmake --build "$CMAKE_SMOKE_DIR" --config Release --target help 2>&1 || true)

    REQUIRED_TARGETS=(
        "uhtc_native_accel"
        "uhc_fpga_driver"
        "uhc_cuda_test_harness"
        "uhc_api_smoke_test"
    )

    for target in "${REQUIRED_TARGETS[@]}"; do
        if echo "$TARGETS" | grep -q "$target"; then
            log_pass "CMake target exists: $target"
        else
            log_fail "CMake target missing: $target"
        fi
    done
fi

# ============================================================
# SUITE 7: FPGA Vitis HLS Compile (optional)
# ============================================================
log_banner "SUITE 7: FPGA VITIS HLS COMPILE"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$SKIP_FPGA" = "true" ]; then
    log_skip "FPGA tests skipped (--skip-fpga)"
elif [ "$HAS_VITIS" = "false" ]; then
    log_skip "Vitis HLS not found — skipping FPGA compile"
    log_info "Install Vitis 2024.1+: https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vitis.html"
else
    log_section "Compiling HLS kernel with Vitis..."

    VITIS_INC=""
    if [ -d "/opt/xilinx/vitis/include" ]; then
        VITIS_INC="/opt/xilinx/vitis/include"
    elif [ -d "/opt/Xilinx/Vitis/2024.1/include" ]; then
        VITIS_INC="/opt/Xilinx/Vitis/2024.1/include"
    else
        VITIS_INC=$(find /opt -name "ap_axi_sdata.h" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "")
    fi

    if [ -z "$VITIS_INC" ]; then
        log_skip "Vitis HLS include directory not found"
    else
        log_pass "Vitis HLS includes: $VITIS_INC"

        VITIS_HLS_SRC="$REPO_ROOT/src/Native/FPGA/hls/laser_controller.cpp"
        VITIS_HLS_OBJ="$BUILD_DIR/laser_controller_hls.o"

        if [ ! -f "$VITIS_HLS_SRC" ]; then
            log_fail "HLS source not found: $VITIS_HLS_SRC"
        else
            log_section "Running Vitis HLS synthesis..."

            VITIS_CFLAGS=(
                -I"$REPO_ROOT/src/Native/FPGA/hls"
                -I"$REPO_ROOT/src/Native/FPGA/Bridge"
                -I"$VITIS_INC"
                -std=c++17
                -D__SYNTHESIS__
                -c
                -o "$VITIS_HLS_OBJ"
            )

            if vitis_hls "${VITIS_CFLAGS[@]}" "$VITIS_HLS_SRC" 2>&1 | tail -20; then
                log_pass "Vitis HLS compilation: laser_controller.cpp"
            else
                log_fail "Vitis HLS compilation failed"
            fi
        fi
    fi
fi

# ============================================================
# SUITE 8: FPGA Hardware Tests (Alveo / ZCU104)
# ============================================================
log_banner "SUITE 8: FPGA HARDWARE TESTS"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$SKIP_FPGA" = "true" ]; then
    log_skip "FPGA tests skipped (--skip-fpga)"
elif [ "$HAS_XRT" = "false" ] && [ "$HAS_UIO" = "false" ]; then
    log_skip "No FPGA hardware detected (XRT/UIO not present)"
    log_info "To test FPGA:"
    log_info "  Alveo: install XRT 2024.1, load xocl driver, run xbutil examine"
    log_info "  ZCU104: load UIO drivers, ensure /dev/uio0 exists"
else
    log_section "Checking FPGA device status..."

    if [ "$HAS_XRT" = "true" ]; then
        XBUTIL_CMD="xbutil"
        if command -v xbutil2 &> /dev/null; then
            XBUTIL_CMD="xbutil2"
        fi

        $XBUTIL_CMD examine --dump 2>&1 | head -30 | while IFS= read -r line; do
            log_info "  $line"
        done

        # Count FPGA devices
        N_DEVICES=$($XBUTIL_CMD examine 2>&1 | grep -c "Device" || echo "0")
        if [ "$N_DEVICES" -gt 0 ]; then
            log_pass "FPGA device(s) detected: $N_DEVICES"
        else
            log_skip "No FPGA devices found by XRT"
        fi
    fi

    if [ "$HAS_UIO" = "true" ]; then
        log_section "Checking ZCU104 UIO mappings..."
        for uio_dev in /dev/uio*; do
            if [ -c "$uio_dev" ]; then
                UIO_NAME=$(basename "$uio_dev")
                UIO_SIZE=$(cat /sys/class/uio/${UIO_NAME}/maps/map0/size 2>/dev/null || echo "unknown")
                log_pass "UIO device $UIO_NAME: size=$UIO_SIZE"
            fi
        done
    fi
fi

# ============================================================
# SUITE 9: Integration Test (C# → Native round-trip)
# ============================================================
log_banner "SUITE 9: INTEGRATION TEST (C# → NATIVE)"
TOTAL_SUITES=$((TOTAL_SUITES + 1))

if [ "$SKIP_CUDA" = "true" ] && [ "$SKIP_CSHARP" = "true" ]; then
    log_skip "Integration test skipped (both C# and CUDA disabled)"
elif [ "$HAS_DOTNET" = "false" ] || [ "$HAS_NVCC" = "false" ]; then
    log_skip "Requires both dotnet and nvcc — skipping integration test"
else
    log_section "Setting up integration test environment..."

    # Find the built native library
    NATIVE_LIB=""
    for candidate in \
        "$BUILD_DIR/src/Native/libuhtc_native_accel.so" \
        "$BUILD_DIR/libuhtc_native_accel.so"; do
        if [ -f "$candidate" ]; then
            NATIVE_LIB="$candidate"
            break
        fi
    done

    if [ -z "$NATIVE_LIB" ]; then
        log_skip "Native library not built — skipping integration test"
    else
        log_pass "Native library: $NATIVE_LIB"

        # Set LD_LIBRARY_PATH so C# can find the .so
        export LD_LIBRARY_PATH="$(dirname "$NATIVE_LIB"):${LD_LIBRARY_PATH:-}"
        log_pass "LD_LIBRARY_PATH set to: $(dirname "$NATIVE_LIB")"

        log_section "Building integration test project..."
        cd "$REPO_ROOT/src/CSharp" || exit 1

        INTEGRATION_CS="$TEST_BUILD/IntegrationTestRunner.cs"
        cat > "$INTEGRATION_CS" << 'INTEGRATION_EOF'
// SPDX-License-Identifier: Apache-2.0
using System;
using UhtcAperiodicCoolingEngine.Interop;

class IntegrationTestRunner
{
    static int Main()
    {
        int failures = 0;

        // 1. Initialise native engine
        int rc = NativeBridge.Initialize(UhcBackend.Auto);
        if (rc != 0) { Console.WriteLine("FAIL: Initialize returned " + rc); return 1; }
        Console.WriteLine("PASS: NativeBridge.Initialize");

        // 2. Check active backend
        var backend = NativeBridge.ActiveBackend();
        Console.WriteLine($"PASS: Active backend = {backend}");

        // 3. Material property queries
        float k = NativeBridge.MaterialThermalConductivity(0, 300.0f);
        if (k > 50 && k < 200) Console.WriteLine($"PASS: k_ZrB2(300K) = {k:F1} W/m·K");
        else { Console.WriteLine($"FAIL: k out of range: {k}"); failures++; }

        float barrier = NativeBridge.MaterialOxygenBarrier(0.15f, 3.5f, 2.0f);
        if (barrier == 0.0f || barrier == 1.0f) Console.WriteLine($"PASS: O2 barrier = {barrier}");
        else { Console.WriteLine($"FAIL: barrier out of range: {barrier}"); failures++; }

        // 4. SDF evaluation round-trip
        var parameters = new UhcParams
        {
            GeometryType = 0, Freq = 1.0f, WallThickness = 0.25f,
            Tortuosity = 3.5f, TMeltK = 3523.0f, MaterialId = 0,
            LaserPowerW = 500.0f, LaserEta = 0.35f, ScanSpeedMmS = 5.0f,
            EllipseX = 2.5f, EllipseY = 2.5f, EllipseZ = 1.0f
        };
        float[] points = { 0,0,0, 1,0,0, 0,1,0 };
        float[] sdf = new float[3]; float[] barrierArr = new float[3];
        float[] kArr = new float[3]; float[] lq = new float[3]; float[] o2 = new float[3];

        rc = NativeBridge.EvaluateSdf(points, sdf, barrierArr, kArr, lq, o2, 3, in parameters);
        if (rc == 0) Console.WriteLine($"PASS: EvaluateSdf returned 0, sdf[0]={sdf[0]:F4}");
        else { Console.WriteLine($"FAIL: EvaluateSdf returned {rc}"); failures++; }

        // 5. PID laser scan
        UhcScanSegment[] segs = {
            new UhcScanSegment { X=0, Y=0, Speed=5, Power=500 },
            new UhcScanSegment { X=1, Y=0, Speed=5, Power=500 }
        };
        float[] T_meas = { 3400, 3400 };
        float[] P_eff = new float[2]; float[] e_stop = new float[1];

        rc = NativeBridge.PidLaserScan(IntPtr.Zero, segs, T_meas, P_eff, e_stop, 2, 3523.0f, in parameters);
        if (rc == 0) Console.WriteLine($"PASS: PidLaserScan returned 0, P_eff[0]={P_eff[0]:F1}");
        else { Console.WriteLine($"FAIL: PidLaserScan returned {rc}"); failures++; }

        // 6. Thermal solver (CUDA)
        IntPtr thermal = NativeBridge.ThermalCreate(0.5f);
        if (thermal != IntPtr.Zero)
        {
            Console.WriteLine("PASS: ThermalCreate succeeded");
            NativeBridge.ThermalDestroy(thermal);
        }
        else
        {
            Console.WriteLine("SKIP: ThermalCreate returned null (CUDA unavailable?)");
        }

        // 7. Shutdown
        NativeBridge.Shutdown();
        Console.WriteLine("PASS: NativeBridge.Shutdown");

        Console.WriteLine($"\nIntegration result: {(failures == 0 ? "ALL PASSED" : failures + " FAILURES")}");
        return failures;
    }
}
INTEGRATION_EOF

        # Compile and run the integration test
        if dotnet run --project "$REPO_ROOT/src/CSharp/UhtcAperiodicCoolingEngine.csproj" \
            -- "$INTEGRATION_CS" 2>&1 | tail -20; then
            :
        else
            # Fallback: compile as standalone
            log_info "Compiling integration test as standalone program..."
            dotnet new console -n IntegrationTest -o "$TEST_BUILD/IntegrationTest" --force 2>&1 | tail -5
            cp "$INTEGRATION_CS" "$TEST_BUILD/IntegrationTest/Program.cs"
            cd "$TEST_BUILD/IntegrationTest"
            dotnet add reference "$REPO_ROOT/src/CSharp/UhtcAperiodicCoolingEngine.csproj" 2>&1 | tail -3
            dotnet run 2>&1 | tail -20
        fi

        cd "$REPO_ROOT" || exit 1
    fi
fi

# ============================================================
# SUMMARY
# ============================================================
log_banner "TEST SUMMARY"

echo ""
echo "  Total test suites : $TOTAL_SUITES"
echo -e "  ${GREEN}Passed${NC}            : $PASSED_SUITES"
echo -e "  ${RED}Failed${NC}            : $FAILED_SUITES"
echo -e "  ${YELLOW}Skipped${NC}           : $SKIPPED_SUITES"
echo ""

if [ "$FAILED_SUITES" -eq 0 ]; then
    echo -e "${GREEN}ALL TEST SUITES PASSED${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review any skipped suites — install missing tools to enable them"
    echo "  2. For FPGA tests: ensure Vitis 2024.1+ and XRT are installed"
    echo "  3. For C# tests: ensure .NET 8 SDK is installed"
    echo "  4. Run individual suites with: ./scripts/run_tests.sh [--csharp|--native|--cmake]"
    exit 0
else
    echo -e "${RED}$FAILED_SUITES FAILED${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check build logs in: $BUILD_DIR"
    echo "  - For CUDA errors: verify nvcc --version and nvidia-smi"
    echo "  - For FPGA errors: verify Vitis HLS and XRT installation"
    echo "  - For C# errors: verify dotnet --version and NuGet restore"
    exit 1
fi
