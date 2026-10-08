# Reused diagnostic from OOC snapshot 42968c23235bd812d2361fe4acd1fc018e7b2f73.
# One 100 MHz clock. Zero external delay is a diagnostic reference;
# the wrapper registers bound all DUT input/output combinational paths.
set clock_ports [get_ports -quiet clk]
if {[llength $clock_ports] == 0} {set clock_ports [get_ports clk_i]}
create_clock -name mem_clk -period 10.000 $clock_ports
set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != clk_i}]
set_input_delay -clock mem_clk -max 0.000 $data_inputs
set_input_delay -clock mem_clk -min 0.000 $data_inputs
set_output_delay -clock mem_clk -max 0.000 [all_outputs]
set_output_delay -clock mem_clk -min 0.000 [all_outputs]
# No false paths or multicycle paths, including reset.
