2026-10-12 09:05 C19整系统结果完成并拒绝合入：Alan/chen-System-Product-Name，Vivado2022.2/AreaOptimized_high/retiming0/100MHz，07:57:00→08:35:23 CST，synth与runner0；只读35组路径分析08:35:39→08:40:39、groups0。全部41项exit文件均0，含原38静态/BIOS-RTL生成与三个综合/runner/groups项。源854文件manifest2b9a9ca7e92ad5409965d86767fa2d2be9c6ad4cdc4ab3ed34fb67afd3173481，实际153输入ed8c7f3e859b8c66d4ee87eb468b0c672adbdc82d0c05b7e08d6bdee8a21edf9；base d834162f7ff1a3e86b43abf270d57df86088ab88，子模块HEAD同C18。最终161文件归档7ba15e43188403977223f1df8cfc1413573db21ae846bba74e5ebd95fbe10a51，证据build/soc-threewide-storage19-20261012-075601/evidence与final-review.json。
C18→C19 LUT237709→242792(+5083，100.16%，超容量392)，FF103220→101828(−1392)，BRAM274.5→303(+28.5)，DSP27不变；综合估算WNS−2.662→−3.769ns(恶化1.107)，最差逻辑40→44级，TNS−15657.364、12912/466811 setup失败；WHS−.252/THS−1052.953、41613 hold失败。最差DCache probe snp_q[addr][2]→CSR mip_sw_q[13]。这轮是综合资源/时序回退，不作优化成功或可布线验收。未做opt/place/route/bitstream/板测、全核心功能证明。
分模块IFU9557对9597仅−40LUT、4093→2346FF、增加28.5BRAM；HPM7451→8857(+1406)，包含HPM的CSR整体18512→18771(+259)。其他模块也发生映射变化，不能把整系统+5083归咎于一个模块，不能把HPM孤立−294当作集成收益。IFU与HPM组合不合入；生产两文件SHA仍5de85a22da3adcf76ba1bfa844060120d7d0b0c6a5d8b80fd07a342ce3c84508/a467f79b29e932a587985cef7301c39e65566f69984efcb52e1ead43776e4de3。保持C18结构和此前已验证字段精简，三宽/FU/PRF/队列/cache/HPM数量不变；禁止双写SRAM、器件专用功能原语。后续需继续评估可移植的控制逻辑分级与数据选择，当前不少于三发射可用核心目标尚未达成。

撤回补充证据：TDPv2 原3组共9case均make/runner0、XML fail/error/skip0；OOC baseline/prepared parse0，但综合runner1，仍为Unsupported RAM template。失败结果31文件归档d6de9d68afcfd60ed8cd6ee18e9697f62be95be1338d66411494ca947b2d40f0，build/ifu-tdp-v2-savings-20261012/evidence。拒绝原因以用户单写口/可移植约束为准；通过的局部测试不能改变该决定，不在此候选继续投入。状态及各测试归档SHA保留于rejection-review.json。

2026-10-12 08:22 用户新增存储约束：不要双写 SRAM，不接受只能用于 KCU105 的功能实现。后续资源优化使用每个 SRAM 实例单写口的可移植 RTL；同步读与同址写碰撞由显式流水/旁路保证语义，不依赖厂商原语、器件专属 RAM 模式或跨端口写优先级。保持三宽、原队列容量、端口与吞吐合同。
双写 IFU 候选仅在 build/ifu-tdp-savings-20261012 与 build/ifu-tdp-v2-savings-20261012 隔离评估，未合入生产 RTL、未进入整系统 C19；现因用户约束撤回，不继续验证/优化/采用。08:19 Alan 与本地进程检查中已无其运行任务，不虚构终止操作或退出码；保留现有源码、日志和结果。TDPv1 综合 Unsupported RAM template 为独立失败证据，不能当主机不可用。
C19 整系统快照继续：IFU SHA05ff07b31ae57e0876bfc4d39328e6b6d8cfdc5ba851ac0b7e757792052aace4，payload_mem 只有一个 always_ff 写入所有者，head 预取同步读，同址碰撞由 collision_q/write_payload_q 显式旁路；不依赖双写口。综合仍在 Cross Boundary and Area Optimization，尚无新整系统面积/时序结论。主生产 IFU 尚未合入该候选。

2026-10-12 资源优化第一轮：按用户“可”实施评估，先做Decode FIFO/F0→F1缓存/CSR-HPM，保持三宽、FU/PRF端口/队列容量/cache/HPM数量。先写端口/所有权/取消/信用矩阵于build/storage-savings-20261012/port-ownership-contract.md。
Decode FIFO三种候选全原seed1的900/1200完整payload/wrap/partial/flush测试各2case成功，但均未取得LUT收益，不合入：4-bank distributed完整接口OOC baseline4103LUT/49FF/2520RAM→5944/13/1120，internal2.176→2.506ns；fixed-writer BRAM next-head预取/写碰撞旁路→5964/1489/0RAM/63BRAM，internal1.557ns；编码合并数据source mux→5001/1493/63BRAM，internal1.648ns。后两者读时序改善但LUT增加，不当作面积优化成功。独立OOC归档分别60文件2dcae5014bc74dec4b523d8896ab22b3548916795713680aec018dd6aac63855（含IFU），37文件55565f84667c9d089fb5f706c9150e755b0df9ee906d1152391539d761641e0c、37文件01b37533189b51192971dd73784e6831c002faa39d7143f71eae5f00f3e8aa14；baseline/prepared parse/runner0。原production FIFO保持C18实现。
IFU拍缓存候选：单写口BRAM保存两个固定物理beat，独立窄FTQ身份/slot支持任意取消；每沿预取next-head，同址读写注册碰撞旗标旁路并在非SYN时poison RAM输出，保持原握手沿、2容量/不借pop信用/空beat/c-prime边界规则。完整8槽public OOC baseline2381LUT/4175FF→2400/2397/29BRAM，internal2.361/6→2.975ns/7；局部LUT+19、FF−1778，不能宣称整系统省LUT。原4槽3case与8槽3case成功，F0→queue→F1的3case跨半字/取消流水成功；原bandwidth4case在当前三宽下失败，C18原版也同样4fail，均保留XML/日志。原因旧test固定count<4和100拍四条交付，而O3_CFG.fe.fetch.deliver_width已为3。独立legacy4仅在隔离sim源将deliver_width=4，原test逐字不改4case成功（f8d63dd0630c180bcdaa9b7a9531b0ee147f410f4c93191db8cf1a38fbd3ab05）；新增production3独立用例保留360区域/5000随机拍/seed1和完整指令oracle，要求400条=133拍3条+末拍1条、c-prime/fault/clear/kill合同，4case成功（1a529c3b7602ca8408b4712f19f91707407791916b5c43a6c16b9c229de168db）。原test/golden不改；新增test_ifu_bandwidth_three.py和Makefile.three。8槽首次helper EXTRA_ARGS覆盖丢掉assert/timing/Wno-fatal导致warning-fatal编译2、无XML；保留失败证据并修正完整参数后3case通过，非主机故障。
CSR/HPM候选：精确overflow_after_pending用两次INC_W窄进位及基值upper-all-ones条件，避免当前事件进入64bit forwarded值的upper reduction；architected view/count/state/overflow拍不改。HPM read/RMW平行index选择，单模块2883→2589LUT(−294)，1218FF不变，internal3.466/14→3.363ns/15。原22case与CSR13case成功。但改CSR PMP读/写选择成parallel OR后cluster10315→11285LUT、internal6.224/27→6.631ns/21，已拒绝该CSR源改写。保留原CSR+新HPM cluster仍10961LUT(+646)/5040FF(−21)/internal6.414ns/19，说明不能把单模块面积差当成集成收益；58文件44df98e127dc0f535c49142bea01325b874f78b96d0549c135b1aeabd181c8ba、retained39文件88c54d9b615cb2b3a670c29dd75fa3fb222ac44cc17c122d8ef34af1eee67521，两个组合的13case均成功，wrapper初次缺CFG默认值的parse1保留后修复，非RTL/golden失败。
整系统C19以独立快照比较IFU BRAM+新HPM，当前production这两项尚未合入。fresh cloud255→Alan0，854文件manifest2b9a9ca7e92ad5409965d86767fa2d2be9c6ad4cdc4ab3ed34fb67afd3173481，6179296bytes；base d834162f7ff1a3e86b43abf270d57df86088ab88/原子模块SHA不改；实际source override IFU05ff07b31ae57e0876bfc4d39328e6b6d8cfdc5ba851ac0b7e757792052aace4、HPM63fe2ab0c77a92875cc7214fcdf0887fadbcd5bc6055dac1ab27475dbc19d590。RTL/sim/third_party对C18差异只有operand字段保留版、候选IFU/HPM、新增三宽测试/Makefile；配置与其余RTL不改。build/soc-threewide-storage19-20261012-075601，AreaOptimized_high/retiming0/100MHz，静态/BIOS-RTL生成与整系统综合活动，尚无面积/时序结论。以整系统结果决定保留；未做opt/place/route/bitstream/板测，不把局部测试当全核心证明，旧FIFO8失败未在这轮绕过。

2026-10-12 07:03 字段精简最终保留版：仅rtl/backend/operand_read_pipeline.sv改为A0 request_owner_t、A1 rank_descriptor_t、A2 read_owner_t和capture_owner_t窄类型；保留原A1 rs1/rs2读使能、use_imm、两个域和三个preg，不把需求计算移动到入级前。非O3_SIM完整uop553位，A0 78、A1 94、A2 69、capture9（旧capture struct745）；不改变公共full-uop接口/固定payload RAM/端口mapping/槽位与order/注册信用/取消/周期/FU数/配置。IQ scheduling与各FU RegRead本来已使用sched_t、int_regread_pipe_uop_t、mdu_req_t、fpu_req_t、mem_execute_uop_t，未为字段精简改动其控制。
最终RTL SHA304afa4cb2c2663f7751f1cfa4d3561058a5ee8181750705656d38ee40bc139b与v1 OOC归档中source manifest逐字匹配。完整public同接口、10ns/all I/O0 baseline→final LUT25918→25918、FF1974→1974、RAM12496不变；internal7.455ns/21、A2 7.252ns/17不变，两parse/runner0。只将原本为零/后级不读的全uop占位声明变成明确阶段类型，综合器此前已自动消除这些位；本轮不能宣称实际资源下降或整系统时序改善。证据build/operand-fields-20261012/evidence，46文件1b55edb3b0c0763691d53f91a25299627e9d7c24ee05a7c313fe15e820d87f71。
最终保留版再次fresh读取共享配置、cloud255→Alan0；独立复制原seed1/规模/golden，加旧RTL shadow与1200拍full-random字段/立即数/域编码seed405，make0/XML2tests、fail/error/skip0。原事务模型3113ns、新1200拍4801ns均成功；其中逐拍核对全部live payload、握手、地址/port maps与三操作数，原连续三路/FMA/慢DIV隔离断言不改。build/operand-fields-final-functional-20261012-070231，854文件simulation manifestfd2074727b20fe1e494b4205e14b3ab5713dfd029444a71a1f7b1fc9e5c49e74，结果归档2ff71f38d6dc7f8e2f15d11ae54d57b7e4541cd4112d9580d30bf511dd1c529e；launch.json含实际Alan cwd/命令/工具/exit，production原测试逐字不变。相对C18的685 RTL/sim/third_party绑定审计只有该一文件变化，patch/审计与复现脚本位于build/operand-fields-final-20261012。全核心/SoC功能与物理验收仍未完成。
试验v2的两个有效INT需求位虽减少A1声明5bit且两功能用例通过，但OOC LUT25918→26138(+220)、FF1974→1980(+6)、internal7.455→7.684ns/21；A2 7.252/17→7.265ns/18。两parse/runner0、46文件056d59792e36494ae3ecda32b3257a8ede6e7ac42eda27dbaf06e5acde519c5d，build/operand-fields-v2-20261012/evidence；已撤回这部分production变更，保留独立失败收益证据。下方之前v2活动记录为历史状态，当前生产采用上述最终保留版。无其他资源裁剪/流水改动/未相关功能修复。

2026-10-12 字段精简范围冻结：用户明确“先做精简字段吧，其他的先不改”。相对C18冻结源，本轮RTL/sim/third_party逐文件差异只有rtl/backend/operand_read_pipeline.sv；三宽、FU数量、PRF端口、队列/cache容量、流水拍数、排序/取消/注册信用规则不改，不合入build中的LQ top-P/A2固定存储/HPM候选，不修复无关FIFO8用例。
A0 mutable record只留valid/ROB年龄身份/instruction_id/main与fuse-lo masks；A1只留valid/instruction_id/main mask/三个源preg/两个有效INT读需求，立即数和域按原NONE/INT/FP比较折叠为需求位；A2只留valid/instruction_id/main mask，地址和端口mapping仍原独立字段；capture mutable record只留valid/main mask/lo mask，完整payload与操作数仍存原固定槽RAM。当前非O3_SIM声明位宽full uop553，A0 78、A1 89、A2 69、capture9（原capture record745）；这些是声明位宽，不能直接当FF/LUT节省，64bit instruction_id仍供原身份断言，综合可裁掉。
验证：原test_operand_read_pipeline.py bytewise不改、seed1/原500随机拍和连续三路/FMA/慢DIV隔离断言保留；build中追加旧RTL shadow逐沿完整valid payload/handshake/maps/data比较，以及1200拍任意完整payload/立即数/全部四种域编码、随机取消/回压，新增seed405。Alan/Verilator5.050/cocotb2.1.0 make0/XML2tests、0fail/error/skip，原3113ns+新增4801ns，未表示全核心功能通过。fresh共享配置cloud255超时后Alan0，cwd/命令/工具/主机/exit/XML在build/operand-fields-v2-functional-20261012-065826；854文件simulation manifest61a10208cc444ca63612291f78a309d2e0070a64a6d1c89751a9f53e9928dd59，结果归档72ecf2930a40a1accae7726003131280979d02403be24d1aed020d6d6ebd0e57。测试fixture全部在隔离build源码中，production旧golden未改。
字段窄类型v1完整public同接口、10ns/all I/O0 OOC两parse/runner0，LUT25918/FF1974/RAM12496与baseline完全相同，internal7.455ns/21级也相同，证明原zero descriptor死字段已被综合裁剪；46文件归档1b55edb3b0c0763691d53f91a25299627e9d7c24ee05a7c313fe15e820d87f71，build/operand-fields-20261012/evidence。最终需求位编码v2单独OOC活动，尚不宣称资源收益或整系统改善。

2026-10-12 06:41:47 CST C18整SoC综合完成（05:37:33开始，报告synth_and_report_seconds3834；不能将该报告时长当起止wall差），synth/runner/groups exit0。LUT237709/242400(98.06%，较C17v2减3400)，FF103220，BRAM274.5/600，DSP27；100MHz综合估算WNS−2.662ns/40级，TNS−9342.409ns、9462/468697 setup失败，WHS−.252/THS−1078.845、42265 hold失败。最差DCache ps_resp_q[paddr][8]→MSHR/PTE AD响应性能事件→HPM→CSR mip_sw_q[13]，非FU算术执行链；仍无opt/place/route/bitstream/板测。852源码93abfe1e72c8525a701e9a6bce2824e3f98d30489ebd841ffbb358a27e2cd725、实际153输入2072cfcd859ee12090da879306b02a502b5e372951d0ce51ec455631eb3a35cf/external=[]，base d834162f7ff1a3e86b43abf270d57df86088ab88，Alan/Vivado2022.2/AreaOptimized_high/retiming0。最新161文件含35项group报告归档0e9f16e7d09a3ebaaf760276299b3b372534eeaf31622edce8ff0162f0470f73，build/soc-threewide-components18-20261012-052848；原generation-phase归档独立保留。该C18是字段修改前结果，不与本轮字段v2混同。

2026-10-12 06:11进展核对：C18整SoC仍Timing Optimization，尚无synth/runner.exit。模块功能回归采用冻结C18源码93abfe1e72c8525a701e9a6bce2824e3f98d30489ebd841ffbb358a27e2cd725，实际Alan；完整独立模块范围55套默认+FP free-list/FP writeback/FIFO8三变体，保留每Makefile/test原默认seed（writeback默认105，不统一覆盖为1）。已返回6项、16个testcase，其中FIFO8变体1个failure，其他15个case成功，error/skip为0：free_list-default, free_list-fp, register_storage-default, fu_buffer_storage-default, fu_completion_fifo-default, fu_completion_fifo-depth8；FIFO8首个功能失败后orchestrator已停止后续，保留make/XML证据待定位，当前不执行整核心。证据build/module-functional-c18-20261012-060728；记录包含逐项fresh cloud-first/Alan预检、frozen source、cwd、命令、exit/XML和归档hash。C17v2最新已完成整系统数字仍LUT241109/242400(99.47%)、100MHz综合WNS−4.120ns/40级，未完成物理/板测可用验收。
A2固定物理地址包v1两parse/runner0，46文件归档70d6a934a1f747c33bd19d95339702106346d78b2ae894768092875520ff4562，build/threewide-operand-stationary-read-prepared/evidence；完整接口all I/O0 LUT25918→25271(−647)、FF1974→1950、RAM12496不变，但internal7.455→7.844ns、A2 7.252/17→7.844ns/21，暂不合入。v2用registered packet count直接准入、physical live owner计reserved credit，追加与logical视图等价断言，仍保持旧public周期和信用；在build独立评估，不改变C18 production或本轮功能源码。

2026-10-12 06:02：按用户最终不少于3发射可用核心目标，流水分级RTL编码阶段结束，进入用户要求的“后端重构完成后一块修”功能阶段。当前production冻结C18，685 RTL/sim/third_party逐文件再次核对无漂移；LQ top-P/A2固定地址/HPM候选仅build中，均不纳入本轮功能输入。开始31项完整默认模块回归，保留golden/seed/scale/assert；每项编译/仿真前fresh读取共享simulation-host.md、cloud-first/Alan fallback并记录实际主机/命令/exit/XML计数。独立模块失败不通过换host/改golden掩盖；功能结果当前尚未返回。全核心/SoC功能在前置模块通过后进行；当前整系统C18综合继续，opt/place/route/bitstream/板测尚未启动。该阶段切换不等于功能或物理验收通过，最终目标未达成。

2026-10-12 05:59：C18冻结源仍活动整系统综合；read-only group诊断追加LQ/LSU replay_rr/SQ终点，不改变153实际综合输入。
独立LQ oldest-top-P候选全部完整public+原read-only observer接口、同all I/O0/10ns：v1两parse/runner0，LUT15086→15485(+399)、FF3277/RAM984不变，内部8.022ns/23→6.774ns/18，输入→状态7.518→6.252ns/18，state→replay7.700→6.734ns/18，input→replay7.196→6.212ns/18；38文件归档0b48f8a1f9326e714bc7b80e44cfdec2bb08595b419a673c5e44a6567b6471df，build/threewide-lq-top-p-prepared/evidence。v2将P==1/2的每节点合并写成固定head/runner比较，generic P>2保留list merge；两parse/runner0，LUT15598(+512)、FF/RAM不变，内部6.510ns/18、输入→状态5.988ns/18、state→replay6.481ns/17、input→replay5.959ns/17；40文件dbde1d192e8162e488f44e9339581b91f3354339f5fbc3f755b8455ad482a998，build/threewide-lq-top-p-prepared-v2/evidence。每版9.6万纯算法圆环年龄/valid/ready/取消/flush/depth3/4/7/8/15/16/17/32/physicalP1..4/memP<=physicalP向量与线性圆环oracle一致，seed405；非RTL仿真。当前均在build中，公共周期/排序/两路吞吐不变，待C18整体面积反馈决定是否合入；不能把完整observer OOC面积差直接算成全系统增量。
读口取消预算factorization候选两parse/runner0但拒绝合入：完整接口同backend current mispredict OR issue_block接法、all I/O0。LUT25918→25951(+33)、FF1974/RAM12496不变；A2 internal7.252ns/17→8.220ns/20、input6.830→7.859ns/20，总体最差7.455→8.220。虽A1偶然改善，主要目标A2变差；46文件34154546c493ccf8c5c2f4902f3d5bd4ebf5828b15a40343a2b9d4c1282d3c34，build/threewide-operand-cancel-budget-prepared/evidence。已另准备A2两包固定物理存储+窄order/count候选，消除取消/部分消费后的宽包搬移，保留旧read_d为SYNTHESIS排除的等价observer、原public周期/注册准入/不借current-consume容量。解析两0，综合活动；10万纯逻辑队列/物理存储identity、全maps、partial/kill/correct/flush/reset/信用周期seed405一致，非RTL仿真。不在production。
HPM配置E-1one-hot selector候选两parse/runner0，但拒绝合入：LUT2883→3725(+842)、FF1218→2242(+1024)，event→state2.299ns/8→2.444ns/8，event→overflow2.543→2.658ns/8，internal3.466→3.556ns/15。38文件262ba1fc625240a0cb16b69a7719b1408cc5a18b21e6dccef21f447a35a56705，build/threewide-hpm-selector-prepared/evidence；全部65536selector纯算法覆盖FE holes/source/range/multi-count等价seed405，非RTL仿真。旧HPM RTL/黄金不改。
当前production仍C18；保留三宽/FU/cache/端口/100MHz，不再裁剪；功能/opt/place/route/bitstream/板测未启动，最终可用目标未达成。已只读整理31项完整默认模块回归inventory于build/backend-refactor-functional-plan/inventory.json，标记not_started_backend_refactor_gate，无make/编译/仿真执行。

