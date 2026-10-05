# Usage: vivado -mode batch -source scripts/vivado/o3_ooc.tcl -tclargs OUT_DIR ?core|mul|div?
# Run from repo root. Core-only OOC, XCKU040, 100 MHz; no placement/routing.
set out_dir [file normalize [lindex $argv 0]]
set scope [lindex $argv 1]
if {$scope eq ""} {set scope core}
if {$scope ni {core mul div}} {error "scope must be core, mul or div"}
set top o3_core
set clock_port clk_i
set generic_args {}
if {$scope ne "core"} {
    set top mdu_tb_top
    set clock_port clk
    set generic_args [list -generic "DIV_UNIT=[expr {$scope eq {div} ? 1 : 0}]"]
}
file mkdir $out_dir
set t0 [clock seconds]
set fp [open rtl/rtl.f r]
set files {}
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line ne "" && ![string match {//*} $line]} {lappend files $line}
}
close $fp
set_param general.maxThreads 8
create_project -in_memory -part xcku040-ffva1156-2-e
set_property verilog_define {FPGA_TARGET} [current_fileset]
read_verilog -sv $files
if {$scope ne "core"} {read_verilog -sv sim/cocotb/mdu/mdu_tb_top.sv}
set xdc [open [file join $out_dir o3_ooc.xdc] w]
puts $xdc [format {create_clock -name core_clk -period 10.000 [get_ports %s]} $clock_port]
close $xdc
read_xdc [file join $out_dir o3_ooc.xdc]
synth_design -top $top -part xcku040-ffva1156-2-e -mode out_of_context -flatten_hierarchy rebuilt -retiming {*}$generic_args
set synth_seconds [expr {[clock seconds]-$t0}]
write_checkpoint -force [file join $out_dir ${top}_synth.dcp]
report_utilization -file [file join $out_dir utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained -file [file join $out_dir timing.rpt]
report_drc -file [file join $out_dir drc.rpt]
set fp [open [file join $out_dir summary.txt] w]
puts $fp "synth_seconds=$synth_seconds"
puts $fp "scope=$scope top=$top"
puts $fp "part=xcku040-ffva1156-2-e"
puts $fp "clock_period_ns=10.000"
puts $fp "stage=synthesis_only_no_place_route"
set paths [get_timing_paths -max_paths 1 -delay_type max]
if {[llength $paths]} {puts $fp "worst_setup_slack_ns=[get_property SLACK [lindex $paths 0]]"}
close $fp
puts "O3_OOC_SYNTH_PASS scope=$scope seconds=$synth_seconds"
