# ============================================================================
# Makefile - ZCU104 Hardware Testbenches
# ============================================================================
# Targets:
#   ghdl_compile   - Compile VHDL sources with GHDL
#   ghdl_run       - Run tb_uhc_laser_controller with GHDL + waveform
#   ghdl_view      - Open waveform with GHDL wave viewer
#   xsim_compile   - Compile with Vivado xsim (requires Vivado 2024.1)
#   xsim_run       - Run with xsim
#   clean          - Remove simulation artifacts
#
# Prerequisites:
#   GHDL:  https://ghdl.github.io/ghdl/
#   Vivado: https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vitis.html
#
# References:
#   UG835 - Vivado Design Suite Tcl Command Reference
#   UG901 - Vivado Synthesis
# ============================================================================

.SHELLFLAGS := -eu -o pipefail

# ---- GHDL configuration ---------------------------------------------------
GHDL          ?= ghdl
GHDL_FLAGS    := --ieee=synopsys --no-vital-checks --work=work
GHDL_SOURCES  := tb_axi_lite_slave.vhd tb_axi_stream_sink.vhd tb_uhc_laser_controller.vhd
GHDL_TOP      := tb_uhc_laser_controller
WAVE_FILE     := uhc_zcu104.ghw
STOP_TIME     := --stop-time=100us

# ---- XSIM configuration ---------------------------------------------------
VIVADO        ?= vivado
XSIM_TOP      := tb_uhc_laser_controller
XSIM_WAVE     := uhc_zcu104.wdb

.PHONY: all ghdl_compile ghdl_run ghdl_view xsim_compile xsim_run clean help

help:
	@echo "ZCU104 Hardware Testbench Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  ghdl_compile   Compile VHDL sources with GHDL"
	@echo "  ghdl_run       Run simulation with GHDL + waveform"
	@echo "  ghdl_view      Open waveform with gtkwave"
	@echo "  xsim_compile   Compile with Vivado xsim"
	@echo "  xsim_run       Run with xsim"
	@echo "  clean          Remove simulation artifacts"

# ---- GHDL targets ---------------------------------------------------------
ghdl_compile: $(GHDL_SOURCES)
	$(GHDL) -a $(GHDL_FLAGS) tb_axi_lite_slave.vhd
	$(GHDL) -a $(GHDL_FLAGS) tb_axi_stream_sink.vhd
	$(GHDL) -a $(GHDL_FLAGS) tb_uhc_laser_controller.vhd
	$(GHDL) -e $(GHDL_FLAGS) $(GHDL_TOP)

ghdl_run: ghdl_compile
	$(GHDL) -r $(GHDL_TOP) $(STOP_TIME) --wave=$(WAVE_FILE) --ieee-asserts=disable

ghdl_view: $(WAVE_FILE)
	gtkwave $(WAVE_FILE) 2>/dev/null || echo "gtkwave not installed"

# ---- XSIM targets ---------------------------------------------------------
xsim_compile: $(GHDL_SOURCES)
	$(VIVADO) -mode batch -source xsim_compile.tcl

xsim_run: xsim_compile
	$(VIVADO) -mode batch -source xsim_run.tcl

# ---- Clean ----------------------------------------------------------------
clean:
	rm -f work-*.cf *.o *.ghw *.wdb *.vcd xsim.log webtalk*.log \
	      xsim.dir transcript *.jou *.bak