2026-10-12 05:43：C17v2整系统综合/runner/只读group全部exit0，04:42:00→05:37:30 CST、3311秒。LUT241109/242400(99.47%)，Logic217895/RAM23214，FF101150，BRAM202.5，DSP27；100MHz综合估算WNS−4.120ns/40级，最差branch_result valid→LQ串行两路replay选择/payload→LSU replay_rr base_value；TNS−11457.035ns、11500/476038 setup失败，WHS−.252ns/THS−1062.794ns、41800 hold失败。ROB整体+.892ns、R3 payload+2.126ns/ready+1.550ns，free capacity−1.585ns，IQ INT/FP/MEM/BR−1.741/−1.357/−2.157/−.805ns，A1−.638/A2−1.691/capture−.066ns，HPM−1.749ns，TAGE首更新−2.445ns；ALU+2.748、FMA+2.283、INT/FP W1+1.635/+2.847、L2+2.663、DCache+.070ns。当前LQ最差不是FU算术链；准备独立评估共享top-P年龄选择树，保持现有公共replay周期/优先顺序/两路吞吐，不先改production。
C17v2固定852源码49e973beb6b4180bbb9b8269d6d7a2f399528e20ad8d32c8ac0c28f3ed805944、153实际输入57cd8c1d181ec502a5e484a9cda282a615a791677d27776d949ac113808135a8/external=[]；base d834162f7ff1a3e86b43abf270d57df86088ab88，Alan chen-System-Product-Name/Vivado2022.2/AreaOptimized_high/retiming0。155文件最终再次拉取归档ee81534ff599bd1a820de0571fdbdc8b161534b0dfb639f04eb0cc71fd8bb4ff(含29项group路径报告；先前同155文件归档8f256f4b392e0226b3d4b5d7e54a9242bcb077d1b9c6ed514dfd92a7f836f844另存)，build/soc-threewide-components17v2-20261012-041314；原105文件生成归档626dde57eac5b805f64780cd58dd5e55139e8c3825ffc5aaea7f28a3a68117fa单独保存，不混同最终。
C18已冻结并完成37项静态+生产BIOS/RTL生成共38项exit0，parse/lint无UNOPTFLAT/LATCH/Error；685个RTL/sim/third_party文件与冻结输入逐文件一致。852源码93abfe1e72c8525a701e9a6bce2824e3f98d30489ebd841ffbb358a27e2cd725(6125143bytes)、153实际输入2072cfcd859ee12090da879306b02a502b5e372951d0ce51ec455631eb3a35cf/external=[]；base/子模块HEAD同前，fresh cloud255超时/Alan0。105文件生成归档514a09ec92b6611ca94e0fb13febdd092ce597c86060d9f74c6f527a96d3eba4，build/soc-threewide-components18-20261012-052848/generation-phase-review.tar.gz；05:37:33 CST在C17v2 runner0之后串行启动整系统综合。包含C17v2+IQ incoming ready+dispatch并行比较+free cached-first-N+TAGE行捕获+RDQ BRAM next-head v3；保持三宽/FU/cache/端口/100MHz，不再裁剪。未执行功能/opt/place/route/bitstream/板测，最终不少于三发射可用核心目标尚未达成。

2026-10-12 05:28：RDQ v3已合生产：next ownership head同步BRAM预取；每writer一个共享write-data寄存器；用survivor-prefix+writer lane的head rank记写读collision，新增与原物理row equality等价仿真断言，仍将实际同址读数据poison验证旁路。未增加公共dequeue沿/容量/current-consume信用/FSM，空/未使用head由public registered count屏蔽。每拍预取所有head，不用晚count_next拉BRAM EN；当前指令payload在原规定沿可见。
完整三宽public接口v3两parse/runner0、同全部I/O0：LUT5890→4790(−1100)，FF136→1745(+1609)，分布式RAM2880→0，BRAM0→72。内部3.028ns/7→3.745ns/9级、input→state2.829→2.832ns/7级、state→output1.755ns/5→2.332ns/3级；局部延迟略变慢，选择理由是减少LUT/均衡存储资源，不宣称局部总体时序收益。33文件29ef7431b74295a11c2d1db2afc416ada9572196fd64770edaa7d37ab3824dfa，build/threewide-rdq-head-prefetch-prepared-v3/evidence。v1/v2归档各33文件b517b500335d5c761fc8f2e2b89b283e605a26ccef0144c5ab31507bb56d2db6/49ef4e0bf745eb06389913cd7e45d9f2d1e385a82e2dddbf6ea780b341dcb9c9保留，前者只减305LUT且内部4.250ns不合；v2−1109但late count_next→BRAM EN内部3.858ns，v3仅多9LUT以去该使能控制。
两个独立算法模型各9万ownership周期seed405/depth4/8/16/width1/3/4/640-bit payload覆盖invalid/复位/清bit/误预测/新head/old survivor/poisoned同址读写与head-rank身份，通过但非RTL仿真。旧RDQ全部600/700黄金/seed/规模bytewise exact prefix，追加256连续满宽同沿enqueue/dequeue、10拍head保持及old survivor/new head/writer复用合同；AST0、git diff --check0；功能未执行。
C18准备合并C17v2+IQ incoming-ready预计算+dispatch并行容量比较+free-list cached first-WIDTH/请求计数消耗+TAGE T1行捕获+本RDQ v3。四宽此前始终超限后已授权三宽；保持当前三宽/FU/cache/ROB/PRF端口/100MHz，不再裁剪。C17v2固定source活动Timing Optimization不取消；新整SoC将fresh cloud-first/Alan预检、全部静态/生产BIOS-RTL生成并串行等待C17v2。下一轮用于判定全系统资源与控制路径，不将局部OOC数字简单相加当整系统结论。最终功能、物理时序、bitstream和板测未完成。

2026-10-12 05:15：TAGE完整行捕获候选两parse/runner0，无UNOPTFLAT/LATCH。完整接口独立OOC内部8.272ns/18→6.924ns/17级；LUT9602→10257(+655)，FF6110→6627(+517)，BRAM14不变。29文件e2d738a4e24d99d2447beba2970bd31d12702255fc80f4acea846773da3de1f3，build/threewide-tage-row-capture-prepared/evidence。已合生产，表可见多一拍，query仍第二沿输出、非冲突训练仍每拍一包；保留T1-only同址hazard并从较老second-slice完整组合结果旁路当前行捕获。RTL保留t2_*/t3_*原信号名，头注释明确其实际T3/T4边界。tage_model.py逐字不改(sha25678d11ef5d395c3ea4a7549dbe4fedca4dcc8a2347ad1c7410e08393c1f11fb22)，仅bench多一拍transport与write schedule3→4，原256 legacy全bit比较和stalls==255断言、旧seed/随机规模不改，追加512 A/B逐拍回访旁路与query stall/kill合同；BPU排空等待3→4适配，均未运行功能。
Free-list最终选cached候选+按请求总数消耗前N个identity，保留bitmap/count精确更新与恢复优先级，去除当拍request-routed preg再decode；与bitmap/count同沿准备候选，无新增公共分配周期、同拍release信用/FSM。两域完整接口OOC两parse/runner0、all I/O0：INT LUT1869→2061(+192)/FF384→406/内部6.213→4.536ns(15→11级)，alloc→state4.496→4.065ns(12→11级)；FP1995→1928(−67)/391→412/内部6.653→4.735ns(16→12级)，alloc→state4.929→4.218ns(13→12级)。两组各37文件INT3be5aa3c778251245da903ad373a9d92e5e7b4a7ac0705763291fa84be254023、FPe03c78378e1f68b5da7066c77cf70dea5c6e5cb079615096b4bdfdf3f6ae7dad；build/threewide-free-cache-counted[-fp]-prepared/evidence。已合生产；旧全部free-list测试bytewise exact prefix，追加256连续满宽包、无current-release借用、already-free/same-boundary/duplicate返回sorted-set合同，AST0但功能未运行。cache+delta/纯delta候选不合入。Dispatch首版helper失败最终13文件0b4e356a8e819f4c24d0aea9a1e38f9296a75645fd59e4df7d719eec20b1509e，baseline parse1，pid已退出且无vivado.log；早退helper未写runner.exit，不伪造runner返回值。
当前另评估RDQ next-head同步BRAM预取+新写head显式旁路，仅build/threewide-rdq-head-prefetch-prepared，不在生产。预计消除分布式payload RAM占用，但等待完整接口面积/内部及I/O路径报告，不因只减少FF就盲目合入。旧RDQ 600/700全payload黄金、容量/恢复/对外边沿/同拍空队列入队可见规则不改。C17v2固定源仍综合，不取消；拟C18合并已获证据改动及必要RDQ优化后冻结，同一任务完整综合必须等C17v2 runner.exit。没有功能/opt/P&R/bitstream/板测；最终可用目标未达成。

2026-10-12 05:06：在C17v2独立固定输入继续综合的同时，合入两项组合控制改写，不增加stage/FSM或改变公共入队/选择周期。IQ incoming readiness按dispatch lane先解码再选物理row，四类完整接口OOC baseline/prepared两parse/runner0、同全部I/O零delay：LUT34097→31243(−2854)，FF1439不变；input→ready5.686ns/18→4.566ns/14级，内部最差6.364→6.415ns(略变慢，非内部总体时序收益)。31文件868429c85db110006268bbaf7ec0bd7857102a23ee9754eb06ba3b3e3606f9d8，build/threewide-iq-ingress-prepared/evidence。新增在合法单writer情况下与原row-selected readiness逐源等价的RTL仿真断言；旧全部IQ黄金/seed/规模不改，未运行功能。
Dispatch需求前缀只由decoded分类/可见lane计算，各lane容量比较并行后prefix AND。保留原bounded subtraction，包括异常/serialize强制前缀和重叠分类的legacy bounded-underflow、FP/MEM域分类、FUSE_HEAD/MEMBER、可见invalid holes和恢复禁止。20万纯代数向量seed405与原顺序扣减规则一致，非RTL仿真。完整public三宽接口v2 baseline/prepared两parse/runner0，相同virtual10ns/allI/O0：LUT63→57，输入→输出最差3.310ns/11→1.571ns/5级。29文件6dbdede42f6e0b37333d4200f5738b67932993d32d55a03b37fa8ef51a9fce3f，build/threewide-dispatch-prefix-prepared-v2/evidence。首版OOC helper误用rename fixture文件名，baseline parse1未进入Vivado，失败证据保留；修正的是helper，不改生产RTL/黄金。
Free-list registered候选视图独立两域parse/runner0：INT LUT1869→1829/FF384→406/内部6.213→5.159ns(15→12级)，FP1995→1939/391→412/6.653→4.994ns(16→12级)，FP alloc→state4.929→4.477ns/13→12级。35文件INT3b730ef376ec360c1a5a7d1c1c9806cfc27294ecb41b75804789239120f75576、37文件FP3504ebc9e4ed7ef7d25e16d1025d5227cfe2d40e3c28722e56e88c3a2270a433。cache+delta另一INT候选2176LUT/411FF/4.702ns内部/4.123ns alloc→state，相比cache-only面积又高347，不合入；37文件be9919928693e10db1a98617ff0b76c5a29c854bd58ee306c5320a3cb482d14c。正在改进cache-only位图消耗：registered candidate身份先decode，与当前请求总数并行，用“前N个候选”代替request-routed preg再decode，仍相同位图/count/候选同沿更新。7.2万纯算法周期seed405覆盖INT/FP、depth33/40/63/64/65/96、width1/3/4缓存视图和delta恒等式，通过但不是RTL仿真。尚未合入free-list。
TAGE T0 SRAM→T1完整行/旁路capture→T2首四槽→T3尾四槽→T4原子写候选独立评估。下一同址训练在T1通过较早事务已完成second-slice组合结果旁路，保留原T1-only接收冲突规则及独立每拍一包；query S0/S1/S2周期不改，表可见晚一沿，无新FSM。尚未合生产，原TAGE模型/全部golden未改，功能后置。C17v2仍活动，之后C18必须串行等待，当前三宽/FU/cache/端口/100MHz不裁剪；容量已有C16证据，时序/物理/功能/板测及最终可用目标尚未闭合。

2026-10-12 04:54：C16整系统综合和只读分组全部exit0，首次三宽完整生产SoC LUT容量落入KU040：239376/242400(98.75%)，Logic216241/RAM23135/FF100991/BRAM202.5/DSP27。100MHz综合估算WNS−4.182ns、最差42级，从R1 valid经重命名/空闲分配到FP free-list group_count；TNS−28720.133ns、29124/475098 setup失败，WHS−.252ns/THS−1043.326ns、41160 hold失败。容量内仅是综合证据，尚无物理实现/功能/板测证明。
分组：INT/FP/MEM/BR IQ −1.859/−1.880/−2.012/−1.745ns；ROB −1.758ns，R3 payload/ready −.534/−.705ns；A1 −.698ns，A2 −1.706ns，capture −.159ns；ALU +3.298ns，FMA +2.283ns，INT/FP W1 +1.522/+3.569ns，L2 +2.537ns，DCache +.346ns；TAGE第一更新 −2.445ns/33级，T3 payload/control −1.076/−1.300ns；HPM −2.082ns/39级，实际从DCache probe query经过事件形成，不把终点名称当唯一瓶颈。
固定C16：852源码4072b2ef28c6adc9f3ee99697fc50dba834be9a91eebe857bbb1c65c5822c2af，153实际输入2bdc443a49f799d3c00ec65f7a4e7fcb02ba35c1e13314bbd36c892a56a3acdb/external=[]，base d834162f7ff1a3e86b43abf270d57df86088ab88，Alan chen-System-Product-Name，Vivado2022.2 AreaOptimized_high/retiming0，cwd=/home/chen/FUN/CISLC-O3-runs/soc-threewide-components16-20261012-032952。03:48:38→04:41:48 CST/3170秒，153文件最终归档74f8a1fc554d15417bb640e854443b65f9eefc865a8b565469dc7b26713e1bfc，build/soc-threewide-components16-20261012-032952；原103文件生成归档另外保存generation-phase-review.tar.gz。C17v2固定49e973be.../57cd8c1d...于04:42:00 CST串行启动完整综合，正在运行，不取消。
独立free-list增减计数候选两域parse/runner0，但拒绝合入：INT LUT1869→2134(+265)/内部6.213→5.948ns/输入到count4.496→4.610ns，FP1995→2176(+181)/6.653→5.938ns/4.929→4.580ns；增加面积且仍保留编码/释放碰撞深反馈。INT33文件归档d8d62ed92a23c85c04e75cc4b45b30a0080923c40631999b906603e99e0e0838、FP33文件4926e5bc29935e8e3cfb1ef5bdef35f76fbc74ce388d874998a129ae368bf675，build/threewide-free-delta[-fp]-prepared/evidence。40万纯代数INT/FP向量seed405通过，仅算法不是RTL仿真。当前另评估free-list next-bitmap→registered first-WIDTH candidate视图：与bitmap/count同沿更新，无额外公共分配周期、同拍release借用或FSM；仅build/threewide-free-cache-prepared候选，未合生产/C17v2。继续保持三宽、全部当前FU/cache/PRF配置和100MHz；功能后置，最终可用目标未达成。

2026-10-12 04:15固定C17v2：soc-threewide-components17v2-20261012-041314，852源码49e973beb6b4180bbb9b8269d6d7a2f399528e20ad8d32c8ac0c28f3ed805944，153实际生产输入57cd8c1d181ec502a5e484a9cda282a615a791677d27776d949ac113808135a8，external=[]，base d834162f7ff1a3e86b43abf270d57df86088ab88/submodules原固定版。fresh cloud SSH255连接超时/Alan0，实际Alan chen-System-Product-Name；37静态+生产BIOS/RTL生成共38项0，当前完整parse无UNOPTFLAT，无新LATCH/Error，不增加warning waiver。105文件生成阶段归档626dde57eac5b805f64780cd58dd5e55139e8c3825ffc5aaea7f28a3a68117fa，另存generation-phase-review.tar.gz，build/soc-threewide-components17v2-20261012-041314。
Alan runner2529057/groups watcher2529472，run.sh明确等待C16 runner.exit（新增串行guard），尚无synth.start，不是整系统综合结果。包含C16全部及FPU双项hold/输出过程拆分、rename并行容量比较/完整fixture、DTLB查询index过程拆分、SQ携带ready及等价断言；三宽/FU/cache/ROB/IQ/PRF配置不再减少，100MHz不变。C17首版失败17文件最终归档6a7baa27b0d7bdcdaa5dd2dea57f0362256d536ee04a1e0c2a1745da22d304c4，未生成/Vivado。C16仍活动，不取消；等待C16/C17v2整体容量和路径反馈。功能仍后置，无opt/P&R/bitstream/板测；最终可用目标尚未达成。

2026-10-12 04:13：C17首快照soc-threewide-components17-20261012-041143，852源码76ca871639dfc6d452ff4f97652676f305a61105a884b85e9a41c9f3310faf35，fresh cloud255/Alan0。生产lint0；新增rename fixture的两个field-mask观察值给enum直接赋'1导致ENUMVALUE，rename-stage-parse/runner1，未启动生产生成/Vivado，不能归因主机/生产RTL。已将观察器赋值改为reg_domain_e/fuse_role_e显式cast；生产RTL及黄金不改。失败快照/日志保留，下一C17v2重新fresh预检/冻结；C16活动综合不动。

2026-10-12 04:11：SQ最年轻overlap选择记录携带该项full_ready，去掉选idx后再mux全部entry predicates。原youngest-overlap/youngest-full-cover/unknown block/partial cover/data输出规则、dual查询/提交/drain/容量/阶段不改，无新FSM/寄存级。完整实际SQ接口DCACHE_DRAIN=1独立OOC baseline/prepared parse/runner0，全部I/O同零delay约束：LUT15472→14089(−1383)、RAM1512不变、FF2597→2596，最差8.198→7.738ns；query address→forwardvalid6.782ns/28→6.092ns/25级。29文件2033243e2d34a6aba985fa374c3800bd2ae5e125313e6e407d048e71ea6fa650，build/threewide-sq-query-prepared/evidence。已合生产，追加winner carried-ready等价旧indexed-ready仿真断言（不在OOC候选输入）；旧全部SQ golden/seed/规模未改，未执行功能。HPM系统最差从LSU S1 address经SQ查询到OF，主要深逻辑在SQ查询，不再仅因终点是HPM就改变counter CSR语义。
拟固定C17=此前C16+FPU双项hold/输出过程拆分+rename并行容量比较+DTLB地址过程拆分+SQ携带ready；C16继续运行，当前只冻结新的生产输入并串行排队，不取消活动综合，不发起物理实现或功能仿真。

2026-10-12 04:09：FPU双项完成缓冲CONV完整接口OOC两parse/runner0。相同全部I/O零delay约束，LUT2100→2158(+58)、FF673→747(+74)，最差裕量4.074ns不变；resp_ready_i→wake由1.867ns/6级变为No timing paths，实际切断当拍W0选择反馈，非时序例外。30文件524cba1ce10737221618e44879947591c7096a1d683416ce0b37e00d74da2f15，build/threewide-fpu-hold-prepared/evidence。生产共用transport合入两项hold/FMA min identity10；native SP5/DP7无改，增加共享resp输出与W0ack组合process拆分，消除process-wide伪反馈。新增七种满两项+第三FMV等待/当前ready切换不借credit/clear/head、tail、both kill/flush/reset/identity复用合同；旧全部测试bytewise exact prefix，未执行功能。
Rename R2资源需求前缀独立于当前free counts，各lane并行容量比较后prefix AND，替代逐条accepted lane扣减资源，保持旧缺资源最老截断、invalid visible holes、INT/FP分域p0及MUL HEAD lookahead、branchmask规则；不新增资源分配沿/FSM。完整三宽接口含FP/第三源OOC baseline/prepared parse/runner0，相同virtual10ns/allI/O0约束，LUT180→162(−18)，最差组合3.066→1.906ns；preg容量→laneaccept2.769ns/8→1.727ns/6级。29文件63a2649c42674447b81c3ec0d010c2bce6c11aa73531252be203c979f522006b，build/threewide-rename-prefix-prepared/evidence。20万Python纯代数向量seed405逐字原预算过程对比PASS，仅算法非RTL；旧900 golden/seed/规模bytewise exact prefix，wrapper补齐原缺FP容量/第三源可控口，追加512分域/融合/holes独立原过程oracle用例未运行。
当前preview040538 32checks0，852 source605f2a335c540e70d1b1ab9bd544f0d86627a0272c064739d2e69b8d51758144；随后resp组合process拆分、DTLB RAM读index独立continuous assign仅消除地址/返回伪反馈，未改变硬件流水/查表周期，此两小修改不在该preview。最终检查增加rename fixture。SQ查询树携带winner readiness候选独立OOC运行，不在生产。C16固定source继续整系统综合，不取消；拟新增C17须串行等待C16。资源/100MHz/功能/物理未闭合。

