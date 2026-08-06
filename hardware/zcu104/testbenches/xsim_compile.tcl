# ============================================================================
# xsim_compile.tcl - Vivado xsim compilation for ZCU104 testbenches
# ============================================================================
# Usage: vivado -mode batch -source xsim_compile.tcl
# ============================================================================

set_property source_mgmt_mode All [current_project]

# Create xsim simulation fileset if needed
set sim_fileset [get_filesets -filter {FILESET_TYPE == BlockSrcs} -of [get_filesets sim_1]]
if { $sim_fileset eq "" } {
  puts "Creating simulation fileset..."
  create_fileset -simset sim_1
}

# Add VHDL sources
add_files -norecurse -fileset sim_1 [list \
  "tb_axi_lite_slave.vhd" \
  "tb_axi_stream_sink.vhd" \
  "tb_uhc_laser_controller.vhd" \
]

# Set top-level module
set_property top tb_uhc_laser_controller [get_filesets sim_1]

# Compile simulation
puts "Compiling simulation..."
launch_simulation -simset sim_1 -mode behavioral -no_wait
wait_on_open_sim_result -timeout 60
puts "Compilation complete."
