// Keep the original four-lane contracts executable alongside the new default.
package ifu_test_cfg_pkg;
    function automatic o3_cfg_pkg::frontend_cfg_t with_width(input int width);
        o3_cfg_pkg::frontend_cfg_t cfg;
        cfg=o3_cfg_pkg::O3_CFG.fe;
        cfg.fetch.f0_slots=width;
        cfg.fetch.f1_width=width;
        return cfg;
    endfunction
endpackage