2026-10-12 04:00：C14完整生产SoC synthesis/runner/只读分组exit0，03:00:56→03:48:28 CST，2833秒。LUT244534/242400(100.88%)、Logic221432、RAM23102、FF100600、BRAM202.5、DSP27，仍超资源2134 LUT；100MHz综合估算WNS−5.576ns/TNS−111480.953ns，48298/474405 setup失败，WHS−.252ns/THS−1106.687ns，43151 hold失败。最差free_bitmap→rename→RDQ payload CE 45级，ROB alloc −4.118ns/41级，R3 payload/ready −2.418/−3.672ns；此前整数IQ瓶颈改善为−1.967ns/35级，FP IQ−3.892ns/41级。A1−1.412ns/35级、A2−1.814ns/33级，capture+.926ns，ALU+3.151ns、FMA+2.283ns、INT W1+1.802ns、FP W1+3.472ns；HPM−2.479ns/42级、TAGE T3控制−1.300ns/34级、FE训练first−2.445ns/33级、DCache−1.178ns/35级、L2+.770ns/28级。原始报告保留，未用局部OOC代替系统结论。
固定852源码8a1a47d62828900f8ecda078edcba82264bfd95baa204ca3922731afee3253f2、153实际输入5a66820f64451412eb1c49a29258a9527f5479b605819c8e5646f3a21f83066d，base d834162f7ff1a3e86b43abf270d57df86088ab88，cwd=/home/chen/FUN/CISLC-O3-runs/soc-threewide-components14-20261012-024957；Vivado2022.2 KU040-2 AreaOptimized_high全生产SoC、100MHz、retiming0。147文件最终归档f1229fb1b764a1e8768f1316d8167cca57742c6ea577f6cc45a9c4017f4d0bf8，build/soc-threewide-components14-20261012-024957。原gen-only归档记录为历史阶段，不是该最终归档。C16已串行启动综合，固定4072b2ef.../2bdc443a...，包含L2 bounded/IQ注册accepted→下一拍reclaim/free-list exact registered capacity及operand组合地址拆分；等待整系统结果。没有功能/opt/P&R/bitstream/板测；资源与100MHz尚未闭合，目标仍未完成。
FPU双项本地完成缓冲仅独立候选：current registered count提供capture信用，不借当拍W0 consume，head交接W0才释放identity；live结果排队，kill/flush逐head discard，实际PRF/ROB仍W1。无阻塞count1 pop+push保持每拍一个结果，full停顿允许容量限制；FMA最低identity为DP7+两项hold+slack1=10。候选build/threewide-fpu-hold-prepared，当前只评估CONV完整接口OOC和resp_ready→wake因果路径，未合生产/C16，未功能测试。

2026-10-12 03:39：F0/F1二行payload RAM独立候选v2两parse/runner0，完整生产8-slot接口相同。LUT2381→2527(+146)、FF4175→307(−3868)、RAM0→1180；内部2.361→2.339ns/6级，I/O未约束。27文件c1620209c3ab2218e83caead4bf2d4f3b8e9f734e3e291c52787c88f0812f4fb，build/threewide-ifu-payload-prepared-v2/evidence。当前瓶颈是LUT而非FF，本候选拒绝合入；生产仍原二行stationary FF payload，旧FE黄金/测试完全未改。C16固定source不包含候选，无多余下一排队快照。
吞吐信用静态复核：FMA的实际identity容量为max(config8,DP7+holding1+registered-admission slack1)=9，单格式独立请求在结果端可接受时覆盖II1；slot在W0接受结果交接或discard时释放，W1另拥有其完整tag/data/fflags，新增W1不增加FMA identity生命周期。wrapper旧“final writeback”注释属于W0/W1之前措辞，以本记录当前ownership为准。MUL4 arithmetic stages+完成FIFO→W0交接普通最多6个registered-lifetime owner，8信用能覆盖普通II1。融合pair预留2信用、两个结果经同一个MUL completion-head逐次交接，持续pair throughput受单source completion带宽限制，不能宣称每拍完成两个融合结果；本轮不改变该既有资源带宽。该检查仅RTL结构审阅，未运行连续吞吐仿真。共享PRF INT4R2W/FP5R1W也会限制特定混合，三宽是整体decode/rename/dispatch/retire及INT IQ选择宽度，不是三ALU/三INT写口。
C14仍在Timing Optimization；C16保持排队。无功能/opt/P&R/bitstream/板测，目标未完成。

2026-10-12 03:35：C16前置36静态+生产BIOS/RTL生成37项exit0，153实际输入2bdc443a49f799d3c00ec65f7a4e7fcb02ba35c1e13314bbd36c892a56a3acdb，external=[]；103文件生成阶段归档e5df658ee3aa29be61d605fbd0ae6014d3ecfdc0f353920e18a283c84af01b3c，非最终综合。fixed源码4072b2ef...不绑定后续docs/候选。当前free-count capacity process与request编码分开后，free-list fixture无UNOPTFLAT/LATCH/error；完整SoC lint旧alloc_req虚假feedback warning同样消除。读前candidate_slot warning已在032309 preview消除，没有禁用诊断。C14仍处Timing Optimization，C16等待，无功能/opt/P&R/bitstream/板测。
IFU payload首个独立OOC v1两RTL parse0但报告Tcl错用clk端口，实际完整接口是clk_i，runner1；19文件5bcd27f507c21a054b1e950ee76115518b9b7b04b1da2c04739d58631bc2210b全部保留。v2仅修正报告create_clock到clk_i后重跑，尚无收益结论，candidate不在生产/C16。旧FE 64连续/1200随机full-payload/kill/empty-beat/c-prime黄金检查与种子/规模未改。

2026-10-12 03:32固定C16：soc-threewide-components16-20261012-032952，852源码4072b2ef28c6adc9f3ee99697fc50dba834be9a91eebe857bbb1c65c5822c2af，base d834162 dirty；fresh cloud SSH255/Alan0，runner2518729、只读group watcher2519323。含C14全部+L2 bounded/PLRU v2+IQ I0/I1回收+operand candidate/RAM组合拆分+下面精确注册容量；三宽/FU/容量/100MHz不变。前置37项正在运行，必须等待C14和C15结束，只有一个自身完整综合。C15确认尚无synth.start/Vivado console，03:30:16只TERM排队run.sh子进程2506516，parent记录runner143、watcher skip；原37项成功及所有源码/生产输入保留。106文件最终取消/生成归档9168bc6bab7ee05aa0958b714b74601c39590ade2a534e6f514cfd41e20b583e，早期103生成归档另存generation-phase-review.tar.gz。C14正在运行的Vivado未中断。
当前free-list v4使用每64物理寄存器一份精确注册容量：分配/释放/误预测/全flush同沿先形成原free_next位图，以平衡population tree写count state，与bitmap同步。INT p0规则、FP p0、最高preg释放、重复/同拍恢复优先级和全局committed state完整保留，无当前释放旁路、额外admission周期或FSM。公开容量单独从count state形成，避免request编码与容量输出同一always_comb的虚假反馈；候选OOC后production加count=bitmap invariant assertion和准确注释。旧free-list700/120/32×全稀疏mask合同、种子和规模不改，仍未运行。
完整公开接口v4 OOC(两域分别两解析/runner0，相同全I/O零delay约束)：INT1819→1869LUT(+50)、378→384FF(+6)，FP1750→1995(+245)、384→391(+7)。容量输出INT3.582ns/9和FP3.292ns/9→两者.115ns/0级；完整内部最差INT4.297ns/10→6.213ns/15、FP4.320ns/10→6.653ns/16，统计更新侧更长。明确这是把跨模块admission的population移至本地状态更新的取舍，不能把输出改善冒认为整系统时序闭合，完整反馈需C16评估。29文件INT6b5c9c3bf5afd7f96e4d734864a2a833d7ce61ab7ec699f4d8a1599fbce3c2a1、FP0834873da3bff1e30c020495b9b3abfd27a06bb12557bffa6a31c88e47db9b3d，build/threewide-free-count-prepared[-fp]-v4/evidence。四项分组v3只保留实验，不合入。
无功能/opt/place/route/bitstream/板测；目标仍未实现。F0→F1二行immutable payload的单写RAM候选只在build独立OOC，未合入当前生产或C16，全部FE宽度/队列/空beat/c-prime边界规格保持。

2026-10-12 03:25后续IQ I0/I1接收确认/回收已合入当前工作区，尚不属于C14/C15固定输入。I0实际FU-buffer handshake只捕获accepted physical rows；I1使用该注册确认回收/压缩IQ索引。accepted_q立即从候选中排除，free_count和allocator使用同一份已注册的确认信用，允许下一沿重用，避免重复发射、延迟信用气泡或增加容量。所有当前输入→buffer输出的年龄/选择/partial acceptance/payload/mask/取消与公开free_count周期保持，OLDEST_ONLY按第一live逻辑项处理确认留下的临时物理洞。普通三宽dispatch/issue仍持续重叠，无新FSM。四IQ完整接口OOC baseline/prepared两解析/runner0：LUT34544→34097(−447)、FF1411→1439(+28)、RAM7680不变，内部7.214ns/18→6.364ns/16级；27文件b9b9088a64292bff20a5e15ee0aed83e5ec69b1381c01592767320d8a4e067bb，build/threewide-iq-reclaim-prepared/evidence。I/O未约束，不声明跨backend路由时序闭合。production另加已确认physical owner存在/不重复确认assert及准确注释。
原700/900/160 IQ全包/年龄/稀疏/ready域golden、种子、规模均逐字不变；新增196周期连续三宽mixed FU/物理行复用/full payload/free credit合同，191个稳态满宽周期，未运行。Python10万周期physical-owner/credit与独立逻辑FIFO身份检查PASS(seed405)，仅纯算法，非RTL功能证明；初稿误在mispredict强制accept，修正为原规则，不更改RTL。原issue path不增加接口延迟。
读前operand scheduler将candidate physical index选择与RAM返回payload组装拆成独立always_comb；原found_candidate条件按被选物理owner重算，默认无candidate时仍无valid。无寄存器/握手/行为改变，消除fixture candidate_slot工具可见的虚假组合自依赖，未豁免warning。最新032309完整静态preview32项exit0，852源码64ed351d28bb830e456042d062db7399091937f60a2ef47aee972bf6e3e316eb，含IQ I1与operand comb split；功能仍后置。
Free-list四项分组容量候选仅独立评估，尚未合入生产：INT1819→1847LUT/378→425FF，FP1750→1901/384→432；同0-delay完整I/O约束下容量输出INT3.582ns/9→3.172ns/8，FP3.292ns/9→2.945ns/8，内部分别4.297→4.401ns、4.320→4.353ns略变慢。v3各两解析/runner0，29文件INT392e672d519c6dd1049abe68a8f7999a619d819941becc11c0ede5ed4d655797、FPdba8b3f91bc3c60faa2a090ed3302e3a4d83535047ac0536ec923c32b02f3333。v2约束Tcl误用其他工具的remove_from_collection命令runner1，基线RTL parse0，非主机问题，19文件493c2893c9db17fae0c1ef37ed50fe0321466ba3bfa81d2a6f33c40535704315/a0043a8cf741ffac637e4fa8c76b31e6ae73aa987f1c0aa2e0d34fee600292ca全部保留；v3修正Vivado get_ports filter。早期未约束输出v1 27文件dc76dca0bafe63026521de8ee8384b7bc654435914974211dd9b31db9ac9a805/cc178bde7c5199b7dfacfa9f07470882db84c5b6bcdba52117c248130b80150c保留。完整注册容量另一候选v4正在评估，不能宣称系统收益。
C14完整综合仍运行；C15生成/排队，无新功能/opt/P&R/bitstream/板测，KCU105目标尚未达到。

2026-10-12 03:10：C11完整生产SoC synthesis/runner/只读分组均exit0，02:24:24→03:00:51 CST，2168秒。LUT245383/242400(101.23%)、Logic221188、RAM24195、FF99747、BRAM176、DSP27，资源仍超限；100MHz综合估算WNS−4.475ns/TNS−107222.727ns，60260/481496 setup失败端点，WHS−.252ns/THS−1010.009ns，40600 hold失败端点。最差42级INT IQ ready3→选择/握手→order；FP IQ −4.319ns/43级，ROB −3.330ns/40级free bitmap→entry_complete，HPM −2.472ns/40级probe→event OF，A1 −1.438ns/35级、A2 −1.611ns/32级branch-resolution→调度。DCache −.669ns/33级，FE −2.547ns/35级，L2+.739ns/28级；执行ALU+3.249ns、FMA+2.283ns，W1 INT+1.637ns/FP+4.033ns。固定源码85120d32...、153实际输入7d1eff52...，不绑定C14/C15。138文件最终归档7775caf584b989cd6d3168281588894bd8b64d1ba5e84cde65be740aab240bdf，build/soc-threewide-components11-20261012-015035。
C14已于03:00:56在Alan串行开始整系统综合，固定8a1a47d6.../5a66820f...；不取消活动任务。后续L2 bounded controls不在C14：初始化set/req、put、task轮询及每client响应FIFO heads/tails/count限定实际容量位宽；PLRU单写端口与目录S0同步读，无新阶段/FSM/容量/节拍改变，init阻塞普通请求直至全部行清零，内部read寄存有效性由现有S1/S2 guard保护。v1 block属性实际fallback LUTRAM，不能声称PLRU BRAM；v2生产明确distributed并加init与正常写互斥断言。完整L2home OOC v2两解析/runner0：LUT13614→9696(−3918)、RAM0→32、FF13442→13840(+398)、BRAM57不变，内部7.939ns/24→7.353ns/23级；v1为9610LUT/6.541ns，不能混用为生产v2收益。27文件602ea68934605908a924f44d665c771a4b9641f6b03d91fc368f80b9eb37297f，build/threewide-l2-bounds-prepared-v2/evidence；v1归档343a3b756fd95e6859f6c7e7fa7f4ed1fd01a14427661a84ac0be3c345cb1f22保留。追加384读请求独立tree-PLRU/实际安装way/全512-bit数据/复位与队列回绕合同，旧golden/seed/规模不改，未运行。
C15 soc-threewide-components15-20261012-030319固定852源码1c5bcfe5fd86d5e5539c3033690be0b19aa8eff94b12e4a93a9cf42acec014bf，153实际输入308b36b93537be452323e23c8826d994219a5200872d386265b1f573965238a6，external=[]；36静态+生产BIOS/RTL生成37项0，fresh cloud SSH255/Alan0。Alan runner2506515/group watcher2508264，必须等待C14，不并发两次自身完整综合。103文件生成阶段归档764900b1dea7ec643efd961ea8f84f7a53c9ce680b55bebac09732daf43a5f1d，非最终综合。C15含C14全部及L2 bounded/PLRU v2；三宽、FU、cache/IQ容量和100MHz不再削减。功能/opt/P&R/bitstream/板测均未运行，目标仍未完成。

2026-10-12 02:54固定C14：soc-threewide-components14-20261012-024957，852源码8a1a47d62828900f8ecda078edcba82264bfd95baa204ca3922731afee3253f2，153实际生产输入5a66820f64451412eb1c49a29258a9527f5479b605819c8e5646f3a21f83066d，external=[]。36静态+生产BIOS/RTL生成37项exit0，fresh cloud SSH255/Alan0；103文件生成阶段归档08583c0000b7a9d776b95d0efc51355f956d6b2cf8593ed878c8b3ee6030bab8，非最终综合。Alan runner2501044/group watcher2502166；包含C11全部+TAGE T3/MSHR有界rank/L2 S0同步BRAM读/IQ直接FU路由和prefix/ROB R3，三宽/FU/容量/100MHz不再裁减。main必须等待C11 runner结束。
C13确认尚无synth.start/Vivado后主动取消排队run.sh，runner143，原37项成功检查和全部生产输入保留。106文件取消/生成最终归档8cb8f6e58e386c0c00710fb9de47b320d9bfedd613a510d122e07773636e23df，旧103文件另存generation-phase-review.tar.gz。latest current preview024705共32项0，852源码abd63c6d1c4684a7e45a599c2cf2176053007109a4aaf3f48eb60b9b96055ecb。没有动态功能/opt/P&R/bitstream/板测，最终目标仍未实现。

2026-10-12 02:49：ROB R3 metadata publication已合入当前生产。R2立即分配owner/index/capacity并冻结每lane immutable meta/entry；下一沿R3写bank RAM并发布ready。head_valid与retire prefix必须同时满足meta/entry ready，避免重用行的旧payload或未发布serialize/exception信息提前可见。alloc/WB/late-exc/succ/fflags/needs-D/branchmask仍在原沿独立更新、原同拍优先级保留；R3不清late selectors。正常3分配/3发布每拍重叠，无FSM；空ROB新head控制多等一拍，数据执行吞吐不受新增级限制。kill/flush时R3允许写已不可达旧RAM行，只有原owner仍活着才发布ready；后续复用R2再次清ready，防串包，不把晚branch/flush回路接入宽RAM写端口。
独立完整接口OOC v2补齐head CSR/SFENCE outputs，两解析/runner0：LUT10896→10668(−228)、FF673→1960(+1287)、RAM1398不变，内部4.412ns/13→4.386ns/11级；该边界不包含rename/free-list输入路径，不能据此宣称整系统跨模块闭合。27文件27746b6c5bf9f29c53a0939e436ea823b7e9247d19c77148db4f6ff023c4adda，build/threewide-rob-publication-prepared-v2/evidence；production仅追加准确注释，硬件与OOC candidate一致。
旧600+600 retirement/generation/seed/规模及全payload期望保留；两个80批meta/late-priority合同仅按新增R3在alloc后多等一个沿再观测，160批CSR/SFENCE classification同样延后一沿且新增R2 head_valid必须0断言。新增260周期连续3分配+3退休、94个稳态满宽周期、early completion/publication、branch取消保留older/global flush、物理行复用ID/preg63检查。三个更新bench Python AST检查通过，仅语法而非RTL仿真；功能仍后置。完整32项current preview024705正在运行，C13 fixed source不含L2/IQ/R3，拟合并下一生产输入并取消尚未开始Vivado的C13重复排队。C11整系统继续运行，目标尚未完成。

2026-10-12 02:43：IQ直接FU路由与平衡survivor prefix已合入生产RTL/backend接线。INT per-class候选在窄调度选择时分配目标：第c个ALU候选映射到第c个可用ALU，MUL/DIV固定独立路；按全局年龄排序后同步输出目标索引。backend enqueue接受只检查该目标的注册buffer容量，不经完整payload RAM读取FU class；IQ删除仍由实际buffer handshake控制。partial acceptance、最老eligible、ALU/MUL/DIV各路容量、mask/kill、payload数据与周期不变，无新寄存器/FSM。四IQ compaction survivors使用平衡prefix，原稀疏dispatch/顺序/容量规则不变。
完整四IQ OOC v2带旧backend路由反馈：baseline API adapter从完整payload class产生目标，新版直接从候选产生，wrapper让INT ready通过目标容量与外部lane denial回送；两者相同公开包/通知宽度25/24和输入资源。LUT34580→34544(−36)、FF1411/RAM7680不变，内部10.547ns/28→7.214ns/18级；2解析+runner0，27文件175771ff8293ca7dda5842da5924f157e6ff5837f8ff60bf9a5aa17be41f35f2，build/threewide-iq-route-prepared/evidence。production移除candidate重复的同值issue_int_fu_o默认赋值，其余candidate逐字节相同；backend接线/测试顶层属于后续preview输入。旧700/900/160全包/ready oracle、种子/规模不变，追加900 mixed原同一场景下的独立expected FU target断言，未运行功能。
32项最新完整SoC/fixture静态preview024035全部0，852源码dabe6c92e954b44c5fe619b3152924e99d0437b6b4ca250d2136e2204f6f4cb5，包含L2同步BRAM读与IQ新路由；C13固定输入尚不含两者。ROB R3 publication仅为独立候选，还未合入：allocation立即占容量，后沿发布immutable metadata，head/retire必须等待ready；候选首次复制旧OOC wrapper漏接后来新增head_csr/head_sfence，baseline parse1，非主机故障；13文件失败归档eccec05a6b39b6ec895fc699a763070160893882e07c35decf0f172c27c3789b保留。wrapper已补齐公开outputs，v2正在独立解析/OOC，不声称收益或功能结论。原生产ROB当前仍R2同沿写metadata。

