# L9 CVFPU source

CVFPU is a submodule from https://github.com/RanxiChen/cvfpu.git pinned at
`1b220f3bc89df99e246b72e3574a3a533cf87653`. Required nested common_cells is pinned at
`6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea`. Original licenses remain in the submodules.

```sh
git submodule update --init third_party/cvfpu
git -C third_party/cvfpu submodule update --init src/common_cells
```

Only common_cells is required; MVP and flexfloat are outside the THMULTI compile set.
The source set below comes from Flow `7dfa75c4eca1bd68cd82780508cc8eb84659e835`,
`design/src/main/resources/vsrc/fpnew/cvfpu-files.f`; paths are added to `rtl/rtl.f`.
`fpnew_top` is parsed for source parity; O3 instantiates split opgroup blocks.
The filelist loads `scripts/cvfpu.vlt`: only BLKANDNBLK in fixed CVFPU fpnew sources
is waived. No O3 wrapper rule is waived.

```text
+incdir+src/common_cells/include
src/common_cells/src/cf_math_pkg.sv
src/common_cells/src/lzc.sv
src/common_cells/src/rr_arb_tree.sv
src/fpnew_pkg.sv
src/fpnew_cast_multi.sv
src/fpnew_classifier.sv
vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v
vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ctrl.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_double.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ff1.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_pack.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_prepare.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_round.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_scalar_dp.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_bound_table.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_with_sqrt.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt.v
vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_top.v
src/fpnew_divsqrt_th_32.sv
src/fpnew_divsqrt_th_64_multi.sv
src/fpnew_divsqrt_multi.sv
src/fpnew_fma.sv
src/fpnew_fma_multi.sv
src/fpnew_noncomp.sv
src/fpnew_opgroup_block.sv
src/fpnew_opgroup_fmt_slice.sv
src/fpnew_opgroup_multifmt_slice.sv
src/fpnew_rounding.sv
src/fpnew_top.sv
```

Initialization completed locally. Lint and functional validation: 未运行.
