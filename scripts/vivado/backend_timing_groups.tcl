# Read-only per-destination reg-to-reg diagnosis of the saved backend checkpoint.
# vivado -mode batch -source scripts/vivado/backend_timing_groups.tcl \
#   -tclargs CHECKPOINT OUT_DIR
set_param general.maxThreads 8
open_checkpoint [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
file mkdir $out_dir
set sinks [all_registers -data_pins]
set sources [all_registers -output_pins]
set fp [open [file join $out_dir groups.txt] w]
foreach {label prefix} {
    rename_r1 u_backend/u_rename_stage_buffer/*
    rename_dispatch u_backend/u_rename_dispatch_queue/*
    int_rat u_backend/u_rename_map_table/*
    fp_rat u_backend/u_fp_rename_map_table/*
    int_freelist u_backend/u_free_list/*
    fp_freelist u_backend/u_fp_free_list/*
    int_iq u_backend/u_int_issue_queue/*
    fp_iq u_backend/u_fp_issue_queue/*
    mem_iq u_backend/u_mem_issue_queue/*
    br_iq u_backend/u_branch_issue_queue/*
    int_buffer u_backend/int_issue_buffers*/*
    fp_buffer_rr u_backend/g_fp_issue*/*
    mem_buffer_rr u_backend/g_mem_issue*/*
    alu u_backend/alu_pipe_array*/*
    mul_rr u_backend/u_mul_regread/*
    div_rr u_backend/u_div_regread/*
    mul u_backend/u_mul_execute_unit/*
    div u_backend/u_div_execute_unit/*
    fma u_backend/g_fp_fma*/*
    fp_divsqrt u_backend/u_fp_divsqrt_fu/*
    fp_misc u_backend/u_fp_misc_fu/*
    fp_conv u_backend/u_fp_conv_fu/*
    int_prf u_backend/u_physical_regfile/*
    fp_prf u_backend/u_fp_physical_regfile/*
    rob u_backend/u_rob/*
    lq u_backend/u_load_queue/*
    sq u_backend/u_store_queue/*
    lsu u_backend/u_load_store_unit/*
    dcache u_backend/u_dcache/*
    ptw u_backend/u_ptw/*
    csr u_backend/u_csr_file/*
} {
    set ends [filter $sinks "NAME =~ $prefix"]
    puts $fp "$label endpoint_pins=[llength $ends]"
    if {[llength $ends] == 0} {continue}
    foreach p [get_timing_paths -delay_type max -max_paths 1 -from $sources -to $ends] {
        set start [get_property STARTPOINT_PIN $p]
        set end [get_property ENDPOINT_PIN $p]
        puts $fp "$label slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] from=$start to=$end"
        set start_cell [get_cells -of_objects [get_pins $start]]
        set launch [get_pins -of_objects $start_cell -filter {DIRECTION == OUT}]
        report_timing -delay_type max -max_paths 1 -from $launch -to [get_pins $end] \
            -input_pins -file [file join $out_dir ${label}.rpt]
    }
}
close $fp
puts BACKEND_TIMING_GROUPS_COMPLETE