2026-10-12 02:36当前增量：L2 slow-slot payload同步读已合入工作区，不属于C13固定快照。S0只选择/授予slot并捕获set/slot/类；task RAM在同一沿同步读，结果与原目录RAM一起属于S1，S2副作用不变。probe RAM同步读合并已有probe hold建立沿，probe_valid首次出现时payload已就绪；held probe所有元信息同沿冻结。四份单writer payload/refill RAM由distributed→block，无新流水级/气泡/FSM；Put>task>req、容量/SET保护/ID/响应顺序/错误/dirty data规则保持。完整slots接口OOC baseline/prepared和实际L2home fixture共3解析0、runner0：LUT3795→1895、FF176→180、BRAM0→48；内部最差2.418ns→3.577ns，变慢但本地10ns内，不冒认整系统收益。32文件归档9c958411d9f4294ac1e3e8b00de1006abec964c7b24c7855d64ef239336d3d84，build/threewide-l2-sync-read-prepared/evidence；原2000D/500I、64 payload合同保留，新48批三client/DDR阻塞/slot复用/dirty probe全512-bit golden测试未运行。需要下一完整输入综合评估LUT与BRAM实际变化。
IQ控制v1仅保留候选证据，不合入生产：将调度记录全部重建输出并平衡survivor prefix，四IQ完整接口OOC LUT34555→34848(+293)、FF1411/RAM7680不变，内部7.132→7.041ns，收益不足；27文件f89489ef46cbe969fb7254abfb2e86cf8140bf096edbd2e495f2a8544a6a8195。另一个IQ直接FU路由+平衡prefix候选正在OOC，baseline adapter复制旧backend payload-class路由反馈，尚无结论。
C13前置36静态+生产BIOS/RTL生成37项exit0；153实际输入77240f80862466bdb7da8ab08f8f95de0d0e0c27f6ecacd581d5fdc9eb5f82ec，external=[]；生成阶段103文件59727152a077171bd9bb3989d41c6f1fea6aee0dbb269eeef1610f45d24c6735，非最终综合，watcher2490619。C12主动取消后104文件最终生成/取消归档ce42ae5f7fc3dc48062e927126636f00d2af73b10e3bdacb10dca6121b5b9784；早期101文件生成归档另存generation-phase-review.tar.gz。C11整系统仍运行，C13等待；功能后置，无opt/P&R/bitstream/板级证据。目标仍未完成。

2026-10-12 02:30：C10完整生产SoC综合/报告/runner/只读分组均exit0。LUT244632/242400(100.92%)、Logic221180、RAM23452、FF99352、BRAM176、DSP27；仍超资源。100MHz综合估算WNS−5.202ns/TNS−83027.711ns，68338/476157 setup失败端点；WHS−.252ns/THS−1077.067ns，42091 hold失败端点。最差45级INT IQ ready3→选择→payload FU class→buffer路由握手→IQ order；非执行器计算延迟。综合01:32:58→02:24:21 CST、3064秒。128文件最终归档51cd9b2bc55f5bd1218f493dd52c19401805ec14eb5f55aa7b01f7ad9434edd0，build/soc-threewide-components10-20261012-010753，固定源码37c590fc.../实际输入32f2a9bf...，不绑定C11之后代码。no-clock/internal-unconstrained/loops/latch-loops=0；外部I/O未约束，资源DRC未豁免；没有功能/opt/P&R/bitstream/板测。
C11已于02:24:24串行开始完整综合，保留运行。C12 soc-threewide-components12-20261012-020527为TAGE-only固定快照：849源码4572ef0ed6bcad4f6a45d80e5c54665b26cfba69c3c6f909e677ea7a6f4f2bcf，153实际输入6035b623700c7a4cf7f3845b52ad2476c0b1587fccce6c911b7c64954b5b246a，external=[]；35静态+生产生成36项0，101文件生成阶段83104aeb1200534c1f1e68b8531efb0a6a9e24208a6c299643c07a3e5f3fe28c。确认没有synth.start/Vivado进程后于02:27主动取消排队run.sh，runner143，保存取消原因和全部生成证据；TAGE与后续MSHR排序合并C13，避免额外一轮重复完整综合。
当前DCache MSHR将32位全局序号替换为N个活跃事务的有界相对rank；删除完成owner后压缩较新rank，分配追加末尾，同拍完成槽仍不借给新分配。所有活跃状态参与年龄，held SEND在backpressure/较老WB依赖释放时保持，原GET/INSTALL/data/error身份、容量和时序不变；无新FSM/延迟。避免原32位序号长期回绕破坏顺序。完整实际metadata接口OOC LUT860→735、FF328→176、RAM296不变，内部5.251ns→1.867ns；2解析和runner0，27文件b53dcdadbbf725bbe6fd878318f8fb086a6e5046b1fc67ea723badca93a79924，build/threewide-mshr-rank-prepared/evidence。独立2200周期/unbounded birth-order oracle+512bit数据+middle deletion/同拍alloc-done/WB/重排响应/held请求/reset合同新增，seed105，未运行。32项静态preview021457全0，852源码93838455...；其后追加rank范围/唯一性仿真断言，不在该preview/OOC输入中。
C13 soc-threewide-components13-20261012-022745固定852源码ebb2a8a09e964a7e52a595925d8715c038d56e6d23acec362bbc37e6a970b2b1，base d834162 dirty，包含C11全部+TAGE T3+MSHR有界rank及断言；Alan runner2490316，新鲜配置cloud SSH255/Alan0，37项静态/生成前置检查运行中，完整综合必须等待C11结束与C12取消标记，不并发第二个本任务整SoC综合。三宽/全部FU与存储容量不再削减；目标未完成。

2026-10-12 02:04 后续TAGE T3已合入当前工作区，尚不属于C11固定快照。T0训练副本读→T1四槽更新→T2四槽更新→T3已完成行原子写，两份SRAM与query collision bypass同时使用T3包。完整T2新值经T3优先旁路下一T1，T0仍只检查原T1未完成行冲突，因此独立行II=1和同地址原一拍hazard不增加；训练表可见多一拍，查询S0/S1/S2、stall/kill、fold/meta/provider语义不变。无FSM/功能裁剪。
完整接口独立OOC baseline/prepared解析、runner0；LUT9729→9602、FF5659→6110、BRAM14不变；内部最差7.714ns/20→8.272ns/18级，新的最差为训练BRAM读→T2 tag，属于略变慢而非时序收益结论。T3隔开35级SRAM写使能路径的整系统效果仍待固定输入综合。27文件归档adb6a14a8d7039841bfe3f659461e4560087ad95a67066a5bc949363611cfaa5，目录build/threewide-tage-write-stage-prepared/evidence。I/O未约束，不宣称F0时序。
31项整SoC/fixture静态解析全部0，目录build/threewide-components5-preview-20261012-020113，849源码fb0f3cc7d0620a11530a3a0ee68e1725f461195f0529cdaaca3a143b3a834c0c。tage_model.py功能/预测/row-update oracle逐字节与C11一致；仅测试bench增加一拍训练transport adapter，post-training directed query多等一拍，仍保留查询必须第二沿出现的断言。256 accepted legacy-reference全bit比较保留，只将pending write schedule2→3；同址stalls==255的原吞吐断言保留；新增256连续独立行满包+query collision/stall/kill，均未执行功能仿真。C12将仅包含上述TAGE增量并串行等待C11；当前没有新完整SoC资源/时序结论。

2026-10-12 01:56 C11固定快照已排队：soc-threewide-components11-20261012-015035，Alan runner2479723、只读分组watcher2480086。849源码manifest85120d32cb221c76ea06c90f8cb738c8edde70eaa490f1ace3aae52d3f2cdc9c，153实际生产输入manifest7d1eff52da98ad7cee853549790c98d032f9571ca735fcc51218d04cfb9a45fa，external=[]。34项静态+BIOS/RTL生成共35项exit0，cloud预检SSH255、Alan0；99文件生成阶段归档e582e0de277167766d89d2b7aadf3fbe915d5257221c536dbc4d3a6fa3e3fa20，非最终综合证据。AreaOptimized_high整系统必须等待C10 runner.exit，未开启第二个本任务整SoC综合。固定包含W0/W1、MEM R、DCache I0/I1和LR计数器窄化、INT/FP free-list平衡收集；仍三宽/ALU2/MUL1/DIV1/FMA1/FDIV1/FMISC1/FCONV1/MEM2/INT4R2W/FP5R1W。无功能/opt/P&R/bitstream/板测，目标尚未实现。
DCache v2显式O3_CFG.be重复完整接口OOC，解析/runner0，LUT18216→18364、FF8857→8659、内部9.792ns/30→8.086ns/25级，与v1有效配置结果完全相同；29文件归档f8e9930f1b88f79c73614e15289dad7fa7d5a77243668e88d707b36b1e8625c2，目录build/threewide-cache-permission-prepared-v2/evidence。后续TAGE训练原子写T3候选只在build/threewide-tage-write-stage-prepared，不属于C11或当前生产RTL，尚在独立OOC；拟用已完整T2结果在T3旁路下一T1，仅保留原T1同地址部分更新hazard，不新增训练接收气泡。尚无资源/时序或功能结论。

2026-10-12 01:50 C11准备：当前30项静态解析全部0，目录build/threewide-components5-preview-20261012-014645，849源码manifest243ceafb3ef3eab93ffb700bb12539fc1cf958b3698ea00ff64bbae5068d8dd5。当前包含W0/W1写回、LSU响应R、DCache内部I0捕获/I1权限分级、7-bit LR窗口计数与free-list共享平衡前三候选收集；三宽/FU/队列/cache/读写端口不再缩减，功能后置。35项预定C11完整前置检查含34解析+生产BIOS/RTL生成，Vivado必须等C10 runner结束再启动。
free-list将三路串行排除编码改为一次按地址收集前三候选，再根据稀疏请求prefix rank映射到原lane；free count、相同边沿释放不旁路、最高63号、checkpoint创建/回滚/全局恢复、INT p0保留与FP p0可分配规则不变，不增延迟/FSM。完整INT接口OOC v2显式CFG=O3_CFG.be：LUT1740→1819、FF378不变、内部6.811ns/16→4.297ns/10级；FP LUT1784→1750、FF384不变、6.464ns/15→4.320ns/10级。两组各2解析+runner0，各27文件归档0bfa9881a6fa20bdc1b918fbab2afbac3d497446827f9bbdcd44b333d8b62b39和d5454bb269dd8402def6224f4923e02c431820d71453ac6da7cad2a8ddb30596。旧INT v1 wrapper将完整O3_CFG隐式截为LSB be(有效配置相同、但产生WIDTHTRUNC)，保留7453e492abba980b3b6dcd56c23173e66ce4da53c39b8e5f12c251d8c07de30a；v2无此配置截断。旧700周期oracle/种子/规模不变，追加32遍全部稀疏请求模式/池耗尽/跨bank孔洞、INT1/FP0与preg63端点测试，DOMAIN=1/2均静态通过，功能未运行。
DCache在现有预约移位里划分I0原始内部包捕获、I1 PA/PMP/PMA资格寄存，后面预约移位和CPU S0位置不变；消除PTW物理检查与DCache权限计算同拍串联。STORE_DRAIN仍复用STA的PMP授权，PMA读写规则不变；PTW/AD/SQ内部事务所有权、等待原因、FIFO/握手不变，无新增状态机或延迟。LR窗口仍80，set/clear/conflict优先级不变，原85周期expiry和SC一次成功合同保留。完整DCache v1 OOC baseline/prepared均真实双CPU/内部PTW/AD/coherence接口：LUT18216→18364、FF8857→8659、RAM1008/BRAM32不变，内部9.792ns/30→8.086ns/25级；2解析+runner0，29文件fb74ef61ddd9d34e854035972373e2788d91860921ee8e54728b927154276e3d。其v1 wrapper配置也由O3_CFG LSB截取be，正在用显式be的v2重验；不把此独立OOC当整SoC时序结论。
临时HPM overflow代数候选已撤回生产，保留独立证据：LUT2883→2914、FF1218，内部3.466→3.562ns；给全部I/O设同一0-delay的v2，late event→overflow2.543→2.432ns/8级不变，counter→overflow3.132→3.259ns，收益不足以换额外面积。v1 27文件bdec05099da745380a7bd952212575733d151f432b6e8f29d2b59020ffa4d53b；v2 31文件298e2ad7a23c94437a24377b0e2871994a8e6145089d04561bb97993e6c67ad8。Python纯算术20万向量恒等式检查通过，只是代数检查，无RTL仿真；新增192 pending low-carry/OF边沿合同仍保留，未执行。生产继续原E0 pending/E1累加精确CSR/OF规则。

2026-10-12 01:45 当前：C9完整SoC综合、runner、只读分组均exit0；仍未达到KCU105三发射目标。LUT248289/242400(102.43%)、Logic226661、RAM21628(Distributed21576/SRL52)、FF108205、BRAM176、DSP27、latch0。100MHz综合估算WNS-6.080ns/TNS-79258.469ns、69679/489525 setup失败端点；WHS-.252ns/THS-1186.744ns、45248 hold失败端点。最差49级DCache LR窗口计数→cache S2事务分配→LSU成功通知→MEM IQ ready；uBTB训练不再是最差路径。A2 -2.076ns/37级、ROB -3.427ns/38级、FE -2.547ns/35级、DCache -3.873ns/47级、HPM -2.732ns/41级；ALU+3.468ns、FMA+2.283ns、L2+.872ns、恢复+1.995ns。no-clock/internal-unconstrained/loops/latch-loops均0；71输入/113输出没有外部delay，禁止冒认全板时序。源/输入manifest仍为2e6e2a73.../16234b1e...，未绑定后续代码；综合00:43:21→01:32:58 CST，2977秒。128文件最终归档ba536a3329c2a7bf0318dceecf357b23eea95351cf15fe157ef13a917f688958，目录build/soc-threewide-components9-20261012-004216。
C10已在01:32:58串行接续AreaOptimized_high整SoC综合；目录soc-threewide-components10-20261012-010753，runner2461106/groups watcher2461560。845源码manifest37c590fc65248c96bdc1141c4be30c0e5b6cdc5a53baa13f50b01ab40ddcb1c6；152实际生产输入manifest32f2a9bfafcc9ef1b9465dcaead0a1e327713ace2f494b0456c72fd3974f7d5f，external=[]。31静态解析+BIOS/RTL生成共32项0。cloud SSH255、Alan0；97文件生成阶段归档9745018e93784abd683d0407d613773885dafc3a4068c2d023beb7a2998177d4，非最终综合。固定C10含DTLB base PPN RAM/DCache MSHR-WB metadata API/L2 selected task API；不含下述W0/W1和LSU R级。基线HEAD d834162f7ff1a3e86b43abf270d57df86088ab88，各轮dirty文件用manifest独立绑定；无opt/place/route/bitstream/板测。

当前后续流水边界：整数/FP写回拆为W0仲裁转交→三包有界W1传输→实际PRF写、true ready与ROB完成，普通每拍转交一包(INT2W/FP1W)。信用只看寄存占用，CSR占用INT口0时仅保留对应source，其他write和不写寄存器的completion可先完成；有效head提供每写口一份旁路。全包mask/valid随正确解析清除、误预测取消和flush更新；HEU转交后抑制同ROB head重复启动直到W1实际完成；无FSM。新增完整身份/data/fflags交接fixture，96连续满口、12次CSR保留口和1500周期随机部分完成/取消/复位，INT/FP两种，功能未运行。当前PORTS旁路v2 OOC INT LUT1524/RAM560/FF183、内部2.657ns/6级；FP LUT125/RAM52/FF21、1.741ns/3级。独立新模块成本，无假baseline；I/O未约束，不能声明系统时序收益。2解析+runner全0，25文件归档b6bbda0e2d74283c5a29f5f501d16ad90be27e57036f582485a6c5e7978134ec。旧SOURCES旁路v1保留25文件fc615ae4caee6e880cecc8d28025ed9cad4c6a51554428fd328869116b97fe40。
MEM在cache S2返回和LSU update/wakeup之间新增R响应寄存，owner/kind/PA/LQ tag/AD-order metadata一起推进，信用增加R在途，cache S0位置/三拍预约不变；双路仍每拍推进，成功通知仍比结果FIFO可见早一拍。所有stage解析/flush防止ROB/queue复用串包；HEU返回同样通过R。LSU完整接口OOC baseline/prepared各含C10 DTLB和FIFO8：LUT10709→10976、FF7744→8339、RAM552→770；内部4.949ns/14级不变，跨cache输入→IQ路径不在该OOC边界内。2解析+runner0、28文件aca29c030dcf1c3566dc737ca35ba8ee96fcad97a84c3bd90cb010806e8defa1。旧seed/规模/外部cache黄金代理保留，旧立即STA观察按新增一拍等待其真实完成；追加192组R边界取消/正确解析/flush/双路身份数据及通知精确早一拍检查，未执行。
01:37:49预览28项完整SoC/fixture解析0；849源码eb999e72726851a9c0afc315fd3bccdcfde64d2f8cc2df1ef2346c930630967e，包含临时HPM overflow候选，后者正在单独评估，尚不能用于当前最终代码的证明。LR窗口计数器由32-bit int改为clog2(80+1)=7 bit，窗口80、set/clear优先级和SC配对不变。后续准备在DCache现有预约传输I0选择/I1权限之间做逻辑分级，避免PTW自身物理检查串上第二轮PMP；不再缩宽/FU/queue/cache容量。功能仍后置。

2026-10-12 01:08当前后续合入：DCache MSHR逐槽接口改为dc_line_meta_t，只有动态INSTALL读512-bit响应RAM；WB逐槽/READ接口改为dc_wb_meta_t，只有held Put读512-bit READ-completion RAM。生产无消费者需要逐槽refill/data，原alloc初始宽data在任何合法有效INSTALL/Put前均被实际response/read覆盖；窄状态、REQ/Put保持、ID复用、事务顺序和所有握手/延迟不变。第二版OOC baseline适配到同一实际metadata接口，全部端口仍暴露并未tie-off：MSHR LUT2396→860、FF2376→328、RAM0→296；WB LUT837→368、FF1092→69、RAM0→296。内部路径MSHR4.900→5.251ns/16级、WB1.546→1.291ns/3→2级，输入/输出未约束。5解析/runner项0，43文件归档 `22058de75eff1ef2d694578dfe9700f944aa1ebaf8af1fb7ddf5af8eccb24f10`。此新API对比与原接口OOC scope不同，不能混用其baseline数字。
L2 slots同步采用task_select_i+单个完整task_o：调度先看逐槽valid/protected_set，再动态读被选中的完整工作包；task/probe各自单写alloc RAM和refill RAM，窄mutable metadata/valid保证复位和重分配边沿。L2home选择逻辑与payload返回拆成独立组合块，不引入串行FSM或增加延迟。原接口baseline用动态选槽wrapper适配相同API；LUT4677→3795、FF4654→176、RAM0→1920，内部2.376→2.418ns/6级，解析/runner全0；29文件归档 `edb1d349e30380b63fc84c6bef2aa94d5660cc0fa9a9198e69351e8ccebee177`。当前26项整SoC/fixture解析0，目录`build/threewide-components5-preview-20261012-010316`，845源码manifest `cdd5157042d77286d19ef14e0780cfc6e075c7a7476398d46b1c51534632e4c5`。保留所有旧golden/seed/scale，追加DCache48批全512-bit install/dirty Put复用与L264批三client全512-bit交错。功能尚未执行；所有这些后续改动均不属于C9固定综合输入。

2026-10-12 00:58后续组件候选：DTLB base PPN两查询副本RAM+独热命中选择已合入当前工作区，查询延迟/双路II不变。完整接口OOC baseline/prepared解析/综合均0：LUT3545→2917、FF3934→2520、RAM0→224，内部路径4.742ns/14级→5.068ns/13级（略变慢，I/O未约束）；27文件归档 `21854854217e9877b34d1b96ffe91e79ae4186e7d4c3d36694ec09aa223b577c`。旧MMU page-table oracle/seed/测试未改，追加512连续双路全32resident槽、64定向SFENCE重填、复位后256双路查询，均未运行。26项最新完整SoC/fixture静态解析exit0，目录`build/threewide-components5-preview-20261012-005501`，845源码manifest `9a4723bdd4ed9f8c451d975ed9eef0affa9a23ef22ce3989c642d832eb3412d9`。此增量不属于C9固定输入。
cache槽首版原接口候选全部解析/综合0，但固定全槽宽payload输出使RAM推导0、MSHR2396→3424 LUT、WB1337→2119、L2 slots3522→5828，全部拒绝合入；58文件归档 `63921b2c213cfcb7d469e368e20d0b9828a7dafe248d71dd8893423e8a288269`。v1独立候选WB语法错误(end/int间换行漏掉)保留25文件失败归档 `90bbfa76355469b39e5bded6f86f2440b2485f7aa91e9c74f182044016338d35`。正在评估改为实际逐槽metadata+动态INSTALL/Put payload端口的第二接口候选，尚未合入生产。

2026-10-12 00:49 C9实际启动：`soc-threewide-components9-20261012-004216`，845源码manifest `2e6e2a73eac0596f0421f1b1a3d8834e5525f4fe1b8477915dcda2375bd6bf84`；实际152个生产输入manifest `16234b1e59e1d3e09225d1ff4794bd233a006bfe748ff3ea04552ef93889ffbc`，external=[]。30项静态解析+生产BIOS/RTL生成共31项exit0，cloud预检SSH255、Alan0，runner2450155；AreaOptimized_high完整综合正在运行，分组只读watcher2452115。生成阶段95文件归档 `86462dfd300ed65da81f55da3d5f28fa19e99b31e0183d179126505902d3c232`，不是最终综合归档。本轮固定输入包含SQ RAM、LSU T/FIFO8、DCache三拍预约、恢复C3、uBTB两级训练/RAM；当前无完整资源/时序结果。后续cache事务槽RAM只在独立candidate/OOC，尚未合入生产或C9。功能/opt/place/route/bitstream/板测均未运行。

