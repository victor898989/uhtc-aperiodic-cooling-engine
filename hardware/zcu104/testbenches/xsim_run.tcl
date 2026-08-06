# ============================================================================
# xsim_run.tcl - Vivado xsim run for ZCU104 testbenches
# ============================================================================
# Usage: vivado -mode batch -source xsim_run.tcl
# ============================================================================

set sim_fileset [get_filesets sim_1]
set sim_handle [open_sim -run -paths -active_sim -simset $sim_fileset]

# Run simulation for 100 us
puts "Running simulation..."
run 100us

# Save waveform
puts "Saving waveform to uhc_zcu104.wdb..."
save_wave_config uhc_zcu104.wdb
close_sim -export_waveform uhc_zcu104.wdb

# Report results
set pass_count [get_property -name tests.passed -objects [get_testbench_objects -filter {type == test}]]
set fail_count [get_property -name tests.failed -objects [get_testbench_objects -filter {type == test}]]
puts "Results: passed=$pass_count failed=$fail_count"

if { $fail_count > 0 } {
  puts "ERROR: Simulation failed"
  exit 1
} else {
  puts "SUCCESS: All tests passed"
}
