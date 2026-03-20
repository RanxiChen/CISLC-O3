# ============================================================================
# regfile_perf.xdc
# Beginner-friendly constraints for synthesis-oriented comparison.
# Use this file together with perf/regfile/run_vivado_synth.tcl.
# ============================================================================

# 1) Primary clock for KCU105.
# KCU105 platform in litex_boards uses a 125MHz input clock ("clk125"),
# so we use 8.000ns here as default timing target.
create_clock -name clk_i -period 8.000 [get_ports clk_i]


# 2) Keep both DUT instances visible and independent.
# Use direct top-level instance names to avoid huge matched-object logs.
set_property DONT_TOUCH true [get_cells u_force_consistent]
set_property DONT_TOUCH true [get_cells u_latest_tag]
set_property KEEP_HIERARCHY yes [get_cells u_force_consistent]
set_property KEEP_HIERARCHY yes [get_cells u_latest_tag]

# 3) Keep top observation outputs (signatures/counter) alive.
# Without observable outputs, Vivado may trim some logic as unused.
set_property DONT_TOUCH true [get_nets -hier -regexp {.*signature_consistent_o.*}]
set_property DONT_TOUCH true [get_nets -hier -regexp {.*signature_latest_o.*}]
set_property DONT_TOUCH true [get_nets -hier -regexp {.*mismatch_count_o.*}]

# 4) Optional debug visibility in implemented design.
# If you only care about synthesis reports, these can be removed.
set_property MARK_DEBUG true [get_nets -hier -regexp {.*signature_consistent_o.*}]
set_property MARK_DEBUG true [get_nets -hier -regexp {.*signature_latest_o.*}]
set_property MARK_DEBUG true [get_nets -hier -regexp {.*mismatch_count_o.*}]