2026-10-12 00:41 uBTB完整接口OOC v2：baseline/prepared解析与Vivado全部0，LUT3664→2315、FF3365→1605、RAM0→80，内部路径6.915ns/20级→5.155ns/12级；query输入/输出未约束，不能据此宣称F0时序。28文件归档1387c1604d30d39dbd6c2bd8e6d0993f796d82c18b70f6d0b215b1860fe7f1ac，build/threewide-ubtb-training-prepared/evidence。失败v1时钟名clk错误归档19文件79a061da93cdb700d3ca9010341d7fa722303e0f3414b694b175eb69efccdc65；C7最终生成/取消88文件567cef1c0cda6340bc98bf3fff5351269f948c71857054628509a3f38040a729，均保留。

2026-10-12 00:30：C7/C8在生产生成完成后、Vivado未开始前主动取消（runner143）；LSU新增T级将RR→cache S0从2拍改成3拍，因此DCache内部/line reservation也必须增加一拍，旧快照仅保留静态/生成证据。当前CFG.lsu.cache_s0_delay=3，LSU elaboration断言一致；DCache line/internal packets、probe保护/安装ID/bank/PS下一拍冲突均跟随预留末级，不增加FSM。普通CPU lane仍每拍预约，内部事务仅增加固定延迟。原DCache数据/golden/seed/规模保留，预约驱动按实际配置推进，新增800周期CPU双路+PTW/probe交错身份/成功数据/实际容量检查。当前正在解析3拍与旧2拍DCache fixture；功能后置。C9将包含全部SQ、LSU、恢复边界与预留校正。

2026-10-12 00:25 最新恢复增量：所有提交重定向包均通过recovery_boundary寄存发送，不再让C2 trap target旁路读取提交组合包。C0接受→C1取消/CSR更新→C2目标捕获→C3完整目标送前端；trap transport busy与recovery pending连续持有精确边界，不新增FSM，不影响普通发射/退休吞吐。旧500周期seed/完整包随机检查保留并按授权新延迟更新，新增160组实际trap_ctrl+dispatcher身份/目标冻结/连续busy/复位检查。功能未运行，待当前静态解析与后续完整综合；C7固定输入不含此增量。

# 后端重构与独立综合（2026-10-11）

当前默认为整体三宽（ALU2/MUL1/DIV1/FMA1/MEM2、INT4R2W/FP5R1W），目标仍是KCU105不少于三发射。最新完整C6v2 AreaOptimized_high：LUT249109（102.77%）、FF112389，100MHz综合估算WNS -8.769ns/58级，资源与时序未闭合。
C7/C8在静态解析和生产生成成功后、Vivado开始之前主动取消（runner143）：LSU新增翻译级必须同步把DCache预约窗口2→3拍。后续C9增量包含SQ payload RAM、LSU T级/FIFO8、DCache三拍预约、统一注册重定向，以及uBTB选行/更新流水和目标RAM。当前25项静态解析exit0，uBTB独立OOC正在重跑；尚无这些增量的完整综合结果。
当前验证范围仅静态/组件OOC/完整SoC综合估算；功能未运行，没有opt/place/route/bitstream/板测。以下最初四宽描述和命令均是历史证据，最新增量见文末。

首版用户授权：按讨论落 RTL，只综合后端、分析时序与不合理的实现，功能问题等后端重构完成后统一修。用户随后授权整系统综合及资源削减，见末尾后续阶段。本报告的动态功能验证仍为“未运行”。

## 实现边界

- Decode4 → Rename R1 依赖预处理 → R1/R2 固定槽 buffer → R2 原子分配 → Dispatch4。
- INT IQ 选择宽度4独立配置，ALU4/MUL1/DIV1，六个独立读前 buffer；再共享 INT 6R 读口仲裁，进入各自 RegRead。MUL 保留四拍算术流水与8项完成信用，DIV 保留迭代实现。
- FP IQ 选择2；FMA2/DIVSQRT1/MISC1/CONV1，各自读前 buffer 和弹性 RegRead。FMA 使用当前 Breeze SP5/DP7 CVFPU，其他组配置保留；FP PRF 8R/2W，转换源与普通请求竞争 INT 读口。
- MEM IQ 选择2、两个读前 buffer/RegRead；保留 LSU/LQ/SQ/cache/replay/HEU 的原有路径。Replay 使用已存 VA，不重新仲裁 PRF。BR 保留原有读口到 RegRead 路径，增加真实数据可读检查。
- ALU/MUL（含融合第二目的）/DIV/FP/成功普通 load 均在下一拍捕获完成结果前发调度通知，FIFO尾部也可通知。IQ readiness 与真实数据可读分开：buffer 必须等 PRF ready、当拍真实写回或 live completion-head bypass，才能取得读口。通知不更新 PRF ready/ROB complete；store 不发目的通知。
- 退休总宽度4，实际完成仍随真实写回/原有无目的完成路径进入 ROB；不改变异常/精确退休规则。

## 证据身份与复现

当前工作区未提交，不能将基底 HEAD 当作重构提交。综合输入绑定逐文件 SHA256 清单：

| 项 | 值 |
|---|---|
| 分支/基底 HEAD | `feat/l11a-litex-soc` / `d834162f7ff1a3e86b43abf270d57df86088ab88` |
| CVFPU | `23153ba10a0ab8c6ee774b5e1a928007c3b2adcc` |
| common_cells | `6aeee85d0a34fedc06c14f04fd6363c9f7b4eeea` |
| source-manifest.json SHA256 | `85ae939de87136509932d5a5f708664ae37c73de0f39c437c1a98a403d8131b7` |
| 实际主机 | Alan / `chen-System-Product-Name` |
| 工具 | `/home/chen/Tool/FPGA/Vivado/2022.2/bin/vivado`，v2022.2，SW Build 3671981 |
| 远端目录 | `/home/chen/FUN/CISLC-O3-runs/backend-refactor-20261011-151827/` |
| 综合 cwd | 上述目录的 `src/` |
| 原始证据 | 上述目录的 `evidence/`；`source.sha256` 全部远端校验通过 |

源代码以普通 tar 源码快照传输，没有 Git bundle。每次连接重新读取共享主机配置，Vivado 使用 Alan。运行命令：

```
/home/chen/Tool/FPGA/Vivado/2022.2/bin/vivado -mode batch \
  -source scripts/vivado/backend_ooc.tcl \
  -tclargs /home/chen/FUN/CISLC-O3-runs/backend-refactor-20261011-151827/evidence
```

入口 `scripts/vivado/backend_ooc_wrapper.sv` 保留 backend 的全部外部端口，实例真实 backend，未通过 tie-off 裁剪执行路径。`backend_ooc.tcl` 按权威 `rtl/rtl.f` 筛选 common/backend/lsu/mmu/system 与第三方依赖，排除 frontend/core/L2/platform 源。

综合包括 backend 实际连接的译码、Rename/Dispatch/IQ/PRF/ROB/全部FU/LSU/L1D/DTLB/PTW/HEU/CSR/提交控制。KU040 `xcku040-ffva1156-2-e`、10ns 时钟、输入输出延迟0ns，OOC、不 retiming；保留独立 reg-to-reg 路径报告以区分外部组合边界。**没有 place/route，综合时序只作结构诊断，不代表 100MHz 布线收敛。**

## 当前结果

主综合与报告任务退出码 **0**，`BACKEND_OOC_REPORTS_COMPLETE`；开始于
2026-10-11 15:18:49 +08:00，结束于 16:06:33。`synth_design` 用时约42分56秒，
综合/主要报告计时2840秒。综合阶段汇总706 Infos、663 Warnings、0 Critical Warnings、0 Errors。
这只说明工具完成综合；资源和时序都不满足当前目标。

| 综合结果 | 数值 |
|---|---:|
| CLB LUT | 380,730 / 242,400，157.07% |
| LUT as Logic / Memory | 378,187 / 2,543 |
| FF / latch | 118,062 / 0 |
| RAMB36E2 / RAMB18E2 | 64 / 0 |
| DSP | 38 |
| Setup WNS / TNS | -159.300 ns / -2,786,167.000 ns |
| Setup failing / total endpoints | 204,321 / 326,977 |
| Hold WHS / THS | -0.143 ns / -2,798.635 ns |

`check_timing` 的 no_clock、unconstrained_internal_endpoints、loops、latch_loops 均为0。
`report_drc` 共193项：**3个 UTLZ-1 Error**，分别为 logic LUT、LUT6、总 LUT 超量；
其余为配置电压缺省及 DSP 输入/输出/异步控制流水建议。
没有关闭资源错误检查。当前综合资源估算超过 KU040 预算，后续 opt/implementation
可能改变数量，但本轮没有取得可实现或时序收敛证据。

本地原始证据：[build/backend-ooc-20261011-151827/](../../build/backend-ooc-20261011-151827/)，
包括 `run-meta.txt`、`exit-code`、`console.log`、`source-manifest.json`、资源/时序/DRC报告；
346MB的 `backend_synth.dcp` 保留在远端 evidence 目录，未删除。
111个综合输入文件与当前本地文件再次逐一校验，`local_drift=[]`。
文档、未运行测试及下面的只读诊断脚本不属于那份RTL综合输入快照。

### 最差路径与真正的寄存器边界

最差路径是内部寄存器路径，不是0ns输入输出约束造成的外部组合路径：

```
DCache line_result_q[addr][0]
  → LQ 的同拍 order-hit / rob_order_flush
  → 退休/系统控制、真实结果可用检查
  → 共享 INT PRF 读口仲裁的连续 choice
  → 读前 buffer 的同拍腾位/替换容量
  → INT IQ 选择、删除和 order_next
  → INT IQ order_q[0][3]
```

报告：512级逻辑，数据延迟169.324ns，其中 cell delay38.799ns、
**未放置的 net delay估算130.524ns**。不能把后者当成真实布线延迟，不能据此宣称最终Fmax。
OOC 也未设置 `HD.CLK_SRC`，没有实际时钟布线/偏斜证明。

第一条路径中的可识别网名和累计估算到达时间：

| 路径检查点 | 到达时间 |
|---|---:|
| `lq_rob_order_flush[59]` | 5.206ns |
| `trap_update_valid` | 8.642ns |
| `load_result[1][valid]` | 9.659ns |
| 仲裁 `choice[1].chosen_age` 网 | 34.324ns |
| 仲裁 `choice[5].chosen_age` 网 | 86.359ns |
| 仲裁 `choice[9].chosen_kind` 网 | 147.596ns |
| `int_read_grant[0]` | 151.010ns |
| `order_next[0][3]` | 169.323ns |

这些是同一真实路径的网名证据。Vivado rebuilt hierarchy把大量共享逻辑归入
`u_rob`，网名中仍能辨认 `u_prf_read_arbiter/(null)[1..9].chosen_age/chosen_kind`。
不能把中间的ROB层级名称理解为这条路径经过ROB算术执行，或者把全部逻辑面积归罪于ROB。

源码对应关系：`prf_read_arbiter.sv` 在组合 `choice` 循环里执行10轮候选扫描，
下一轮依赖上一轮 considered/read_used；候选为6条INT、2条MEM、BR、1条INT源FP。
`fu_issue_buffer.sv` 的 `enq_ready_o` 包含本拍 `deq_ready_i`（读口授权），因此
虽然 uop 数据已经注册，容量反压仍把读口授权传回 IQ。`backend_issue_queue.sv`
随后做多口选择、remove_mask、survivors/rank 和 order_next。
所以新增 buffer **确实分开了数据流水，却尚未隔离整条容量/控制组合链**。

### 分组时序与面积

保存DCP后又运行只读的 `scripts/vivado/backend_timing_groups.tcl`，不重综合。
脚本SHA256为 `04cb0b6507bfe5573892b5ef26eb5d70aff09d673340afa37cd74897f5dcb18a`，
命令记录在 `groups-meta.txt`，退出码0、`BACKEND_TIMING_GROUPS_COMPLETE`。
来源为全部寄存器，终点按模块分组；**不是FU内部算术路径的独立测量**。

| 终点组 | 最差slack | 逻辑级数 |
|---|---:|---:|
| INT IQ / INT buffer | -159.300 / -158.927ns | 512 / 511 |
| FP IQ / MEM IQ / BR IQ | -151.433 / -145.799 / -140.315ns | 490 / 473 / 455 |
| ALU RegRead / MUL RegRead / DIV RegRead | -144.650 / -144.306 / -144.306ns | 471 / 470 / 470 |
| Rename R1 / Rename-Dispatch Queue | -7.469 / -10.611ns | 53 / 61 |
| ROB / DCache | -10.061 / -9.960ns | 60 / 65 |
| FMA / FP DIVSQRT / DIV | -3.391 / -3.742 / -2.949ns | 42 / 45 / 40 |

所有这些最差分组路径也从 DCache 行结果地址寄存器发出。
MUL组的最差路径终点在DSP输入，包含读口仲裁产生的操作数选择；
FMA组的最差路径到tag槽CE，不能据此断言FMA算术已经满足10ns。
共有31个非空终点组报告，`groups.txt` 保留全部明细。
报告阶段的deprecated `-nets`、大规模pin集合 Critical Warning 属于报告命令，
不等同于综合阶段的设计Critical Warning；没有因此丢弃任何报告。

层级面积的主要条目（包含子模块，rebuilt归属可能跨源码模块移动）：

| 层级 | LUT | FF |
|---|---:|---:|
| ROB | 43,035 | 10,415 |
| LSU | 31,058 | 7,338 |
| INT PRF | 30,668 | 18,496 |
| Rename R1/R2 buffer | 25,920 | 1,573 |
| DCache | 25,617 | 12,544 |
| Rename/Dispatch Queue | 23,562 | 4,959 |
| FP PRF | 18,056 | 8,256 |
| INT IQ | 16,571 | 3,942 |

不能因为仲裁器独立层级只显示29LUT，就认定仲裁几乎免费；其共享逻辑显著被重建到其他层级。
INT PRF实际为每写口一份bank的异步读/LVT结构，96×64×3=18,432个数据bit；
FP为64×64×2=8,192个数据bit，均映射为大量FF和读mux，并非本轮得到的BRAM PRF。
DSP分配为MUL16、两个FMA各11；增加到四ALU不解释如此巨大的全局仲裁链。

### 优化顺序与代价（候选，尚未改RTL）

1. **先改共享读口仲裁结构。** 候选年龄并行比较/排序窄索引，容量分配采用有界读口计数，
   避免10轮中每轮再顺序扫描全部候选。保留整条指令全部源原子授权、年龄tie规则、
   老指令读口不够时允许后面的较小请求继续竞争；不能简单用累计源数前缀替代现有语义。
   零源请求不占读口，也不能因已有6个读口被占就无条件停止遍历。
2. **隔离向IQ传播的ready。** 评估双槽buffer/skid或注册credit容量，
   IQ只看已注册余量，避免本拍读口授权直接决定本拍IQ选择/删除。
   单槽直接去掉同拍替换会导致满槽时隔拍接纳；双槽需要额外存储及kill/resolve/flush规则。
   这可以不增加空闲情况下的数据通路拍数，但需要认真设计满/空边界。
3. **仍有长路径时才增加仲裁流水边界。** 将候选/授权预约注册，再独立读数；
   增加的是等待到执行的延迟，稳定吞吐仍可能每拍接纳。
   必须配套预约保持、FU容量、重定向取消、真实源可用重查及唤醒时间，不能只在grant线上加DFF。
4. **处理剩余全局控制和面积。** order-hit在退休当拍必须阻止受影响load提交，
   不能随意延后。可研究把影响范围变为更局部的提交许可/恢复事件；
   Rename/队列mux、wake/bypass广播、PRF多读mux及计数位宽分别测量。
   改PRF存储到同步RAM将改变读取时序，不能当作不影响合同的属性替换。
5. **再检查算术与吞吐。** DSP流水提示、DP FMA tag槽容量和MEM在途信用需独立验证，
   它们不是已确认的512级主体。单纯增加ALU/FMA执行级不会切断现有关键路径。

## 2026-10-11 调研：成熟处理器是否拆分发射/读数

用户追问本轮问题是否源于设计缺陷、商业处理器是否增加流水。结论：
目前有实际物理实现缺陷，集中在组合仲裁和反压边界；
“共享IQ → 每FU buffer → 读口仲裁 → RegRead → FU”的总体组织并未被这些报告否定。
公开设计同时使用分级、固定/局部端口和冲突重发，不能把商业处理器概括为单纯加拍。

