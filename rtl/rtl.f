// ============================================================================
// CISLC-O3 RTL 文件清单（唯一权威版本）
//
// 用法：
//   verilator ... -f rtl/rtl.f
//   或由 scripts/lint.sh / sim/o3/Makefile 引用，不要各自复制一份文件列表。
//
// ---------------------------------------------------------------------------
// 顺序规则（必须遵守，否则 verilator 报 "Reference to 'X' before declaration"）
// ---------------------------------------------------------------------------
// 1) 所有 package 必须排在使用它们的 module 之前。
// 2) package 之间按依赖排序：o3_isa_pkg → o3_cfg_pkg → o3_types_pkg → o3_pkg。
// 3) ftq.sv 例外：它同时定义了 package ftq_pkg 和 module ftq，
//    且 bpu.sv 使用 ftq_pkg，因此 ftq.sv 必须排在 bpu.sv 之前。
//    （这是历史遗留布局；后续应把 ftq_pkg 拆成独立文件，见 PASS 说明。）
//
// 新增 RTL 文件时：必须加入本清单，并放在它的依赖之后。
// ============================================================================

// ---------- 1. 类型 / 配置（package，顺序敏感） ----------
rtl/common/o3_isa_pkg.sv
rtl/common/o3_cfg_pkg.sv
rtl/common/o3_types_pkg.sv
rtl/common/o3_pkg.sv

// L9 fixed CVFPU dependencies; same waiver for all -f rtl/rtl.f consumers.
scripts/cvfpu.vlt
+incdir+third_party/cvfpu/src/common_cells/include
third_party/cvfpu/src/common_cells/src/cf_math_pkg.sv
third_party/cvfpu/src/common_cells/src/lzc.sv
third_party/cvfpu/src/common_cells/src/rr_arb_tree.sv
third_party/cvfpu/src/fpnew_pkg.sv
third_party/cvfpu/src/fpnew_cast_multi.sv
third_party/cvfpu/src/fpnew_classifier.sv
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v
third_party/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ctrl.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_double.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ff1.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_pack.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_prepare.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_round.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_scalar_dp.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_bound_table.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_with_sqrt.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt.v
third_party/cvfpu/vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_top.v
third_party/cvfpu/src/fpnew_divsqrt_th_32.sv
third_party/cvfpu/src/fpnew_divsqrt_th_64_multi.sv
third_party/cvfpu/src/fpnew_divsqrt_multi.sv
third_party/cvfpu/src/fpnew_fma.sv
third_party/cvfpu/src/fpnew_fma_multi.sv
third_party/cvfpu/src/fpnew_noncomp.sv
third_party/cvfpu/src/fpnew_opgroup_block.sv
third_party/cvfpu/src/fpnew_opgroup_fmt_slice.sv
third_party/cvfpu/src/fpnew_opgroup_multifmt_slice.sv
third_party/cvfpu/src/fpnew_rounding.sv
third_party/cvfpu/src/fpnew_top.sv

// ---------- 2. 前端（ftq.sv 必须先于 bpu.sv：它定义了 ftq_pkg） ----------
rtl/frontend/ftq.sv
rtl/frontend/branch_history.sv
rtl/frontend/history_snapshot_store.sv
rtl/frontend/ras.sv
rtl/frontend/ubtb.sv
rtl/frontend/main_btb.sv
rtl/frontend/tage.sv
rtl/frontend/bpu_slow_check.sv
rtl/frontend/bpu.sv
rtl/frontend/fetch_buffer.sv
rtl/frontend/fetch_return_queue.sv
rtl/frontend/icache_mshr.sv
rtl/frontend/itlb.sv
rtl/frontend/prefetch_xlate_cache.sv
rtl/frontend/fetch_prefetcher.sv
rtl/frontend/rvc_expander.sv
rtl/frontend/ifu_f0.sv
rtl/frontend/ifu_f1.sv
rtl/frontend/redirect_arbiter.sv
rtl/frontend/frontend_sync_ctrl.sv
rtl/common/pmp_checker.sv
rtl/common/pma_checker.sv
rtl/frontend/icache.sv
rtl/frontend/frontend.sv

