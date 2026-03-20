# Replace 10.000 with your board clock period if needed
create_clock -name clk_i -period 10.000 [get_ports clk_i]

# Keep the two DUT instances for fair resource comparison
set_property DONT_TOUCH true [get_cells -hier -regexp {.*u_force_consistent.*}]
set_property DONT_TOUCH true [get_cells -hier -regexp {.*u_latest_tag.*}]
set_property KEEP_HIERARCHY yes [get_cells -hier -regexp {.*u_force_consistent.*}]
set_property KEEP_HIERARCHY yes [get_cells -hier -regexp {.*u_latest_tag.*}]

# Keep observation outputs from being optimized away
set_property DONT_TOUCH true [get_nets -hier -regexp {.*signature_consistent_o.*}]
set_property DONT_TOUCH true [get_nets -hier -regexp {.*signature_latest_o.*}]
set_property DONT_TOUCH true [get_nets -hier -regexp {.*mismatch_count_o.*}]

# Optional: expose for on-chip debug
set_property MARK_DEBUG true [get_nets -hier -regexp {.*signature_consistent_o.*}]
set_property MARK_DEBUG true [get_nets -hier -regexp {.*signature_latest_o.*}]
set_property MARK_DEBUG true [get_nets -hier -regexp {.*mismatch_count_o.*}]
