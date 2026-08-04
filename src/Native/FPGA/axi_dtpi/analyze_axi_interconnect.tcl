# Análisis de interconexión AXI
# Uso: vivado -mode batch -source analyze_axi_interconnect.tcl
#
# Este script inspecciona la interconexión AXI del diseño cargado
# y reporta componentes clave para streaming de voxeles.

set design [get_files -filter {USED_IN_SYNTHESIS==1 && FILE_TYPE==BlockSrcs}]
if {[llength $design] == 0} {
    puts "ERROR: No hay diseño cargado. Abrir diseño implementado primero."
    exit 1
}

set axi_interconnect [get_ips -filter {NAME =~ "*axi*" || TYPE =~ "*axi_interconnect*"}]
puts "=== Interconexiones AXI encontradas ==="
foreach ip $axi_interconnect {
    puts "  [format \"%-30s %s\" [get_property NAME $ip] [get_property TYPE $ip]]"
}

set masters [get_cells -hierarchical -filter {REF_NAME =~ "*axi_master*" || IS_PRIMITIVE==0 && CELL_TYPE==Master}]
set slaves [get_cells -hierarchical -filter {REF_NAME =~ "*axi_slave*" || IS_PRIMITIVE==0 && CELL_TYPE==Slave}]

puts ""
puts "=== AXI Masters ==="
foreach m $masters {
    puts "  [get_property NAME $m]"
}

puts ""
puts "=== AXI Slaves ==="
foreach s $slaves {
    puts "  [get_property NAME $s]"
}

set fifos [get_cells -hierarchical -filter {REF_NAME =~ "*fifo*" || ORIG_REF_NAME =~ "*fifo*"}]
puts ""
puts "=== FIFOs detectados ==="
foreach f $fifos {
    puts "  [get_property NAME $f]"
}

set reg_slices [get_cells -hierarchical -filter {REF_NAME =~ "*reg_slice*" || ORIG_REF_NAME =~ "*reg_slice*"}]
puts ""
puts "=== RegSlices detectados ==="
foreach r $reg_slices {
    puts "  [get_property NAME $r]"
}

set clk_converters [get_cells -hierarchical -filter {REF_NAME =~ "*clk_converter*" || ORIG_REF_NAME =~ "*clk_converter*"}]
puts ""
puts "=== Convertidores de reloj ==="
foreach c $clk_converters {
    puts "  [get_property NAME $c]"
}

set dw_converters [get_cells -hierarchical -filter {REF_NAME =~ "*data_width_converter*" || ORIG_REF_NAME =~ "*data_width_converter*"}]
puts ""
puts "=== Convertidores de ancho de datos ==="
foreach d $dw_converters {
    puts "  [get_property NAME $d]"
}

set protocol_converters [get_cells -hierarchical -filter {REF_NAME =~ "*protocol_converter*" || ORIG_REF_NAME =~ "*protocol_converter*"}]
puts ""
puts "=== Convertidores de protocolo ==="
foreach p $protocol_converters {
    puts "  [get_property NAME $p]"
}

puts ""
puts "=== Resumen ==="
puts "Masters:    [llength $masters]"
puts "Slaves:     [llength $slaves]"
puts "FIFOs:      [llength $fifos]"
puts "RegSlices:  [llength $reg_slices]"
puts "ClkConvert: [llength $clk_converters]"
puts "DWConvert:  [llength $dw_converters]"
puts "ProtoConv:  [llength $protocol_converters]"