// ---------- 3. 公共基础模块 ----------
rtl/common/lfsr.sv
rtl/common/o3_sram.sv
rtl/common/o3_sram_1r1w.sv

// ---------- 4. 后端：寄存器域 / 重命名 ----------
rtl/backend/uop_queue.sv
rtl/backend/free_list.sv
rtl/backend/rename_map_table.sv
rtl/backend/branch_checkpoint_file.sv
rtl/backend/preg_ready_table.sv
rtl/backend/rename_stage.sv
rtl/backend/rename_dispatch_queue.sv

// ---------- 5. 后端：译码 / 派发 / 发射 ----------
rtl/backend/decoder.sv
rtl/backend/dispatch_stage.sv
rtl/backend/backend_issue_queue.sv

// ---------- 6. 后端：物理寄存器堆与读写仲裁 ----------
rtl/backend/physical_regfile.sv
rtl/backend/prf_read_arbiter.sv
rtl/backend/writeback_arbiter.sv
rtl/backend/fp_writeback_arbiter.sv

// ---------- 7. 后端：执行单元 ----------
rtl/backend/alu_pipe.sv
rtl/backend/int_execute_unit.sv
rtl/backend/branch_execute_unit.sv
rtl/backend/branch_unit.sv
rtl/backend/fu_completion_fifo.sv
rtl/backend/signed_mul65x65.sv
rtl/backend/unsigned_radix4_divider.sv
rtl/backend/mul_execute_unit.sv
rtl/backend/div_execute_unit.sv
rtl/backend/mul_fusion_detect.sv
rtl/backend/fpu/fpu_fma_fu.sv
rtl/backend/fpu/fpu_divsqrt_fu.sv
rtl/backend/fpu/fpu_misc_fu.sv
rtl/backend/fpu/fpu_conv_fu.sv

// ---------- 8. 后端：访存 ----------
rtl/lsu/dtlb.sv
rtl/lsu/walk_cache.sv
rtl/lsu/ptw.sv
rtl/lsu/pte_ad_updater.sv
rtl/lsu/dcache_mshr.sv
rtl/lsu/dcache_writeback.sv
rtl/lsu/dcache_probe.sv
rtl/lsu/dcache_amo_unit.sv
rtl/lsu/lrsc_reservation.sv
rtl/lsu/dcache.sv
rtl/backend/load_queue.sv
rtl/backend/store_queue.sv
rtl/backend/load_store_unit.sv
rtl/backend/mem_head_unit.sv

// ---------- 9. 后端：ROB / 系统 ----------
rtl/backend/rob.sv

// ---------- 10. 后端总装 ----------
rtl/backend/rename_entry_gate.sv
rtl/system/hpm_counters.sv
rtl/system/csr_file.sv
rtl/system/trap_ctrl.sv
rtl/system/wfi_ctrl.sv
rtl/system/commit_ctrl.sv
rtl/backend/backend.sv

// ---------- 11. 存储层次 ----------
rtl/memory/dma_line_adapter.sv
rtl/memory/mmio_axil_master.sv
rtl/memory/l2_slots.sv
rtl/memory/l2_probe_engine.sv
rtl/memory/l2_mem_engine.sv
rtl/memory/l2_home.sv
rtl/memory/axi_master.sv

// ---------- 12. 顶层 ----------
rtl/core/o3_core.sv

// ============================================================================
// 以下文件**不在** o3_core 编译单元内，故意不列入上面清单。
// 它们各自有独立用途，需要单独编译：
//
//   rtl/O3.sv                      SoC 顶层（空壳，未例化 o3_core）
//   rtl/Tile.sv                    Tile 顶层（空壳，未例化 o3_core）
//   rtl/memory/axi_memory_smoke_top.sv
//                                  AXI4 **主机侧**独立冒烟 top，
//                                  例化 axi_master，不参与 o3_core，
//                                  也不是 AXI 从端内存模型。
//
// 需要冒烟这些文件时，显式把它们加到 verilator 命令行，不要塞进 rtl.f。
// ============================================================================
