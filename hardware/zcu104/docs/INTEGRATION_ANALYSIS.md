# ============================================================================
# ZCU104 Integration Analysis - UHTC Aperiodic Cooling Engine
# ============================================================================
#
# Analysis of the ZCU104 hardware repository import, VHDL testbenches,
# and Linux/CUDA/XRT toolchain setup for the UHTC project.
#
# Date: 2026-08-06
# ============================================================================

## 1. ZCU104 Repository Import

### Source
- Repository: https://github.com/Xilinx/PYNQ
- Branch: master
- Board path: boards/ZCU104/base/

### Files Imported

| File | Destination | Purpose |
|------|-------------|---------|
| vivado/constraints/base.xdc | hardware/zcu104/constraints/base.xdc | Pin assignments (HDMI, PMOD, I2C, reset) |
| base.tcl | hardware/zcu104/tcl/base.tcl | Vivado IP Integrator block design |
| build_bitstream.tcl | hardware/zcu104/tcl/build_bitstream.tcl | Bitstream generation + XSA export |
| build_ip.tcl | hardware/zcu104/tcl/build_ip.tcl | HLS IP rebuild automation |
| check_timing.tcl | hardware/zcu104/tcl/check_timing.tcl | Timing constraint verification |
| makefile | hardware/zcu104/tcl/Makefile | Build orchestration |

### Analysis of base.xdc

The constraint file defines:
- **reset**: PACKAGE_PIN M11, LVCMOS33
- **HDMI RX/TX**: Differential pairs for video input/output
- **PMOD GPIO**: 16 pins per connector (pmod0, pmod1), LVCMOS33, pullups
- **I2C**: fmch_iic_scl_io (D1), fmch_iic_sda_io (E1), LVCMOS33

**Note**: base.xdc does NOT define custom AXI Lite pins for user overlays.
For UHTC, you must add your own XDC constraints when building a custom
overlay with the laser controller IP.

### Analysis of base.tcl

The block design includes:
- Zynq UltraScale+ MPSoC PS (xczu7ev-ffvc1156-2-e)
- AXI Interconnect (M00-M10)
- HDMI RX/TX subsystems with video PHY
- AXI VDMA for frame buffer
- MicroBlaze + LMB (optional debug)
- HLS IPs: color_convert, pixel_pack, pixel_unpack

**Note**: This is the stock PYNQ base design. For UHTC, you would instantiate
your krnl_uhc_sdf, krnl_uhc_pid_control, and laser_controller IPs here.

### Analysis of build_bitstream.tcl

Flow:
1. Open project + block design
2. Add wrapper + constraints
3. Set platform properties (sd_card output, embedded=true)
4. Implement + write bitstream
5. Generate XSA + copy bit/hwh files

This matches the ARCHITECTURE.md build flow for uhtc_laser.xclbin.

## 2. VHDL Testbenches

### Files Created

| File | Purpose |
|------|---------|
| hardware/zcu104/testbenches/tb_axi_lite_slave.vhd | AXI4-Lite slave model (256 regs) |
| hardware/zcu104/testbenches/tb_axi_stream_sink.vhd | AXI4-Stream sink (thermal packet verification) |
| hardware/zcu104/testbenches/tb_uhc_laser_controller.vhd | Top-level integration testbench |
| hardware/zcu104/testbenches/Makefile | GHDL + xsim build targets |
| hardware/zcu104/testbenches/xsim_compile.tcl | Vivado xsim compilation |
| hardware/zcu104/testbenches/xsim_run.tcl | Vivado xsim run + waveform |

### Architecture Mapping

The testbenches model the exact interfaces from:
- `src/Native/FPGA/hls/uhc_fpga_types.h` (UHTCParams POD struct)
- `src/Native/FPGA/Bridge/NativeEngineAPI.h` (UhcLaserCommand, UhcThermalReading)
- `src/Native/FPGA/drivers/zcu104_driver.cpp` (AXI Lite @ 0x80000000)

### Register Map Coverage

The AXI Lite slave implements all 10 registers documented in README.md:
- 0x00: LASER_POWER_REG (RW)
- 0x04: GALVO_X_REG (RW)
- 0x08: GALVO_Y_REG (RW)
- 0x0C: MOD_FREQ_REG (RW)
- 0x10: STATUS_REG (RO)
- 0x14: TEMPERATURE_REG (RO)
- 0x18: DT_DT_REG (RO)
- 0x1C: TIMESTAMP_REG (RO)
- 0x20: COMMAND_COUNT_REG (RO)
- 0x40: STREAM_TRIG_REG (WO)

### AXI4-Stream Packet Format

**Laser commands (PS -> PL)**:
- 3 x 32-bit words = 12 bytes per sample
- Word 0: power_W[15:0] + galvo_x[15:0]
- Word 1: galvo_y[15:0] + mod_freq[15:0]
- Word 2: mod_phase[15:0] + reserved[15:0]
- TLAST asserted on final word

