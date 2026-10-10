# Diagnose register-to-register paths in the unchanged checkpoint. The compact
# summary and one full path per sink module avoid enormous pin-list headers.
# vivado -mode batch -source scripts/vivado/frontend_timing_groups.tcl \
#   -tclargs CHECKPOINT OUT_DIR
set_param general.maxThreads 8
open_checkpoint [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
file mkdir $out_dir
set sinks [all_registers -data_pins]
set sources [all_registers -output_pins]
set fp [open [file join $out_dir groups.txt] w]
foreach {label prefix} {
    tage u_frontend/u_bpu/u_tage/*
    bpu u_frontend/u_bpu/*
    ftq u_frontend/u_ftq/*
    icache u_frontend/u_icache/*
    f0 u_frontend/u_ifu_f0/*
    f1 u_frontend/u_ifu_f1/*
    rq u_frontend/u_fetch_return_queue/*
    buffer u_frontend/u_fetch_buffer/*
    prefetch u_frontend/u_fetch_prefetcher/*
} {
    set ends [filter $sinks "NAME =~ $prefix"]
    foreach p [get_timing_paths -delay_type max -max_paths 1 -from $sources -to $ends] {
        set start [get_property STARTPOINT_PIN $p]
        set end [get_property ENDPOINT_PIN $p]
        puts $fp "$label slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] from=$start to=$end"
        set start_cell [get_cells -of_objects [get_pins $start]]
        set launch [get_pins -of_objects $start_cell -filter {DIRECTION == OUT}]
        report_timing -delay_type max -max_paths 1 -from $launch -to [get_pins $end] \
            -input_pins -nets -file [file join $out_dir ${label}.rpt]
    }
}
close $fp
