# -----------------------------------------------------------------------------
# run_yosys_synth.tcl -- Standalone Yosys Synthesis Script
# Analyzes gate count, cell area, and register utilization for axi4_pcie6_bridge_top
# -----------------------------------------------------------------------------

# Read Verilog RTL sources
read_verilog -sv rtl/s2_crc32_gen.v
read_verilog -sv rtl/s2_axis_regslice.v
read_verilog -sv rtl/pcie6_fec.v
read_verilog -sv rtl/pcie6_crossbar_top.v
read_verilog -sv rtl/pcie6_link_layer.v
read_verilog -sv rtl/pcie6_protocol_to_phy.v
read_verilog -sv rtl/axi4_pcie6_bridge_top.v

# Set top module
hierarchy -check -top axi4_pcie6_bridge_top

# Generic synthesis
proc
opt
fsm
opt
memory
opt

# Technology mapping to generic gates
techmap
opt

# Display generic cell statistics
stat

# Print synthesis completion notice
puts "\n[SYNTHESIS COMPLETE] Check cell counts and register allocation above.\n"