**Thermal feedback (PL -> PS)**:
- 5 x 32-bit words = 20 bytes per packet
- Word 0: temperature_K (float32)
- Word 1: dT_dt (float32)
- Word 2: reserved[31:1] + emergency_stop[0]
- Word 3: timestamp_ms
- Word 4: n_samples
- TLAST asserted on final word

## 3. Linux / CUDA / XRT Toolchain

### Current Environment

- OS: Alpine Linux v3.23.5 (container environment)
- Available: gcc, g++, python3, tclsh
- NOT available: nvcc, nvidia-smi, vivado, v++, xrt, ghdl

### Installation Commands (Ubuntu 22.04 LTS)

**CUDA 12.4**:
```bash
sudo apt-get install -y curl gnupg
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin | \
  sudo tee /usr/share/keyrings/cuda-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /" | \
  sudo tee /etc/apt/sources.list.d/cuda.list
sudo apt-get update
sudo apt-get install -y cuda-toolkit-12-4
export PATH=/usr/local/cuda-12.4/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64:$LD_LIBRARY_PATH
```

**XRT 2024.1**:
```bash
sudo apt-get install -y libssl-dev libcurl4-openssl-dev
wget https://xilinx.com/xrt/xrt_2024.1_all.deb -O /tmp/xrt.deb
sudo dpkg -i /tmp/xrt.deb
sudo apt-get install -f
source /opt/xilinx/xrt/setup.sh
xbutil scan
```

**Vitis 2024.1**:
```bash
sudo apt-get install -y libtinfo5 libncurses5
sudo /opt/Xilinx/Vitis/2024.1/install.py
source /opt/Xilinx/Vitis/2024.1/settings64.sh
vitis_hls -version
```

**ZCU104 Platform**:
```bash
sudo /opt/Xilinx/Vitis/2024.1/bin/platformutil install xilinx_zcu104_base_2024_1.xsa
v++ --list-platforms
```

**GHDL**:
```bash
sudo apt-get install -y ghdl gtkwave
ghdl --version
```

### Build Commands

```bash
cd /workspaces/uhtc-aperiodic-cooling-engine
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.4
make -j$(nproc)
```

## 4. Python-Linux + TCL Integration

### Python (Host Side)

The ZCU104 runs PYNQ (Ubuntu 20.04, Python 3.8).  Overlay loading:

```python
from pynq import Overlay
ol = Overlay('/home/xilinx/uhc_laser.bit')
laser = ol.laser_controller_0
laser.write(0x00, 1200)  # power = 1200 W
```

### TCL (Vivado Side)

The TCL scripts automate:
- IP Integrator block design creation
- HLS IP packaging
- Bitstream generation
- Timing verification

Run sequence:
```bash
vivado -mode batch -source hardware/zcu104/tcl/base.tcl -notrace
vivado -mode batch -source hardware/zcu104/tcl/build_bitstream.tcl -notrace
vitis_hls -f hardware/zcu104/tcl/build_ip.tcl
```

## 5. Constraints Analysis

### Current Constraints (base.xdc)

- **HDMI**: Full TX/RX differential pairs
- **PMOD**: 2 x 16-bit GPIO banks (LVCMOS33)
- **I2C**: fmch_iic (SCL=D1, SDA=E1)
- **Reset**: M11 (active-low)

### Missing for UHTC

No constraints exist for:
- Custom AXI Lite GPIO
- AXI Stream FIFO clock/reset
- PMOD galvo control pins
- User LEDs for status

These must be added in a custom XDC when building the UHTC overlay.

## 6. Summary of Actions Taken

1. **Explored** the current codespace: C# engine, CUDA kernels, FPGA HLS kernels, ZCU104 driver
2. **Cloned** Xilinx PYNQ repository to /tmp/PYNQ
3. **Imported** ZCU104 hardware files into hardware/zcu104/:
   - constraints/base.xdc
   - tcl/base.tcl, build_bitstream.tcl, build_ip.tcl, check_timing.tcl, Makefile
4. **Created** VHDL testbenches:
   - tb_axi_lite_slave.vhd (AXI4-Lite slave model, 256 registers)
   - tb_axi_stream_sink.vhd (AXI4-Stream sink with scoreboard)
   - tb_uhc_laser_controller.vhd (top-level integration testbench)
   - Makefile (GHDL + xsim targets)
   - xsim_compile.tcl, xsim_run.tcl (Vivado batch flow)
5. **Documented**:
   - hardware/zcu104/README.md (project hardware guide)
   - hardware/zcu104/docs/CUDA_XRT_SETUP.md (toolchain installation)
6. **Verified** environment: Alpine Linux container, no CUDA/Vivado/XRT installed
7. **Provided** exact installation commands for Ubuntu 22.04 LTS

## 7. Next Steps

1. Install Ubuntu 22.04 with CUDA 12.4, XRT 2024.1, Vitis 2024.1
2. Build ZCU104 base overlay with Vivado
3. Synthesize UHTC HLS kernels with Vitis HLS
4. Link xclbin for ZCU104 platform
5. Run VHDL testbenches with GHDL or xsim
6. Program ZCU104 and validate with Python PYNQ scripts
7. Add custom XDC constraints for UHTC-specific GPIO/PMOD signals
