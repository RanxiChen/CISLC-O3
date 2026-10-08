# Reused diagnostic from OOC snapshot 42968c23235bd812d2361fe4acd1fc018e7b2f73.
# From archive root:
# vivado -mode batch -source scripts/vivado/mem_preview.tcl \
#   -tclargs OUT_DIR dcache|l2_home|core 0|1
# Synthesis only. The launcher must enforce 45m (modules) / 90m (core).
set out_dir [file normalize [lindex $argv 0]]
set scope [lindex $argv 1]
set retiming [lindex $argv 2]
if {$scope ni {dcache l2_home core} || $retiming ni {0 1}} {
    error "expected OUT_DIR dcache|l2_home|core 0|1"
}
file mkdir $out_dir
set top ${scope}_ooc_wrapper
set clock_port clk
if {$scope eq "core"} {set top o3_core; set clock_port clk_i}
create_project -in_memory -part xcku040-ffva1156-2-e
set_param general.maxThreads 8
set_property verilog_define {FPGA_TARGET} [current_fileset]
# The authoritative manifest defines order and include directories. Memory
# runs use its package + LSU + memory dependency closure, without CVFPU.
set fp [open rtl/rtl.f r]
set files {}
set incdirs {}
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match {//*} $line]} {continue}
    if {[string match {+incdir+*} $line]} {
        lappend incdirs [string range $line 8 end]
        continue
    }
    if {[file extension $line] ni {.sv .v}} {continue}
    if {$scope eq "core" || [string match {rtl/common/*} $line] ||
        [string match {rtl/lsu/*} $line] || [string match {rtl/memory/*} $line]} {
        lappend files $line
    }
}
close $fp
if {$scope eq "core"} {set_property include_dirs $incdirs [current_fileset]}
read_verilog -sv $files
if {$scope ne "core"} {read_verilog -sv scripts/vivado/${top}.sv}
read_xdc scripts/vivado/mem_preview.xdc
set fp [open [file join $out_dir synth_status.txt] w]
set start_ms [clock milliseconds]
puts $fp "start_utc=[clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]"
puts $fp "scope=$scope retiming=$retiming top=$top"
puts $fp "part=xcku040-ffva1156-2-e clock_period_ns=10.000"
flush $fp
set opts {}
if {$retiming} {lappend opts -retiming}
set result [catch {
    synth_design -top $top -part xcku040-ffva1156-2-e \
        -mode out_of_context -flatten_hierarchy rebuilt {*}$opts
} message options]
puts $fp "synth_seconds=[expr {([clock milliseconds]-$start_ms)/1000.0}]"
puts $fp "synth_end_utc=[clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]"
puts $fp "synth_tcl_exit=$result message=$message"
close $fp
if {$result} {return -options $options $message}
write_checkpoint -force [file join $out_dir ${top}_synth.dcp]
report_utilization -file [file join $out_dir utilization.rpt]
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -input_pins -nets \
    -file [file join $out_dir worst20.rpt]
report_timing -delay_type min -max_paths 20 -input_pins -nets \
    -file [file join $out_dir hold20.rpt]
# Keep zero-delay external diagnostics in the full summary. Separately expose
# register-to-register hold; do not hide either class with timing exceptions.
report_timing -delay_type min -max_paths 20 -from [all_registers -output_pins] \
    -to [all_registers -data_pins] -input_pins -nets \
    -file [file join $out_dir internal_hold20.rpt]
check_timing -verbose -file [file join $out_dir check_timing.rpt]
report_drc -file [file join $out_dir drc.rpt]
# Store path objects and per-point properties as supplemental machine-readable
# evidence. Logic/route split comes from report_timing's Data Path Delay line.
proc dump_paths {paths filename} {
    set fp [open $filename w]
    puts $fp "rank\tstart\tend\tslack_ns\tlevels\tdatapath_ns"
    set rank 0
    foreach path $paths {
        incr rank
        puts $fp "$rank\t[get_property STARTPOINT_PIN $path]\t[get_property ENDPOINT_PIN $path]\t[get_property SLACK $path]\t[get_property LOGIC_LEVELS $path]\t[get_property DATAPATH_DELAY $path]"
    }
    close $fp
}
dump_paths [get_timing_paths -delay_type max -max_paths 20] [file join $out_dir worst20.tsv]
if {$scope eq "dcache"} {
    foreach signal {full_line_busy_o internal_busy_o} {
        set ends [get_pins -hier -filter "NAME =~ *${signal}_boundary_q_reg*/D"]
        if {[llength $ends]} {
            report_timing -delay_type max -max_paths 20 -to $ends -input_pins -nets \
                -file [file join $out_dir ${signal}.rpt]
            dump_paths [get_timing_paths -delay_type max -max_paths 20 -to $ends] \
                [file join $out_dir ${signal}.tsv]
        }
    }
}
if {$scope eq "core"} {
    set fp [open [file join $out_dir busy_nets.txt] w]
    foreach signal {full_line_busy internal_busy} {
        set alias $signal
        if {$signal eq "full_line_busy"} {set alias dc_full_busy}
        if {$signal eq "internal_busy"} {set alias dc_internal_busy}
        set nets [get_nets -hier -filter "NAME =~ *${signal}* || NAME =~ *${alias}*"]
        puts $fp "$signal: $nets"
        if {[llength $nets]} {
            report_timing -delay_type max -max_paths 20 -through $nets -input_pins -nets \
                -file [file join $out_dir ${signal}_cross_module.rpt]
        }
    }
    close $fp
}
set fp [open [file join $out_dir memory_cells.tsv] w]
puts $fp "cell\tprimitive"
foreach cell [get_cells -hier -filter {IS_PRIMITIVE == 1}] {
    set ref [get_property REF_NAME $cell]
    set name [get_property NAME $cell]
    if {[string match RAM* $ref] || [regexp {tags_q|data_q|g_meta_way|g_tag_lane|g_data_bank} $name]} {
        puts $fp "$name\t$ref"
    }
}
close $fp
puts "MEM_PREVIEW_REPORTS_COMPLETE scope=$scope retiming=$retiming"
