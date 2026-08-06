# ============================================================================
# Linux CUDA and XRT Toolchain Setup
# ============================================================================
#
# This document provides exact commands to install CUDA toolkit and XRT
# on Ubuntu/Debian systems for UHTC FPGA + GPU development.
#
# Environment: Ubuntu 22.04 LTS (recommended) or 20.04 LTS
# Kernel:      >= 5.4 (for XRT on ZCU104)
# GPU:         NVIDIA GPU with compute capability >= 5.0
# FPGA:        ZCU104 (XCZU7EV)
#
# ============================================================================
# 1. NVIDIA CUDA Toolkit
# ============================================================================
#
# CUDA 12.x is required for the UHTC native engine.  Install via NVIDIA
# package repository:
#
#   # Add NVIDIA package repository
#   sudo apt-get update
#   sudo apt-get install -y curl gnupg
#   curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin | \
#     sudo tee /usr/share/keyrings/cuda-archive-keyring.gpg >/dev/null
#   echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /" | \
#     sudo tee /etc/apt/sources.list.d/cuda.list
#   sudo apt-get update
#
#   # Install CUDA 12.x toolkit
#   sudo apt-get install -y cuda-toolkit-12-4
#
#   # Set environment
#   echo 'export PATH=/usr/local/cuda-12.4/bin:$PATH' >> ~/.bashrc
#   echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
#   source ~/.bashrc
#
#   # Verify
#   nvcc --version
#   nvidia-smi
#
# ============================================================================
# 2. Xilinx Runtime (XRT)
# ============================================================================
#
# XRT provides the user-space driver for ZCU104 AXI MM/Stream access.
# Install the .deb packages from Xilinx:
#
#   # Install XRT for ZCU104
#   sudo apt-get install -y libssl-dev libcurl4-openssl-dev
#
#   # Download XRT .deb from Xilinx support site:
#   # https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/xrt.html
#   # Select: XRT 2024.1, Ubuntu 22.04, ZOCLn (Zynq UltraScale+ MPSoC)
#
#   wget https://xilinx.com/xrt/xrt_2024.1_all.deb -O /tmp/xrt.deb
#   sudo dpkg -i /tmp/xrt.deb
#   sudo apt-get install -f  # resolve dependencies
#
#   # Verify XRT installation
#   xbutil dump -d 0
#
#   # Verify ZCU104 detected
#   sudo xbutil scan
#
# ============================================================================
# 3. Vitis HLS / Vitis Unified
# ============================================================================
#
# Required to synthesize HLS kernels (uhc_laser_controller.cpp etc.)
#
#   # Download Vitis 2024.1 from Xilinx
#   # https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vitis.html
#
#   # Install
#   sudo apt-get install -y libtinfo5 libncurses5
#   sudo /opt/Xilinx/Vitis/2024.1/install.py
#
#   # Source environment
#   source /opt/Xilinx/Vitis/2024.1/settings64.sh
#   vitis_hls -version
#
# ============================================================================
# 4. ZCU104 Platform Files
# ============================================================================
#
# To target ZCU104 with Vitis v++, install the platform:
#
#   # Platform installer comes with Vitis or can be downloaded from:
#   # https://www.xilinx.com/products/boards-and-kits/zcu104.html
#   # Download: ZCU104 base platform (xilinx_zcu104_base_2024_1)
#
#   # Install platform
#   sudo /opt/Xilinx/Vitis/2024.1/bin/platformutil install xilinx_zcu104_base_2024_1.xsa
#
#   # Verify
#   v++ --list-platforms
#
# ============================================================================
# 5. Build UHTC Native Engine
# ============================================================================
#
# Once CUDA + XRT + Vitis are installed:
#
#   cd /workspaces/uhtc-aperiodic-cooling-engine
#   mkdir -p build && cd build
#   cmake .. \
#     -DCMAKE_BUILD_TYPE=Release \
#     -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.4/bin/nvcc \
#     -DXRT_FOUND=ON \
#     -DVITIS_HLS_FOUND=ON
#   make -j$(nproc)
#
# ============================================================================
# 6. Build ZCU104 HLS Kernels
# ============================================================================
#
#   cd hardware/zcu104/tcl
#   vitis_hls -f build_ip.tcl
#   cd ../..
#   v++ -c -k krnl_uhc_sdf -I'./src/Native/FPGA/hls' \
#       --platform xilinx_zcu104_base_2024_1 \
#       ./src/Native/FPGA/hls/kernel.cpp \
#       -o build/xclbin/uhtc_laser.o
#   v++ -l -o build/xclbin/uhtc_laser.xclbin \
#       --platform xilinx_zcu104_base_2024_1 \
#       build/xclbin/uhtc_laser.o
#
# ============================================================================
# 7. Python PYNQ Environment on ZCU104
# ============================================================================
#
# On the ZCU104 board itself (running PYNQ image):
#
#   # Update package list
#   sudo apt-get update
#
#   # Install Python packages
#   pip3 install numpy scipy
#
#   # Copy overlay
#   scp build/xclbin/uhtc_laser.xclbin xilinx@192.168.2.99:/home/xilinx/
#   scp hardware/zcu104/base.bit xilinx@192.168.2.99:/home/xilinx/uhc_laser.bit
#
#   # On ZCU104
#   jupyter notebook --ip=0.0.0.0 --no-browser --port=8888
#
# ============================================================================
# 8. TCL Script Reference for ZCU104
# ============================================================================
#
# The following TCL scripts are used in this project:
#
#   base.tcl                    - Vivado IP Integrator block design
#   build_bitstream.tcl         - Bitstream generation and XSA export
#   build_ip.tcl                - HLS IP rebuild
#   check_timing.tcl            - Timing verification
#   analyze_axi_interconnect.tcl - AXI interconnect analysis
#
# Run sequence:
#
#   vivado -mode batch -source base.tcl -notrace
#   vivado -mode batch -source build_bitstream.tcl -notrace
#   vitis_hls -f build_ip.tcl
#
# ============================================================================
# 9. Common Issues
# ============================================================================
#
# Issue: "xbutil: command not found"
# Fix:   Source XRT environment:
#        source /opt/xilinx/xrt/setup.sh
#
# Issue: "v++: command not found"
# Fix:   Source Vitis environment:
#        source /opt/Xilinx/Vitis/2024.1/settings64.sh
#
# Issue: "nvcc: command not found"
# Fix:   Add CUDA to PATH:
#        export PATH=/usr/local/cuda-12.4/bin:$PATH
#
# Issue: "ERROR: Timing constraints are not met"
# Fix:   Run check_timing.tcl.  If timing fails, try:
#        - Reducing clock frequency in HLS kernels
#        - Using a more aggressive optimization level
#        - Reducing AXI burst lengths
#
# ============================================================================