| 一手来源 | 可确认的实现 | 对当前设计的意义 |
|---|---|---|
| Intel作者论文，[Pentium 4 microarchitecture，Figure3](https://www.intel.com/content/dam/www/public/us/en/documents/research/2001-vol05-iss-1-intel-technology-journal.pdf#page=19) | 展示的基本错误分支恢复流水含3个Sch、2个Disp、2个RF阶段 | 商业处理器确实会把调度/传输/取数分级；这是历史实例，不能推定所有新Intel核相同 |
| Arm作者演讲，[Cortex-A76，slide13](https://cdn.hubilo.com/brochure/10860/2803_9570_983821001545027705.pdf#page=13)；[官方优化指南§2.1](https://documentation-service.arm.com/static/61c1f57d2183326f217720de) | 分布的IQ/执行通路，八类执行管道 | 说明限制连接与竞争范围；这些资料没有披露读口仲裁内部准确拍数，不能猜 |
| [BOOM官方寄存器堆文档](https://docs.boom-core.org/en/latest/sections/reg-file-bypass-network.html) | 发射口静态配足对应PRF读口 | 用资源换简单读口路径；BOOM是公开研究核，不能作为商业芯片证明 |
| [香山DataPath官方文档](https://docs.xiangshan.cc/projects/design/zh-cn/kunminghu-v3/backend/DataPath/DataPath/)及[IssueQueueEntries](https://docs.xiangshan.cc/projects/design/en/latest/backend/Schedule_And_Issue/IssueQueueEntries/) | OG0仲裁/发读请求，OG1返回数据；按预定端口做局部优先仲裁；失败回应IQ并取消相关推测唤醒，之后重发 | 读数分级与失败恢复一起设计；与我们“失败留在buffer等待”的政策不同，不能只照搬拍数 |

增加流水必须区分独立指令吞吐和依赖链延迟。增加执行前一级，可能维持每拍一条的稳态吞吐，
但若消费者仍需等生产者结果就绪后才进入新增级，连续依赖ALU之间的间隔会增加。
成熟设计用提前唤醒/预约旁路来隐藏部分等待，同时承担被取消或延迟时的重放/撤销代价。
我们目前采用保守真实数据重查，不能承诺增加调度流水不会影响依赖链IPC。
当前建议仍是先优化仲裁和ready隔离，再按同样KU040/10ns范围复测；不根据本次综合估算
直接决定要增加多少拍，也不因流水可改善时序就忽略157%的LUT问题。

## 功能验证与候选检查

- 新增 `sim/cocotb/fu_issue_pipeline/`：真实读前 buffer 与 MUL/DIV、FP、MEM RegRead，覆盖读口/真实数据拒绝、背压、同时替换、身份/数据、MEM逐拍前进、resolve/kill、flush/reset、400拍固定种子随机。代码已写，未编译运行。
- `sim/cocotb/fpu_fu/test_fpu_fu.py` 新增流水/混合精度/背压/多在途取消与随机运算两例；未运行。
- `sim/cocotb/mdu/` 按用户批准的B33更新尾部通知期望，新增完成头背压时MUL/DIV尾部通知与MUL融合双目的用例；原算术/取消断言保留。未编译运行。
- 本轮未运行 `scripts/lint.sh`、cocotb、整核程序、Spike、ACT4、布局布线或 FPGA。因此不能引用旧 SHA 的 PASS 作为新结构功能证明。
- 当前 INT 6R最多同时读取三条双源指令，四 ALU 不能等同于持续四条双源执行；还有 MUL/DIV/MEM/BR/转换竞争。
- PRF逐次oldest选择已经由最差路径确认处在主体组合链中；wake/bypass和退休控制也进入路径，后续需逐项切分测量改善量。
- LSU 每 lane 的结果 FIFO深度2，同时被用作全部 RegRead/replay/AG/S1/S2 在途预留上限；即使有双管道也会限制连续接纳，不能据“两路”声称每拍持续两条。该资源政策本轮保留，后续需单独评估。


## 2026-10-11 后续候选与整系统阶段

上面的 380730 LUT/-159.300ns 只属于首版后端快照。后续候选新增
`operand_read_pipeline.sv` 的 A0/A1 两个真实寄存级，并把 `fu_issue_buffer.sv`
改为占用寄存状态决定入队容量的双槽 FIFO；共享 INT 读仲裁使用并行有界 ROB 年龄排名、
树形计数与窄端口预算分配。BR 也经过 buffer/A0/A1。A0 等待真实数据与读级空间，
A1 地址/映射包在背压时保持，已消费源独立清空，全部 live 源排空后才装入下一包。
这一保守包保持策略可能在某个源单独背压时阻塞其他候选的新仲裁，后续功能/吞吐测试需覆盖。

用户最新宽度路线：整体四宽 → 先减容量/FU数量 → 仍不足才三宽 → 仍不足重做组件。
当前候选保留四 ALU/一 MUL/一 DIV/两 FMA/双 MEM，尚未削减默认容量。
完整标准 SoC 由 `fpga/kcu105/target.py` 生成，生产 BIOS/DDR/SD DMA 保留；
`scripts/vivado/soc_synth_only.py` 复用生成 Tcl 的源/XDC/综合命令并截断后续实现步骤，
加 `FPGA_TARGET` RAM实现选择。100MHz不降频，不做布局布线或功能仿真。

BOOM 当前官方 v4 MegaBOOM 配置为 `fetchWidth=8`、`decodeWidth=4`、ALU IQ `issueWidth=4`；
fetchBytes为16B。取指槽位数不等于整体八发射，也不能作为 KU040 容量实测依据。
来源：https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/common/config-mixins.scala

补充澄清：用户记忆中的“八发射”确有官方配置依据，不能只解释为取指八槽位。
官方 v3 MegaBOOM 是 Decode/Dispatch4、INT IQ4/MEM IQ2/FP IQ2，队列发射宽度合计8。
官方 v4 MegaBOOM 分为 MEM3/UNQ1/ALU4/FP2，不能把所有版本的BOOM称为同一个八宽配置。
两者都说明整体Decode/Dispatch宽度与各类队列/FU并行吞吐应分开。
这不是相同KU040、相同完整SoC、100MHz时序和资源实测证据。
来源：https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v3/common/config-mixins.scala


### 完整SoC首次流水候选：接口核对后主动停止，无最终结果

- 运行主机 Alan；cloud_chen SSH 8秒连接超时。Alan `cislc-o3` 用于RTL解析，
  `flow`环境用于完整LiteX/BIOS生成，Vivado2022.2用于综合；不修改安装环境。
- 输入基底HEAD `d834162f7ff1a3e86b43abf270d57df86088ab88`；813文件未提交快照，
  source-manifest SHA256 `dc8b60bdff4e5ceab64db5c731a60f3bdef409f522831f0fef4d34ac179080db`。
- 远端根 `/home/chen/FUN/CISLC-O3-runs/soc-fourwide-20261011-164159`；源码 `src/`，
  生成 `build/standard/`，证据 `evidence/`。本地镜像 `build/soc-fourwide-20261011-164159/`。
- `verilator --lint-only -Wno-fatal -f rtl/rtl.f --top-module o3_litex_top` exit0；
  新 `operand_read_pipeline_tb_top` 独立解析 exit0；警告保留，不代表功能通过。
- `python fpga/kcu105/target.py --output-dir .../build/standard` exit0；生产 BIOS
  SHA256 `2cb33d00c913f1d61f2f5949de5575598c44ee7a810e9b4881395e80103badb2`。
- 综合 cwd `build/standard/gateware`，命令 `vivado -mode batch -source .../evidence/soc_synth_only.tcl
  -log .../evidence/vivado.log -journal .../evidence/vivado.jou`。
- 运行中静态接口核对发现新 A0/A1 模块对 helper 的 INT port/address unpacked array 方向不一致。
  已对本任务 Vivado 进程树主动 TERM，日志保留；不是综合成功/工具超时/功能测试失败。
  修正为 helper/backend 一致的 descending INT array，并显式拆开状态输出与容量计算的组合块，随后重新做新快照。
- 不以解析/生成成功替代综合报告，不以综合报告替代功能/布线闭合。


### 完整SoC修正候选：输入记录（最终结果见下）

修正 helper、A1 和 backend 之间 INT port/address unpacked array 的方向一致性；
新独立快照 813 文件，source-manifest SHA256
`ef1b5390008adb4fdeb732b7c1a788b03a70c70f15eba6af42712a2b58cc5c4b`。
根 `/home/chen/FUN/CISLC-O3-runs/soc-fourwide-20261011-164836`；
目录结构/主机/工具/命令及100MHz标准完整SoC范围同前。重新读取共享配置后，
cloud_chen SSH再次超时，Alan工具/依赖/磁盘/内存预检通过，重新解析/生成/综合。
运行状态从此目录 `evidence/*.exit` 与日志核实；最终综合结果如下。


### 完整SoC基线最终结果与第一四宽削减候选

修正候选 `soc-fourwide-20261011-164836` 主任务 exit0，`WHOLE_SOC_SYNTH_REPORTS_COMPLETE`。
开始08:50:00Z，结束09:47:20Z，综合54分40秒，综合/主要报告3418秒。
命令阶段汇总1300 Infos/1065 Warnings/0 Critical Warnings/0 Errors；内部综合另报告214050次warning，
含大量保留属性/未连接/移除对象的重复警告，原日志保留。报告阶段另有大pin集合/弃用参数critical warnings。

| 项 | 完整SoC基线 |
|---|---:|
| CLB LUT | 506389 / 242400，208.91% |
| LUT logic / memory | 499152 / 7237 |
| FF / latch | 211422 / 0 |
| RAMB36 / RAMB18 | 231 / 40 |
| DSP | 38 |
| WNS / TNS | -21.941ns / -1231935.500ns |
| setup failing / total | 242079 / 629031 |
| WHS / THS | -0.252ns / -1549.868ns |

最差内部路径：DCache `ps_resp_q[paddr][10]` → BR读前buffer第二槽 `branch_cond[0]/CE`，93级。
主失败时钟域是sys_clk100MHz。与首版后端OOC的512级/-159.300ns比较可见当前最长链规模变小，
但两个scope/外部约束不同，不能作为同条件完整A/B归因，更不能称100MHz布局布线闭合。

重建层次inclusive LUT：backend390815、frontend79750、L225850；
RF INT30654/FP17940；R1buffer33444/RDQ19147/ROB39691/LSU30542/DCache24000。
跨层次逻辑归因会移动，不能把这些相加当组件固有成本或准确节省量。

基线LUT仍超限，按用户路线应用第一四宽削减候选（当前RTL、尚未重新验证）：
ALU3/FMA1、ROB32、INTpreg80、checkpoint8、L1D16KiB4way，其他宽度/端口/流水/双MEM/完成信用保持。
`num_fma` 支持1/2；禁用槽输出显式无效、buffer容量0，IQ不可路由；新增运行期断言覆盖该约束。
仲裁测试顶层/参考模型的候选数和MEM/FP索引由实际配置导出，适配FU数量变化，不改变期望规则。
三宽尚未实施；须先测此类四宽削减是否足够。

基线 `check_timing`：no_clock、unconstrained_internal_endpoints、loops、latch_loops 均0。
标准板级XDC仍有no_input_delay71/no_output_delay113（含DDR/SD/UART/reset等），
未为取得更好数字额外改约束；内部路径有时钟约束，不等同于全部外部接口时序验证。
DRC共201项，3项 UTLZ-1 Error，均为LUT超限（logic/LUT6/总LUT）；其他198项为警告，
包括输入缓冲、板级配置属性、DSP输入/输出流水和异步控制。没有关闭超资源DRC。
完整输入150文件，manifest SHA256
`073b08a00e841366e12040a115d2d9b02fd3a904d4ca320335f98165c4a97614`；全部位于隔离运行根。
本地 `build/soc-fourwide-20261011-164836/evidence-review.tar.gz` SHA256
`ad0018f6af65565b8c979c7c335d59c2a1657966cd83bc3736192aacfce83df9`；DCP仍保留远端。

警告审计补充：全RTL解析354项，含6项UNOPTFLAT（allocation、FP完成ready及CSR组）。
新operand pipeline独立测试顶层没有UNOPTFLAT/LATCH，但这不能解除全核警告；用户后置功能回归。
基线综合明确输出 `Synth 8-5856`：三维 `ram_banks_reg` 模式不支持，
`Synth 8-11357` 对18432位寄存器表示报警。INT PRF层次30654 logic LUT/0 LUTRAM/18496 FF，
没有映射成复制LUTRAM；不能把“代码写了RAM bank”当成实际RAM映射证据。
该点登记为后续组件实现候选，不在当前容量/FU候选中重写PRF。
FP PRF同样是17940 logic LUT/0 LUTRAM/8256 FF。

后续四宽候选应继续评估PRF读写端口、checkpoint/RDQ/IQ容量和前端预测表容量，
不能因第一轮三ALU/单FMA仍超限就直接判定“四宽削减不够”。
整体Decode/Rename/Dispatch/INT IQ选择/总退休四宽与某一类别的FU数、共享读写带宽分别描述。
减少端口后允许buffer等待，禁止丢失已从IQ转移的uop；FMA必须完整取得三源，
双MEM保留独立地址/数据路径，PRF ready与ROB完成仍只在真实写回发生。
三宽若进入实测，须逐一检查ROB/队列bank的容量整除关系，而不能仅将一个width常量改成3。

基线DCP只读目的寄存器分组 exit0（不是FU算术隔离测量）：

| 目的寄存器组 | WNS ns | 逻辑级数 |
|---|---:|---:|
| A0 | -21.109 | 91 |
| A1 | -20.388 | 90 |
| INT IQ | -17.206 | 80 |
| FP IQ | -10.420 | 59 |
| MEM IQ | -9.709 | 61 |
| BR IQ | -8.470 | 55 |
| ALU | -5.976 | 49 |
| ROB | -9.154 | 56 |
| Frontend | -4.835 | 45 |
| L2 | +1.030 | 28 |
| DCache | -9.928 | 66 |
| FMA | -3.325 | 39 |

上述负路径均从DCache `ps_resp_q[paddr][10]`出发。最差路径经过load queue顺序事件、ROB、
LSU结果有效、operand pipeline容量/仲裁控制，最终到BR buffer槽位写使能。
跨层次优化后的网名只能用于定位，不能把FP CONV/ROB名下的节点直接等同于其原RTL算术路径。
分组脚本 SHA256 `bdf0d02a0d70e68ad1153acc982c54cef97734e1a985dc3ab001b2bb6c2666e4`。

### 第一四宽削减候选：独立快照与运行记录

根 `/home/chen/FUN/CISLC-O3-runs/soc-fourwide-trim1-20261011-175440`，
本地证据 `build/soc-fourwide-trim1-20261011-175440/`。
同基底HEAD/CVFPU/common_cells版本，813文件 source-manifest SHA256
`9bef18b62ab8d106cb9110aa6dd939ccd8b54311dfe90dc62f348c376bdabdbe`。
完整综合输入150文件，manifest SHA256
`38c5b89ef9f3b23940566ba958940f01bd52477a90640deb6dfa981dc0719f01`；无隔离运行根外输入。
重新读取共享主机配置，cloud_chen SSH连接超时，Alan校验通过。
全RTL解析/新测试顶层解析/生产BIOS与标准SoC生成均exit0；功能测试未运行。
此处为启动时记录；该候选最终综合结果见下表。基线数字不代表此候选。

最终主任务/综合exit0，completion marker完整；09:57:14Z开始、10:38:07Z退出，
综合/主要报告2432秒。全RTL解析353条警告，独立测试顶层无UNOPTFLAT/LATCH；功能未运行。

| 项 | 第一四宽削减候选 |
|---|---:|
| CLB LUT | 432321 / 242400，178.35% |
| logic / memory LUT | 425511 / 6810 |
| FF / latch | 189446 / 0 |
| RAMB36 / RAMB18 / equivalent tiles | 199 / 40 / 219 |
| DSP | 27 |
| WNS / TNS | -17.457ns / -795531.688ns |
| setup failing / total endpoints | 174228 / 566263 |
| WHS / THS | -0.252ns / -1301.913ns |
| hold failing / total endpoints | 46175 / 566263 |

同一完整标准SoC约束下，比基线LUT减少74068（14.63%）；仍超限，不满足100MHz综合估算时序。
最差内部77级：DCache `ps_resp_q[paddr][6]` → FMA0读前buffer第二槽 `dst_preg[0]/CE`。
DRC111项，仍有3项UTLZ-1资源错误；无no_clock/未约束内部端点/组合环/latch环，
外部无input/output delay项仍为71/113。没有布局布线或功能闭合结论。
层次inclusive LUT：backend316071/frontend79758/L226636；INT PRF26601/15454FF、
FP PRF18056/8256FF（两者仍0 LUTRAM）、ROB24538/5009FF、operand pipeline12993/3460FF。
只读分组已完成，见该候选evidence/groups/groups.txt，不套用基线分组数字。
主要报告及两轮preview证据已拉回，分组完成前归档保留为 `evidence-before-groups.tar.gz`，
SHA256 `e0fadb71d7de8d6a8593b558895e67f247311e3ba8f4edec84b28b2efdeb39e5`。

下一轮四宽容量/FU/端口候选已准备在忽略的 `build/fourwide-trim2-prepared/`，
已在第一候选超限后应用为默认RTL；最终SoC综合见下文，功能仍未运行：
ALU2/FMA1、MUL/DIV各1、MEM2、ROB32、INT/FPpreg64、checkpoint4、RDQ8、IQ8/8/4/8，
INT4R/2W、FP5R/1W（一组三源FP读口+两路专用FP store读口）。
DecodeQ8/ibuf16/FTQ16、BTB256sets×2ways、TAGE512行/表与base1024、L2 128KiB4way/slots4。
L1I/L1D16KiB、LSQ16、MSHR4、MUL credits8/FPU tags8/SP5DP7及一致性/恢复/提前通知机制保留。
FP读口布局需要上述小范围参数化，不能只改端口数并保留硬编码6/7的store映射。
第一轮仍超限，因此应用此候选；全部整体宽度仍为4。

候选在Alan隔离 `soc-fourwide-trim1-20261011-175440/port-preview` 做静态解析：
整核exit0、测试顶层exit1，后者因读口编号数组仍写死3位，与INT4R要求的2位数组元素类型不等价。
首次preview manifest SHA256 `045c3d1364ebc39b2d40f00777df0768b81f0a0232fe6696482bb1f530bca89e`，失败日志保留。
修正为实际 `$clog2(INT_PORTS)` 数组，测试对外序列化显式补至3位，规则/断言不改。
隔离v2 manifest SHA256 `e4462e48cd8253f08d221b4ec48e8c3cb8334fc99c721200f29112d6c33c2234`。
v2整核与测试顶层解析均exit0，后者无UNOPTFLAT/LATCH/USERERROR/USERFATAL；不代表功能通过。
每次均重新读取共享配置，cloud_chen SSH连接超时、Alan环境/资源校验通过；仅解析，未做功能仿真。

### 第二四宽候选：独立完整SoC任务

根 `/home/chen/FUN/CISLC-O3-runs/soc-fourwide-trim2-20261011-184106`，
本地 `build/soc-fourwide-trim2-20261011-184106/`；同基底HEAD/CVFPU/common_cells，813文件，
source-manifest SHA256 `4f539766b734c79fdfc3dbb4a120577684443caa9e76a88d3bd1a3ccf9259e24`。
相同标准生产BIOS/完整SoC/100MHz/综合only流程，主机再次校验：cloud_chen SSH超时，
Alan工具/依赖/资源通过；启动记录对应任务最终结果见下一节。
该历史四宽快照未把整数/FP PRF存储方式重写；三宽转入发生在该结果取得之后。

### 第二四宽候选最终结果与三宽转入（2026-10-11）

`soc-fourwide-trim2-20261011-184106` 主任务/综合/只读分组exit0；
完整标准SoC、生产BIOS、KU040/100MHz，仍仅综合，无布局布线或功能证明。
综合及主要报告1660秒，10:42:27Z开始、11:10:27Z结束。

| 项 | 第二四宽削减结果 |
|---|---:|
| CLB LUT | 298222 / 242400，123.03% |
| logic / memory LUT | 290826 / 7396 |
| FF / latch | 140406 / 0 |
| WNS / TNS | -13.127ns / -643224.312ns |
| setup failing / total | 150767 / 443153 |
| WHS / THS | -0.252ns / -1211.410ns |
| hold failing / total | 42663 / 443153 |

最差内部82级：DCache `ps_resp_q[paddr][9]` → CSR `mip_sw_q[13]/D`，
数据路径22.962ns，其中逻辑5.161ns、未布局连线估算17.801ns。
路径包含同拍LQ order保护、退休/同步控制、DTLB/SQ事件及HPM溢出；
不能把优化后跨层节点名字直接解释成指令数据经过这些单元。
INT PRF现为1329 LUT（含592 LUTRAM）/63FF，FP PRF6186 LUT/4096FF/0LUTRAM；
相比历史三写口报告，不能继续把“INT PRF全展开”为当前事实。
层次inclusive LUT：backend203346、frontend69446、L217898、ROB23060；重建层次仅供定位。
资源仍超限；按已授权顺序转整体三宽，不转两宽。
当前70文件证据归档SHA256 `0ea53612362531c60a1caaa8a2d6f8e541dbe97bdef11f333a03f17ab8463672`。

### 逻辑流水原型与当前三宽候选

第一原型 `soc-fourwide-pipe1-20261011-190618`，813文件source-manifest
`c4000457eff0073e36ad9139dfbe11319c8076443f817ea663786d1daadd72e3`，
Alan lint/整SoC解析/测试顶层解析exit0（core lint341 warnings），未综合、未运行功能测试。
其整包队头阻塞已在当前代码继续重写，不能套用该原型解析结论。

三宽首轮 `soc-threewide-pipe2-20261011-192312`，813文件source-manifest
`077da9cd5908ccee7eb76e9ca8d2ac295983787cce7272ba3dee142863615b43`。
Alan lint/整SoC解析/测试顶层解析/标准SoC与BIOS生成均exit0（core lint343 warnings），
Vivado综合exit1：`o3_litex_top.sv:70` 的旧 `commit_width==4` 静态断言触发。
失败为宽度适配遗漏，不是主机故障或三宽资源结论；23秒即退出，原始证据保留。
按用户已授权三宽路线改为整体宽度一致、范围3～4的断言，四槽外部调试接口保持，
内部退休数组按实际宽度，未使用的调试槽显式补零；后续重测使用新快照。

当前代码：A0三槽逐源保留项与in-flight标记 → A1采样年龄优先级 →
A2并行前缀INT/FP预算与授权地址 → 各源三槽操作数捕获 → 原RegRead/FU请求接口。
未授权项只释放本次调度占位，在原A0槽重试；新候选包每拍可继续推进。
分配前预留捕获容量并计入授权在途项，慢FU等待不占共享PRF读地址；
真实数据检查、同拍取消、CSR/SFENCE读口互斥、LSU在真实RegRead接纳时预留credit保持。
没有新增串行状态机。连续三路INT/BR、单FMA、慢DIV隔离、所有权/操作数/恢复测试已写，
按用户门禁尚未运行；没有宣称连续吞吐或功能已通过。

### 状态机必要性初审（静态源码，非吞吐验收）

| 当前生产通路 | 处理方向与串行依赖 |
|---|---|
| A0/A1/A2/操作数捕获、ALU/MUL/FMA | 独立valid/占用与流水；新增路径不设全模块串行控制器；正常连续吞吐待验证 |
| INT DIV、CVFPU DIV/SQRT | 迭代商/余数或平方根依赖前一轮结果；保留局部迭代控制，接受间隔由算术结构决定 |
| ICache MSHR、L2 slots、FTQ/返回队列 | 逐事务状态支持多个在途项；不能因出现enum就改成一个全局流水valid，也不能将逐项状态称作全模块串行 |
| PTW | 下一层PTE地址取决于上一层读回；当前单walk局部控制保留，TLB普通命中继续走独立流水 |
| PTE A/D updater | A通路跟随PTW依赖；D通路在精确提交边界完成重遍历/CAS；需要保留身份/epoch与结果等待，不能延迟或丢弃同拍order保护 |
| mem_head_unit | MMIO/不可撤销原子、跨页store的检查先于写副作用，局部顺序必要；普通可缓存拆分load当前也走队头等待，列入进一步流水化候选 |
| frontend_sync_ctrl / commit同步控制 | FENCE.I/SFENCE等需要先等待排空再失效/确认，保留局部屏障控制，不据此阻塞普通命中流水 |
| 生产L2 AXI通路 | 实际实例为l2_mem_engine：每读ID独立组装、写缓冲保留至B，AW/W按协议排序；旧axi_master单事务FSM未接入生产L2，不为它重写生产路径 |
| MMIO / SD DMA桥 | 先核对调用方副作用与Wishbone应答合同，再决定可否重叠；不以“协议控制”作为免审理由 |

每一项仍需验收接受间隔、独立请求是否重叠，以及局部等待是否阻塞其他通路。
候选FP单写口一维RAM副本与ready-table固定目的解码准备在忽略的
`build/threewide-component-prepared/`，尚未应用；三宽综合结果出来后再按用户组件重实现顺序决定。

三宽重测 `soc-threewide-pipe2v2-20261011-192719`，source-manifest
`40d37f2f3599cb776c24527239c641f4836b2df4cf41b5dd1f5a1d3cdf746f82`（813文件）。
Alan lint、整SoC解析、操作数流水测试顶层解析、标准SoC/BIOS生成均exit0；
Vivado综合仍在运行，尚无资源/时序结论。该快照之后本地补充捕获credit/身份断言，
新增断言未包含在此轮证据中。

### 三宽综合期间的后续时序修改（尚未覆盖在运行快照中）

CSR队头请求捕获与架构CSR执行拆分一拍：捕获操作数/完整csr_req，下一拍由CSR文件读改写；
commit_ctrl以csr_inflight持有精确队头并抑制IRQ，真实响应后仍先完成/退休，改变上下文的写继续同步重取。
CSR非法响应仍回填原ROB项后触发同步trap；普通三宽退休没有新增串行等待。
读口互斥同时覆盖捕获/执行两拍，ITLB/PTW接纳也覆盖已接纳请求。
HPM增量限定为FE/BE计数实际位宽；上部16位块独立预增、低部carry选择，
overflow使用窄加法与上部全1检测，保持同拍counter写优先、selector旧值、OF软件基线/硬件set优先合同。
Python数学恒等式78464例通过（增量宽1～16）；这不是RTL或HPM功能仿真证明。
HPM边界进位/同拍溢出与CSR在途IRQ/PTW边界测试已写，功能运行后置。
候选组件预览 `threewide-components-preview-20261011-194252`：cloud SSH超时255，Alan预检0；
HPM顶层、新FP RAM/ready-table测试顶层、固定槽完成队列顶层解析各exit0。
source-manifest `00f3f7c293e466c29a4dd0e7da18da3e5096969c3144637f4774bddaa80aa909`。
预览只解析且早于新增CSR级；prepared RTL仍未替换默认组件，无PPA/功能结论。

### 寄存器组件独立A/B综合（Alan，2026-10-11）

`threewide-components-preview-20261011-194252/evidence/register-ooc-v2/`，
相同64-entry、INT4R2W/FP5R1W与三路allocation、完整外部数据/地址/ready接口，KU040 OOC综合；
baseline取该隔离src，prepared只替换PRF单写分支与ready-table。主任务exit0、两变体完成标记完整。
| 项 | baseline | prepared |
|---|---:|---:|
| 顶层LUT |7595|2480|
| FF |4288|192|
| LUTRAM |592|962|
| FP PRF inclusive LUT/FF |5838/4096|691/0|
| INT ready inclusive LUT |208|238|
| FP ready inclusive LUT |167|168|
FP单写一维RAM确实减少资源；ready-table重写无面积收益，因此不作为默认面积优化应用。
全系统层次ready-table约3990 LUT包含折入的上游组合逻辑，不能算成其自身单元成本。
这仅是组件存储映射证据，不是整核容量、物理时序或功能等价证明。
第一Tcl调用exit1（read_verilog -define要求compile_unit模式）；失败证据保留，
v2改为fileset verilog_define，未改RTL、测试期望或时钟。

后续preview `threewide-components-preview-20261011-195155` 的当前整SoC、CSR/HPM、存储与完成队列顶层解析exit0；
prepared整SoC解析exit1，因候选LSU RAM拆分脚本多出一个end，已仅修候选文件后用新快照重测。
当前整SoC仍有两项既有UNOPTFLAT（allocation分组/FP response分组）警告，不能宣称静态无环；
物理综合check_timing结论需另列，不能把Verilator exit0当作它的替代。

### 三宽pipe2v2超限后的组件重实现

资源报告已生成：LUT296394/242400（122.27%）、FF150564、memory LUT7397、latch0。
完整综合/只读分组均exit0；WNS -10.606ns，TNS -447785.594ns，setup失败144346/460371，
WHS -0.252ns、THS -1400.987ns，hold失败47938/460371。最差内部73级DCache paddr[6]→CSR mip_sw[13]。
RAMB36/RAMB18折合175.5 tiles（29.25%）、DSP27。最终74文件归档SHA256
`9859efad7ca7e2127b6c0b3fef168141389a68c17842c88eb58a469c7d2b396f`。
分组最差HPM -10.184ns/72级、INT IQ -8.384ns/54级、DCache -7.579ns/56级，
A0/A1/A2/capture分别 -1.708/-5.019/-6.392/-5.190ns；这些都是旧三宽快照综合估算，不是新组件结果。
四宽改三宽本身不是容量闭合；按用户授权顺序保持三宽进入组件重实现。
已应用FP单写RAM、固定槽MDU完成队列/LSU结果RAM、LQ直接退休位置order检查、
A0四槽完整uop所有权到实际PRF读取、A1/A2窄调度描述符与三槽固定操作数捕获payload。
新增capture_count/owner断言；顺序索引压缩代替宽数据移动。ready-table保持原实现。
prepared preview `threewide-components-preview-20261011-195953` 整系统解析exit0；
source-manifest `a98d2c57f252c7519072697880466c55a89fb4bb613a7741420b3c783d793c6a`，
prepared-manifest `83447e28088015bd0804fda794c67bc6c370428852b36c892502b81e2ed6f5f1`。
该prepared试验还含未应用ready-table变体，且早于新增capture_count断言，不能替代默认RTL复验。
FP/INT存储scoreboard、A0延迟释放模型、LQ wrap/同拍kill order保护测试已写，未执行。
三宽LQ测试保持原四指令case，在helper中分成合法的3+1批次，不删第四条指令或降低原测试规模。

组件重实现完整任务 `soc-threewide-components1-20261011-200659`：817文件source-manifest
`652a2dde03d69675ca6ed7cd33c3c2c83b1009894579a39827d6f2f83597ad0e`；
cloud连接超时255，Alan预检0，lint/整SoC解析/操作数测试顶层解析/生产SoC与BIOS生成exit0，Vivado运行中。
任务启动后静态检查发现free-list正常release范围比较将NUM_PHYS_REGS=64强转为6位0，
会丢失所有正常释放；已改为整数上界比较，既有700-cycle随机模型保留，新增耗尽池/最高编号释放无当拍旁路用例。
这项修复未包含该运行快照，不能将后续资源或功能结论套用到本地最终代码。


### 三写口PRF的显式RAM银行对照（未应用）

Alan独立 `threewide-components-preview-20261011-194252/bank-prf-ooc` 在KU040/10ns对比
同样64项、6读口、3写口INT PRF。baseline/prepared/runner均exit0；保持同址最高写口优先、
同拍旁路、INT p0恒零、FP p0可写与FPGA数据不reset语义。prepared为每个写银行/读副本
显式一维单写RAM及逐行latest-tag寄存器；未修改默认2W4R配置。
顶层baseline LUT21953/FF12350/LUTRAM0，prepared LUT2901/FF128/LUTRAM1332；
PRF内部prepared LUT2445。结果仅覆盖独立PRF，不能外推整SoC节约相同数量。
证据与逐文件SHA256保存在 `build/threewide-prf-banks-prepared/`，尚无功能仿真。

components1完整150个综合输入（包括生成的SoC RTL、DDR PHY、mem/init和XDC）SHA256
`90e1e26e7a0e96ba25dbd4046e8b1dc28af32ceca4ef1bd414cba232af72d4d0`，external inputs为空。
该运行不含之后free-list上界修复，也不含下面的前端候选。
前端RQ/IFU队列单写RAM候选保存在 `build/threewide-frontend-storage-prepared/`，
只改变宽payload存储及窄kill元数据，未应用默认RTL；保持原请求/响应/kill/dequeue优先级及停顿行为。

显式多写银行实现随后已应用默认PRF源码，但保持INT4R2W/ALU2配置；活动components1快照不包含本次应用。
register_storage测试顶层新增可覆盖IR/IW，保持默认测试和700周期seed105；补充6R3W复验命令，未执行。
完成队列既有depth2定向测试保留，另补900周期seed105的端口结果/信用守恒scoreboard，
通过参数可检查depth8的固定槽碎片、双结果、取消/正确解析/释放/背压/提前通知与reset。未执行功能仿真。

### 加深算术流水后的FMA身份容量（本地修复，待复验）

DP native为7级，wrapper另有1个结果保持槽，且入口不借用当拍WB释放信用；
原8个身份槽可能在连续DP流填满后出现容量气泡。ADDMUL现在按max(配置槽数,DP级数+2)
保留最少9个槽，其他FP组仍为配置8；不增加状态机或算术延迟。
新增S/D各96条连续接受、无WB背压用例，逐条检查身份/精确结果/flags/无额外入口气泡；未执行。
TB依据公开rob_idx宽度映射原输入编号，保留原输入向量、结果golden和用例规模；连续流禁止复用未完成的ROB身份。活动components1不含该容量修复。

components2静态preview `threewide-components2-preview-20261011-202803` source-manifest
`b154e1d9b9ba2d51d1e13b7829e39f4bfc7ec174cfe8fafa6877cf0e472183cb`：
12项解析exit0，FPU TB解析exit1（本次新增TB错误地引用fu_tag不存在的instruction_id字段）。
失败证据保留；已恢复真实ROB tag并按公开宽度映射测试身份，尚待新快照复验。

### trap控制按逻辑职责分级（本地改动，待复验）

精确接受/取消 → 请求寄存(EPC/cause/tval/xRET) → 架构CSR/priv更新和目标计算 → 目标寄存/redirect。
接受拍仍阻止正常退休并取消推测；合法xRET自身仍在接受拍退休。新增一级只增加trap重定向延迟。
request/redirect两个寄存valid共同持有边界，阻止重复IRQ/异常接受、普通退休、CSR/sync/D-bit请求、
后台新issue/rename及ITLB/PTW接纳直到redirect；普通路径吞吐不变，没有新增FSM。
trap_kind在原接受拍锁存，committed_next_pc在真实redirect拍更新。
既有trap_ctrl400-cycle seed测试保留并改为两级transport契约，检查请求身份冻结/目标/复位；
commit_ctrl补边界占有/重复IRQ与同步异常/redirect用例。全部功能测试仍待后端重构后执行。
活动components1及上述components2 preview均不含这条trap流水。

新静态preview `threewide-components2-preview-20261011-203148` source-manifest
`3e9a9e52e946f7f69dba38fe0c5d50cdfb341becef9522098fff4d9681e29982`，
cloud SSH超时255、Alan预检0；14项解析均exit0（整SoC与前端候选overlay、trap/FPU/operand/commit/HPM/free-list/LQ、
PRF FPGA默认/6R3W/generic、completion2/8），包含PRF银行/FMA最小9槽/trap流水与较晚free-list修复。
逐项命令、工具版本、exit和日志位于该build/evidence；此前FPU TB解析失败保留，不以新通过覆盖。
这是解析门禁，未执行功能仿真、布局布线或bitstream。前端两队列RAM候选仍未应用，独立Vivado对比等待主综合结束后运行。

中断资格/原因新增一拍采样级：raw CSR irq_take/cause → 寄存候选 → commit精确接受。
候选每拍覆盖（含撤销），不是sticky pending或已接受事件；EPC仍在实际接受时由committed_next_pc确定。
CSR在途/已执行未退休、trap在途、MMIO/AMO不可撤销保护与同步异常优先级仍在接受端检查。
CSR配置改变拍被已有串行边界排除，候选可在解除保护前刷新；WFI仍用真实irq_view唤醒。
该级给控制路径增加职责边界，不影响普通退休宽度，不新增FSM；本地新增，尚待准确快照复验。
缓存返回队列原golden模型/seed/规模保持，补公开exception输入输出及异常payload/物理槽复用/
zombie响应丢弃用例，未运行功能仿真。

components1主综合/报告exit0（1802s）：LUT286230（118.08%）、FF144484、LUTRAM7990、latch0。
WNS -11.647ns、TNS -281296.562ns，setup失败107300/459099；WHS -0.252ns、THS -1369.412ns，
hold失败46596/459099。最差内部67级，从LQ pa_q[9][6]到LSU replay_rr[1].branch_mask[0]；
逻辑3.535ns（16.456%）、未布局布线估算route17.947ns（83.544%），不以逻辑延迟宣称100MHz闭合。
主证据暂归档58文件SHA256 `e2f452e8a78337a4450a25993b686b7f8c4506955fe3829dc454d71632c91d1d`，
只读分组尚待最终归档；此结果不含较晚PRF银行/free-list/FMA/trap/IRQ候选级。

前端存储独立对比Alan各parse/synth均exit0，归档SHA256
`171343557b9023ed50f12b5ebcd63b901f6fe38c78bf1f5265ea15a8759ef838`：
RQ baseline LUT2013/FF2257 → prepared LUT1373/FF1178/LUTRAM82，已应用。
IFU queue baseline LUT2381/FF4175 → prepared LUT2576/FF308/LUTRAM1228，
因当前LUT约束未采用该+195LUT候选；保持原IFU源码。独立局部结果不外推整SoC。

SQ replay已用物理项并行候选/窄年龄与槽号的平衡oldest-two树替代按head旋转的串行扫描，
payload只在选完槽号后读取，保持当前双MEM两路每拍选择、同拍取消和实际握手才清sta_ready。
Rename/Dispatch/FU预算计数改用容量对应的最小位宽，不以32位int实现逐lane扣减；容量和宽度不变。
这些本地修改待新的准确整系统解析/综合。下一轮仍整体三宽、ALU2/MUL1/DIV1/FMA1/MEM2，未降到两宽。


### 2026-10-11 21:04 当前整系统快照与操作数存储实验

Alan完整快照 `soc-threewide-components2-20261011-204632`：817文件源码manifest
`0bb31d49c93c1d35c0c3436688af92a60fd2f40288f2d4ba83d186aec2a50c68`；150个实际RTL/XDC/初始化/Tcl输入manifest
`a2fc958815ef43246401c8622b11be96090e362a9330c5bfdf89299d55564aa9`，无外部输入。
lint、整SoC、operand与11相关测试顶层解析及生产BIOS/RTL生成exit0；完整综合运行中。
包含free-list边界、PRF显式银行、FMA9身份槽、trap逻辑两级、IRQ候选采样、SQ oldest-two树、窄预算与RQ RAM。

首轮组件综合只读分组有非零端点及有效路径，`groups.txt`已审计；本地archive最终73文件，SHA256
`441d89eb2e75912fe71e4e248eb2a5b9d975039a762a81227e22153299048c95`。
其A0/A1/A2/capture最差分别 -3.358/40级、-4.045/42、-5.388/45、-10.641/64，均从LQ取消控制起点传播。
`rg --files`默认遵守忽略规则而隐藏*.rpt；archive与实际文件均包含15项report，不是零端点。

独立 `operand-storage-ooc`（同一快照pkg、完整重命名uop接口）baseline/prepared解析与综合exit0：
LUT36323/FF52987 → LUT32879/FF53227，latch0、LUTRAM0。候选把不变载荷写入单写数组，
可变身份/branch mask留在元数据；Vivado仍映射FF，尚未采用。继续比较位向量存储写法。
这是未施加综合前时钟约束的独立面积比较；时钟在synth后添加，不能冒充100MHz整系统结果或功能证明。


### 2026-10-11 操作数位向量RAM/HPM同拍改造与恢复应用分级

独立 `operand-storage-vector-ooc` baseline/prepared解析与综合exit0，完整接口baseline
LUT36323/FF52987/LUTRAM0 → prepared LUT25955/FF2011/LUTRAM12496、latch0。
与结构体数组候选相比，显式位向量数组使Vivado识别单写RAM；当前已采用。
原结构体候选28文件archive `e37ccc1dba6f674025afa73ffbe124420fff8e6891aca6da8b31ebe4607854cc`；
位向量候选证据位于 `build/threewide-operand-storage-vector-prepared/evidence/`。

HPM独立三版本：手工上部chunk baseline LUT2811/FF1184；原64位全加 original2786/1184；
保留64位counter CARRY、OF由窄event加法carry与高位全1独立决定 prepared2580/1184。
全部解析/综合exit0，旧/手工/候选内部寄存路径分别3.732/3.620/3.100ns估算；
输入端点未约束，不把它解释成完整event→OF的100MHz结果。候选少231LUT，不增加周期，已应用。
34文件archive `d80ff85a23d06d065cffe72d1fa6637328a63fa59f8eed22ef971fb28ef98ff9`。
此前整系统HPM层级8k与独立2.8k不同，说明flatten跨边界归属不能当成组件自身面积。

`recovery_boundary`把commit精确接受（C0）和全局取消/committed-map恢复（C1）分开。
新增HEU起步和ITLB PTW入场以C0请求局部门控；普通年轻推测工作最多多推进一拍，C1统一取消。
C1 pending挡退休/CSR等新串行admission；trap原有C1 CSR update/C2已寄存redirect不再重复延迟，
其他同步重取的完整packet在C1发出。没有FSM，普通issue/retire不进入事件流水。
新增500周期固定种子packet/cancel/reset测试、SQ40批六条STA重放/独立ready/kill/wake/wrap测试未执行；
集成精确性与不可撤销保护仍需后端统一功能验证。完整components3待静态、生成、综合证据。


第二轮完整综合/报告exit0，2090秒：LUT285294（117.70%）、FF143734、latch0，RAMB36=166/RAMB18=19（175.5 tiles）、DSP27。
10ns WNS -8.249ns、最差53级DCache ps_resp.paddr[6]→CSR mip_sw[13]，TNS -199414.656、setup105655/451743；
WHS -.252ns、THS -1426.286、hold47331/451743。no_clock/internal-unconstrained/loops/latchloops均0；
板级外部71 inputs/113 outputs缺delay，不能用报告宣称外部接口时序。最差逻辑53级仍未满足100MHz。
初次77文件archive `9cf5db001fbf6041e3b19906a3694587b6a08a3088e7a6630924e0698b9b67d9`，只读分组运行中。

第三轮823文件source-manifest `2bae52f60c6e4b08181917a9ba4e90d252237fd13e981382989dcf78f738d0b5`，
整SoC/lint/operand+12相关测试顶层解析与生产生成共16exit0；Alan完整综合已启动。
原80批每批四条SQ测试按真实三宽分两次入队/退休，ROB索引按公开cfg宽度归一；没有减少事务或golden。
该适配及cfg_rob输出是第三轮snapshot之后的测试更新，功能执行与新解析仍待。
位向量operand候选27文件archive `279edb6a4a8650295b7816527a3ad38219d84dd74c522f4975286fe7d3e868a7`。

### 第三轮完整结果与第四轮存储重实现（2026-10-11）

components3完整综合/报告/runner均exit0，1999秒：LUT294923/242400（121.67%），FF139521、
LUTRAM11440、latch0；WNS -5.828ns，58级PLIC threshold→HPM counter，仍超限。
实际151输入manifest `b64b7a5bfadf6f84473c0b4f96300e945d7106517447880cd09838511a9ab5f8`，
external=[]；98文件归档SHA256 `504378ec69f4bbdf509e73a57e0740fe259aba83bb4707970f8398b530a500a3`。
组件2最终95文件归档（含有效分组）SHA256 `38ed8d05db038423e16e480c5727a1f30fec4fa7460aeabecff697af4f508414`，替代较早77文件归档用于完整诊断引用。

第四轮默认接入RDQ、四类IQ的writer-bank/reader-replica RAM，以及ROB初始/晚更新RAM分离。
下表独立OOC均使用相同公开完整接口、相同common package、KU040，解析/综合/runner exit0。
时钟在综合后添加，输入未约束，故仅面积对比，不作为100MHz完整路径或功能证据。

| 模块 | 原LUT/FF | 候选LUT/FF | 候选LUTRAM |
|---|---|---|---|
| RDQ | 9991/4472 | 5890/136 | 2880 |
| INT IQ | 11924/4748 | 9270/404 | 2880 |
| FP IQ | 11034/4748 | 7442/404 | 1920 |
| MEM IQ | 11361/4747 | 7357/404 | 1920 |
| BR IQ | 4824/2371 | 3389/199 | 960 |
| ROB | 21578/4855 | 10674/607 | 1398 |

证据archive SHA256：RDQ `e6ce164d9f8fa8690bb742cd552cc1292f2419c89202543163cbefbf14d1de60`；
INT IQ `8acbf690f877736597e0dc285d006a6cab94b86efb82c13780724628a0a794e8`；
其余IQ `dc9fd00348034078b57bb1bb9f74a5564bcb7485d1055c9c95140dec5a0af146`；
ROB `ff8bde5477039638b5ce77f58a60663fdbf32800169fa8437f9c5f3f4199b79d`。
只显式onehot替换bank mux的OOC：uop_queue资源相同，ROB仅272 LUT下降且+59 FF，未采用；
42文件归档 `cc612ab040dad6375301c7ed8d240a125994e2c48bc22f1ce94da20288d7a6d1`。

静态preview `threewide-components4-preview-20261011-214022` source-manifest
`e16f3b969a313c36e866bc669c711978607642d219ba07e5af35115b3af4e740`，12解析exit0，覆盖RDQ/四IQ，尚无ROB RAM。
新增ROB测试wrapper preview `threewide-components4-preview-20261011-215925` 12解析exit0、ROB解析exit1，
失败是unpacked array三元连接；改为逐lane显式wire后重新解析，失败证据保留。
RDQ/IQ随机全payload各700周期及ROB80+80批复用/优先级/环绕测试已写，未执行。

`soc_synth_only.py --directive AreaOptimized_high`是可选面积实验；default保留生成board指令，
不同非default指令拒绝被覆盖，记录effective directive与实际Tcl SHA。
已用Alan Vivado2022.2 installed `synth_design -help`确认选项；本地只做纯Python Tcl生成检查exit0，
未开始完整面积实验，严格无opt/place/route/bitstream。

第四轮完整快照 `soc-threewide-components4-20261011-220303` source-manifest
`e3b9752feb89a6ded099d2629fe6d8cc965d1a047b6d7828ced23ac441dce848`，828文件；cloud预检SSH超时255，Alan环境预检0。
新ROB wrapper先后修正unpacked array三元连接及vaddr_t未限定namespace，两次失败保留；
第四轮全19项lint/解析与生产BIOS/RTL生成exit0，Vivado默认指令正在Alan综合。
本轮覆盖RDQ/四IQ/ROB RAM和最新测试，功能未运行；后续WFI修改不在该快照。
WFI现采用“观察局部使能pending → 睡眠状态更新 → 下拍恢复退休/入场”的逻辑边界，
去掉PLIC→当拍stall旁路。仅增加睡眠唤醒响应一拍，普通三宽吞吐保持；原200随机周期/seed保留并增补edge前后stall检查，未执行。


后续组件5静态preview `threewide-components5-preview-20261011-221551` source-manifest
`d1c307d78b54a0a14aff7bd20afdac76a11208a560323eb4af9ae89860fe11b8`，839文件、17解析exit0，
覆盖WFI寄存式恢复、SFENCE命令捕获级、ICache MSHR response RAM及新增测试，未执行功能。
INT IQ随后新增按FU收集最老候选→并行年龄排序的窄选择逻辑，完整接口独立OOC LUT9270→9451、FF404保持；
内部寄存路径估算8.240ns/22级→6.374ns/15级，输入未约束。此处181 LUT换时序，已接入待新整系统复验。
原700周期载荷测试保留，另补900周期ALU/MUL/fused-MUL/DIV混合可用性与独立部分接受模型，未执行。
ICache MSHR RAM OOC LUT1528/FF2353→LUT1054/FF305/LUTRAM296，archive
`7f6c302d92b2746ea15638f918fe6bd66c9230c4de12cd58fa63cd0890cc644d`；
第一次OOC脚本clk名错配失败保留，改用clk_i的v2全部exit0。
INT IQ选择OOC archive `28377ea90b924e0aed44a58cb60f6f01ff9b40d862666bafce482f10c43142ad`。
Rename压紧onehot候选 OOC LUT1051→1318、FF1495→1524，无资源收益，未采用；archive
`38f6e78061405dcd0908971b6ec1cd3669ed4429e7ddac895104bea04911e994`。
第四轮151实际输入manifest `fe6c00051355b571c65c1c8e611d3876384f2ccd6a85554226356a15fe3bc684`，external=[]；
同RTL的AreaOptimized_high仅在默认综合exit0后运行，已排队，当前尚无结果。两种模式严格停在综合。


### 2026-10-11 22:47 当前综合边界与第五轮

目标仍为KCU105不少于三发射；四宽缩减后仍超限，当前整体三宽，未再缩宽。
components4在Alan完成默认完整SoC综合/报告/runner/只读分组，均exit0，1460秒：
LUT280125/242400（115.56%），FF126203，LUTRAM17360，BRAM175.5/600，DSP27/1920，latch0。
100MHz综合估算WNS -7.907ns、TNS -109488.312ns，92944 setup失败端点；
WHS -0.252ns、THS -1209.213ns，45287 hold失败端点。最差50级PLIC threshold→INT IQ order。
无no-clock/internal-unconstrained/combinational-loop/latch-loop；外部71输入/113输出未设delay，不能据此声明全板时序。
第四轮828文件source-manifest `e3b9752feb89a6ded099d2629fe6d8cc965d1a047b6d7828ced23ac441dce848`，
151实际输入manifest `fe6c00051355b571c65c1c8e611d3876384f2ccd6a85554226356a15fe3bc684`，external=[]。
完整104文件证据archive SHA256 `ff6c05bd057ddb0bd592fbdeb4af3f75cea93e9b6e8450dcb22ed831e8d238f9`，
替代较早95文件归档（新增完整分组结果）。输入源码对应base HEAD d834162的dirty manifest，而非干净HEAD。

后续默认采用ICache标签三读副本RAM+独立valid/PF元数据，保持原请求采样、fill replay与PF标志优先级。
独立完整接口OOC LUT18209→14091、FF13236→8081；内部路径4.983→5.535ns，输入未约束，仅组件诊断。
28文件archive `c77c0601cfdcc73ee087926247cdb0d6a970680faa062a29b6a729e4b33a7d39`。
HPM采用E0选择并冻结合格增量→E1累加，CSR/RMW前递pending增量保持架构边沿值；
同拍计数器写丢弃该计数器当前增量、配置写用旧配置计数、OF软件baseline/hardware-set优先级保持。
独立OOC LUT2580→2883、FF1184→1218；内部路径3.124→3.466ns，并未独立改善；
接受303 LUT成本用于切断整系统晚事件到宽累加的逻辑链，整体收益待测。
27文件archive `0cf5a06abf1266febc0fa95c33a5038579d008e95c5c3bc48ae257cdd117a2d0`。
Python pending-view代数40000周期/8计数器/seed105通过，仅代数，不是RTL仿真。
新增HPM1000周期逐边沿RMW/inhibit模型与ICache20批reset/invalidation/tag复用测试，原测试/规模/golden保留，均未运行。

第五轮 `soc-threewide-components5-20261011-224328`：839文件source-manifest
`d7a17af46738ab42f14cdb67c4b6888f9f17a5cbac5e6b80919f9f6250b18880`。
新鲜host配置预检cloud SSH255、Alan0；Alan 22项lint/解析与生产BIOS/RTL生成共23项exit0。
覆盖WFI寄存恢复、SFENCE命令级、MSHR数据RAM、INT IQ并行FU候选排序、ICache标签RAM和HPM事件分级。
完整综合已排队，明确等待第四轮AreaOptimized_high runner退出，避免本任务两个完整设计并行。
AreaOptimized_high使用第四轮同一生成RTL/BIOS的151输入，仅改变综合directive，尚无最终结果。
当前新FU前缓冲固定payload存储仍是独立候选，尚未接入第五轮或默认RTL。
功能仿真后置；没有opt_design/place/route/bitstream/板测，资源与100MHz尚未闭合。



第五轮准确152个实际综合输入manifest `a0e2ba06e0d62398e70b059f4a34f0fd3a0b124d3ad16e77b575334b6d396d2a`，external=[]；
新增SFENCE模块导致输入数从151变152，完整综合尚在等待前一面积实验。
FU buffer随后采用两个固定bit-vector payload RAM槽，valid/两个branch mask/head单独寄存；
保留原两槽、raw occupancy不借同拍释放、实际buffer握手删除IQ、各FU独立的规则，不增加读延迟。
完整公开接口OOC LUT869/FF1106→LUT638/FF19/LUTRAM316，内部1.744→1.578ns，输入未约束；
27文件archive `00a43e0b613f21665c44b1fe7f4c3944fbdc2079545ca67fa0339461cf50c44e`。
新增fu_buffer_storage1000周期完整opaque payload+两个mask/复用/reset/flush随机模型，功能未运行；原fu_issue_pipeline400随机保留。
静态preview `threewide-components5-preview-20261011-224821` source-manifest
`ec3e0884cf930ad612bda21db7bcfc22e5f88d80f238533f42a693c238100084`，17解析exit0，覆盖默认FU RAM与全SoC，
此次未单独解析新增fu_buffer_storage wrapper，后续另行解析。该改动不在第五轮完整综合快照。


后续默认L2返回FIFO改成各client独立、精确实际depth的bit-vector payload array，head/tail/count与握手优先级不变；
不再使用统一[3][6]存储。独立完整L2接口OOC LUT16455→14072、FF20521→18450、BRAM30.5保持；
LUTRAM仍0，Vivado并未把此浅数组映射为LUTRAM，不能称作已成功RAM映射或整系统收益。
27文件archive `880ea660476f3752e883efb2a4031be374bc52c8ff3637bc3e39db4018b33265`。
Bench新增可选client response-ready，默认行为/旧seed51/52各2000D+500I规模与golden保留；
新增seed105 40批四条L1I+一条DMA的held完整数据/身份、wrap复用测试，功能未运行。
当前静态preview `threewide-components5-preview-20261011-225359` source-manifest
`3dd7259d5648ca88e2299a7f39f69fc92cff6f7dad5cc5307f1d92fa53af56cf`，19项lint/解析exit0，
覆盖全SoC、FU payload RAM、L2 client payload独立存储及新增wrapper；没有功能或该源码完整综合。
之前preview `threewide-components5-preview-20261011-225122` source-manifest
`06c64083cc69f132c8af5a5c8bb1219a1b38974b3f781ad2bfbc12120a1b3e5e`，18项exit0，已覆盖新增FU wrapper。


Decode uop_queue writer-bank候选独立OOC LUT6018→4103、FF10→49、LUTRAM1120→2520，
内部路径估算1.648ns/3级→2.176ns/4级（输入未约束）；默认接入以减少宽输入lane旋转。
三条固定writer银行各有三读副本，row writer tag按真实入队更新；reset/flush清窄head/tail/count，
原pre-edge空位、不借同拍释放、有效前缀和R1出队合同保持。容量仍8/宽度仍3，不增加级或FSM。
27文件archive `265e6532fcf5a6e906e078d25f6453202bf53383cb940954cb05db837e53af3d`。
旧900周期测试改为读取公开cfg，定向填满末批可不足三条；旧seed/900周期与FIFO golden不变，
已有1200周期全payload测试加入默认make，均未功能执行。此改动不在第五轮完整快照。

Completion bypass窄onehot+balanced数据OR候选未采用：有相同输入/输出测量寄存器的OOC，
LUT3775→3846、FF2009相同，内部路径2.151ns/5级→2.721ns/6级，面积和估算均变差。
28文件archive `607fab56b104aeafcf6ba33845d0c530d389e27b9323c1c2e35a5aaf4b5ac281`。
第一次wrapper缺o3_types_pkg显式导入，解析exit1，13文件失败archive
`a170a8674f26d973f86cf4a332cbfdd5068044eda23e224550e6bf95256dbd1b`；v2解析/综合/runner0。
默认原bypass未改，不新增候选module或改变优先级/旁路时机。


PMP change局部比较随后接入默认：pmp_next更新逻辑不变，仅针对当前PMP CSR判定有效改动。
CFG比较完整有效64-bit字，addr比较选中entry原始54-bit地址，保留隐藏低位和锁定TOR行为。
独立CSR完整接口OOC LUT10628→10315、FF5058→5061；内部6.339ns/24级→6.224ns/27级，输入未约束，
不以此声明板级时序。28文件archive `6800b102f74696a4393ad1bac437606caeb62aac83d71b498c80789756118a45`。
第一次wrapper缺端口括号，parse exit1，13文件失败archive `3b1e8eb221db1c4598ede7e836ca2c6561b5bd680b2633c3c2bc4c7bcc0a91b5`；v2解析/综合/runner exit0。
新增CSR PMP1000周期raw-change模型；旧四条retire count按真实三宽拆成3+1，累计golden54保持，功能未运行。
静态preview `threewide-components5-preview-20261011-231207` source-manifest
`65850030091dbcf700f69de45c018d2cc191ecb7d30f02a0edfa5e97b17d85b0`，21项lint/解析exit0，
含完整SoC、当前FU/L2/Decode/PMP候选与全部新增wrapper。随后只调整PMP测试从公开cfg获取项数及文档。


2026-10-11 23:27 CST：C4 同输入面积策略对照结束，Alan/Vivado 2022.2，runner/synth=0。`AreaOptimized_high` 使用 C4 相同 151 份输入（manifest fe6c00051355b571c65c1c8e611d3876384f2ccd6a85554226356a15fe3bc684），仅策略不同。LUT 262123/242400（108.14%），FF126119、LUTRAM17316、BRAM175.5、DSP27；最差综合 WNS -9.104ns，60级 ROB head→CSR mip，3436秒。相比 default 少18002 LUT，但 WNS变差1.197ns，仍不适配。报告归档21文件 SHA256 `4ae3d4a031e44b7bccbdaf05516146bf6e1ecb975144bdedcc9933a718a0e72e`，目录 `build/soc-threewide-components4-20261011-220303/area-optimized`。未 opt/place/route；不能声明物理时序或板级可用。C5默认策略整系统综合已接续启动，之前23项静态/生成通过。

C6待集成：ROB分配时保存CSR/SFENCE两位预解码，每行与原不可变元信息相同写入/复用/复位，恢复后无效旧行属性保持与旧视图相同；普通读口保留和CSR/PTW admission改用窄谓词，CSR实际请求字段仍来自完整队头。新增160组三宽、逐条完成退休、复位/flush/物理wrap检查，TB每拍断言两属性视图一致，功能尚未执行。23:24预览源码 manifest a70c58f7b7c695605b103f1100bfa7bd979d847bfbcef1c2623ef32306807050，21项lint/parse全0，未包括后续IQ唤醒位图实验。


23:35：IQ共享调度位图在四IQ组合、实际25路INT/24路FP通知宽度、相同全公开端口的独立OOC中 LUT46693→34555（-12138），FF1411不变、LUTRAM7680不变；内部综合路径6.845ns/17级→7.156ns/18级，外部输入无约束，不能当完整100MHz证明。baseline/prepared parse/synth全0，27文件归档 SHA256 `3d20df8bb5cdecbe318751defdf939ac92aca67c8b50751b6af01b9b91095a5d`。新增160组随机三源域/广播/真实ready/粘性已唤醒状态与同拍无选择旁路检查（默认TB通知宽度改为整系统实际值，旧700/900规模/seed不改），未执行。
LQ载荷单写多读RAM：独立OOC LUT21999→15086（-6913）、FF7693→3277（-4416）、LUTRAM0→984；内部7.150ns/18级→8.022ns/23级，接口/功能未仿真，不代表完整物理时序。两份解析/综合全0，27文件归档 SHA256 `a5f1ffdda7a32bad112adfeaf9284754bc64bc1f13121ac92c10a42c2cb8b03f`。新160组两AGU完整随机载荷、同owner双capture优先、换writer捕获、held重放、HEU交接、物理wrap/reset；旧500/240及L8b保留未执行。
C6选AreaOptimized_high用于资源候选测量；C4同输入结果显示其可节省18002 LUT，但时序更差，必须分别评估。新完整runner等待C5结束，只生成/综合，无opt/place/route/bitstream。


C6初次快照 `soc-threewide-components6-20261011-233558`（845份源码manifest `745efe034ef4df62672172d1af31733f4bad31466d5ada95a581a9bec2205af2`，基线HEAD d834162f7ff1a3e86b43abf270d57df86088ab88+dirty）在issue_queue_storage测试顶层因25/24通知端口扩展后未给内部实例传参而失败；该检查/runner=1，生产RTL解析0，无生产生成/综合。接线修正为显式传WAKEUP_WIDTH/FP_WAKEUP_WIDTH，不改生产功能。23:34预览相同TB错误1、其他20项0，失败记录保留，C6v2将重新快照全部源码。


2026-10-12 00:05 CST：C5 default整系统结束，synth/report/runner/groups全0，1310秒。LUT279029(115.11%)、FF119086、LUTRAM17993、BRAM175.5、DSP27、latch0，WNS-5.220ns/TNS-102033.289/93887 setup端点，最差51级 DTLB VA→物理地址/权限/性能事件→HPM溢出→CSR MIP13。全部组报告在112文件归档，SHA256 `fa3a13de8184cc65e2f43070e0c6b735e2e3bf3d0887102002206c7f79ed7604`，取代100文件初归档 `3e4e3a1dd9b7136c7bc5ad8f36a8e296db94ddf14ed8f7784dfefda9b5a59007`。输入仍源码d7a17af.../152实际a0e2ba06...。资源/时序未闭合，无功能/布局布线结论。
C6v2于C5之后启动AreaOptimized_high，源码845份 `f145e545383f5baba3f0c898b6dcf584f49e96cf17dece31aa1c39015cbb9542`，152实际输入 `159c765c0c7246feadd7596dd92a41841037867c7f79a8b6831a3de381d78aa9`，external[]；26静态+1生产RTL/BIOS生成全0。初83文件生成归档 `fc4d6d0cfc7f82ead5fb15b2c618274e9fdfb56ee167a9859795d59950acead7`，不含综合结果；runner2423129，分组watcher2426299。尚未结束，不能声称组件节省已在整系统兑现。
C7当前RTL增量：SQ捕获载荷RAM已采用（独立OOC20917→15275 LUT，9533→2588FF，LUTRAM0→1512，内部5.132/14级→5.134ns/13级；parse/synth全0，27文件归档 `910dad417e6010f1e1f9a5a9eaa4e7c5e599df29dfa1e2a0ac71b0e74a622036`）。新增160组两路完整随机捕获、同owner双capture优先、held双重放、HEU ordered释放/物理wrap/reset；功能未执行。
MEM：AG/DTLB请求→T翻译结果/异常/priv/need_D→S1权限/SQ forwarding/缓存→S2完成，缓存S0跟随T请求周期，RAM S1数据与T注册物理包对齐，恢复掩码同步推进；不加FSM，增加一拍延迟。结果信用每lane2→8并把count/head/tail窄化到实际容量，覆盖额外在途阶段，旧四请求满队列case保留并扩到真实容量；新增48个连续双路包(96指令)命中/身份/II1检查。FPU仍配置8，ADDMUL按DP7+2实际保证9槽，不需要提高到16。ISA物理地址56/PMP原始54等保持。
00:02预览新增LSU fixture在.*连接缺少先前增加wake_o/bypass_o声明而失败，其他21项全0，生产RTL解析0；补上公开输出接口，失败快照manifest c01a2e4fcd76264fe60ac02eb0dbe946dd74dbea93af612775ea1ea3cba58fac保留。无仿真运行。

### 2026-10-12 00:20：C7生成身份与LSU翻译级OOC

C7目录`build/soc-threewide-components7-20261012-000821`，Alan runner2435376，只读分组watcher2438649。
845文件源码manifest `8732a4f8ea807a626824b7a42b11ff549cc0293df53dffb1cc53057fdcb6064c`；152实际综合输入manifest `24a5aa2c12c540d986399a67eaf013dde38f788b374bb455662469b05f276b7e`，external=[]。
cloud新鲜预检SSH255、Alan0；27项静态/fixture解析加生产BIOS/RTL生成共28项exit0。
生成阶段85文件归档`f5352b39f520edb65b021d4b8f1c785a12dcfc8a41a921a8ad6aac6e0a6ccecd`，不是最终综合证据。完整综合仍等待C6v2，尚无C7资源/时序结果。

LSU完整接口独立OOC在Alan完成，baseline/prepared解析与Vivado均exit0，两个变体均用FIFO8以隔离流水改造：
LUT11762→11241，FF8246→9160，LUTRAM328不变；最差内部数据路径7.327→5.041ns，21→15级，WNS +2.697→+4.877ns。
新T寄存器切断DTLB翻译→permissions/forwarding的组合依赖，不能把OOC内部正时序当成完整系统闭合，也没有功能证明。
28文件完整归档`26439a3f306f5aa7bcdf4544146e3e42fef97f1ba35c365075faea19097efb37`，本地`build/threewide-lsu-translation-prepared/evidence`。

恢复统一包寄存增量22项静态解析exit0，源码manifest823c6a46dcf1f14d4f5ac4447e6ce12598ec534c26a6021df84db77b0b80cd80，build/threewide-components5-preview-20261012-002359。计划进入C8完整独立快照，完整综合必须等待C7。

### 2026-10-12 00:40：C6v2最终结果与下一完整输入准备

C6v2 Alan解析/生产生成27项exit0、完整综合runner/report/groups全部exit0，用时2583秒。
LUT249109/242400（102.77%），Logic228396、Memory20713（distributed20660/SRL53），FF112389，latch0；无no-clock/internal-unconstrained/loop/latch-loop。
最差setup WNS -8.769ns/58级，从BPU t1_train.region_base[13]至uBTB entry0.br_ctr[1]。
完整120文件最终归档`365698bb124a45ef7af1596a29196575c9898a42b3555d6f924849742ab47cd7`（替代103文件初步报告归档c570eb47...）。
其845源码manifest仍`f145e545383f5baba3f0c898b6dcf584f49e96cf17dece31aa1c39015cbb9542`，152实际输入仍`159c765c0c7246feadd7596dd92a41841037867c7f79a8b6831a3de381d78aa9`，external=[]；基底HEAD不代表dirty源码。

C8的28项解析/生产生成exit0；取消后84文件完整生成/取消证据归档`86803d2c1c52e1a120ab2da0f0655e0095aad1edfc1a6abdf561aa12894d8e8f`。
845源码manifest`b7eb199f0213ea292f13a530de2d160abd8b665613c84a16aed7026fdb680590`，152实际输入`7cc3e897e75e59a575f5ba87478e503acd5f59dc4f8ed75a4ac1f555580e9399`。C7/C8均无Vivado完整综合，不作为资源/时序证据。

预约窗口修正预览24静态项exit0（3拍与旧2拍DCache fixture均覆盖），源码manifest`9975931a55565890b73242e231cc9d2e1e90bf052f1919f650b39e833e642040`。
加入uBTB两级训练/target RAM后25项exit0，845源码manifest`10023d608a1366a0a04313f0234c85e84bd5ee97934426c408ff566d7d144af1`，build/threewide-components5-preview-20261012-003657。
uBTB独立OOC首轮脚本将clk_i误写成clk，baseline综合完成但create_clock失败，runner1，未得到报告；已修正时钟端口并在v2独立目录重跑，生产RTL不受此脚本错误影响。
训练T0选行/旧值捕获→T1owner/方向/mask更新，pending窄tag/valid/RR计划与前一写完整旧值前递覆盖相邻事务，目标地址用query/train两份单写RAM，query仍组合。原600seed/定向/NT不分配golden保持，仅训练应用延后一拍；增加1000连续同址/满表/别名检查，功能未运行。
