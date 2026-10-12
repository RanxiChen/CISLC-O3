2026-10-12 09:05 C19整系统结果完成并拒绝合入：Alan/chen-System-Product-Name，Vivado2022.2/AreaOptimized_high/retiming0/100MHz，07:57:00→08:35:23 CST，synth与runner0；只读35组路径分析08:35:39→08:40:39、groups0。全部41项exit文件均0，含原38静态/BIOS-RTL生成与三个综合/runner/groups项。源854文件manifest2b9a9ca7e92ad5409965d86767fa2d2be9c6ad4cdc4ab3ed34fb67afd3173481，实际153输入ed8c7f3e859b8c66d4ee87eb468b0c672adbdc82d0c05b7e08d6bdee8a21edf9；base d834162f7ff1a3e86b43abf270d57df86088ab88，子模块HEAD同C18。最终161文件归档7ba15e43188403977223f1df8cfc1413573db21ae846bba74e5ebd95fbe10a51，证据build/soc-threewide-storage19-20261012-075601/evidence与final-review.json。
C18→C19 LUT237709→242792(+5083，100.16%，超容量392)，FF103220→101828(−1392)，BRAM274.5→303(+28.5)，DSP27不变；综合估算WNS−2.662→−3.769ns(恶化1.107)，最差逻辑40→44级，TNS−15657.364、12912/466811 setup失败；WHS−.252/THS−1052.953、41613 hold失败。最差DCache probe snp_q[addr][2]→CSR mip_sw_q[13]。这轮是综合资源/时序回退，不作优化成功或可布线验收。未做opt/place/route/bitstream/板测、全核心功能证明。
分模块IFU9557对9597仅−40LUT、4093→2346FF、增加28.5BRAM；HPM7451→8857(+1406)，包含HPM的CSR整体18512→18771(+259)。其他模块也发生映射变化，不能把整系统+5083归咎于一个模块，不能把HPM孤立−294当作集成收益。IFU与HPM组合不合入；生产两文件SHA仍5de85a22da3adcf76ba1bfa844060120d7d0b0c6a5d8b80fd07a342ce3c84508/a467f79b29e932a587985cef7301c39e65566f69984efcb52e1ead43776e4de3。保持C18结构和此前已验证字段精简，三宽/FU/PRF/队列/cache/HPM数量不变；禁止双写SRAM、器件专用功能原语。后续需继续评估可移植的控制逻辑分级与数据选择，当前不少于三发射可用核心目标尚未达成。

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

2026-10-12 00:40当前：C6v2 AreaOptimized_high完整综合/runner/groups均0，2583秒，LUT249109/242400(102.77%)、FF112389、WNS-8.769ns/58级(BPU训练→uBTB br_ctr)，仍不满足目标；120文件最终归档365698bb124a45ef7af1596a29196575c9898a42b3555d6f924849742ab47cd7。源码f145e545.../实际152输入159c765c...保持原固定快照，不能用后续代码冒认结果。
C7/C8均生产生成/解析成功后主动取消runner143，Vivado未开始，理由是新增MEM T级必须同步修正cache预约2→3拍。C8生成/取消84文件归档86803d2c1c52e1a120ab2da0f0655e0095aad1edfc1a6abdf561aa12894d8e8f。
C9准备：SQ RAM+MEM翻译T/FIFO8+三拍cache预约+统一恢复包寄存+uBTB T0选行/T1更新/target RAM；整体三宽与FU/读写带宽不再削减。25项最新静态解析全部0，845源码manifest10023d608a1366a0a04313f0234c85e84bd5ee97934426c408ff566d7d144af1。uBTB OOC首轮时钟名错误runner1，修正clk_i后v2重跑。无功能/opt/P&R/bitstream/板测。

2026-10-12 00:30：C7/C8在生产生成完成后、Vivado未开始前主动取消（runner143）；LSU新增T级将RR→cache S0从2拍改成3拍，因此DCache内部/line reservation也必须增加一拍，旧快照仅保留静态/生成证据。当前CFG.lsu.cache_s0_delay=3，LSU elaboration断言一致；DCache line/internal packets、probe保护/安装ID/bank/PS下一拍冲突均跟随预留末级，不增加FSM。普通CPU lane仍每拍预约，内部事务仅增加固定延迟。原DCache数据/golden/seed/规模保留，预约驱动按实际配置推进，新增800周期CPU双路+PTW/probe交错身份/成功数据/实际容量检查。当前正在解析3拍与旧2拍DCache fixture；功能后置。C9将包含全部SQ、LSU、恢复边界与预留校正。

2026-10-12 00:25恢复统一注册增量预览：22项静态/完整SoC/fixture解析exit0，845源码manifest823c6a46dcf1f14d4f5ac4447e6ce12598ec534c26a6021df84db77b0b80cd80。目录build/threewide-components5-preview-20261012-002359。无功能证明。

2026-10-12 00:25 最新恢复增量：所有提交重定向包均通过recovery_boundary寄存发送，不再让C2 trap target旁路读取提交组合包。C0接受→C1取消/CSR更新→C2目标捕获→C3完整目标送前端；trap transport busy与recovery pending连续持有精确边界，不新增FSM，不影响普通发射/退休吞吐。旧500周期seed/完整包随机检查保留并按授权新延迟更新，新增160组实际trap_ctrl+dispatcher身份/目标冻结/连续busy/复位检查。功能未运行，待当前静态解析与后续完整综合；C7固定输入不含此增量。

2026-10-12 00:20 CST：C7生产BIOS/RTL生成与27项静态解析共28项exit0，Alan runner2435376，AreaOptimized_high完整综合等待C6v2结束。845源码manifest8732a4f8ea807a626824b7a42b11ff549cc0293df53dffb1cc53057fdcb6064c；152实际输入24a5aa2c12c540d986399a67eaf013dde38f788b374bb455662469b05f276b7e，external=[]。生成阶段85文件归档f5352b39f520edb65b021d4b8f1c785a12dcfc8a41a921a8ad6aac6e0a6ccecd；非完整综合证据。
LSU翻译T级完整接口OOC（两个变体均FIFO8）：LUT11762→11241、FF8246→9160、RAM328不变，内部路径7.327ns/21级→5.041ns/15级，解析/综合均0；28文件归档26439a3f306f5aa7bcdf4544146e3e42fef97f1ba35c365075faea19097efb37。无功能/完整系统收益结论。

2026-10-12 00:08 CST：C5完整综合default已结束，LUT279029/242400(115.11%)、FF119086、WNS-5.220ns/51级（DTLB VA→HPM溢出→MIP13），全runner/report/groups=0，1310秒；112文件最终归档fa3a13de8184cc65e2f43070e0c6b735e2e3bf3d0887102002206c7f79ed7604，资源/时序未闭合。C6v2 AreaOptimized_high仍运行，845源码f145e545...，152实际输入159c765c...，27静态/生成全0，无完整结果。
后续C7增量：SQ捕获载荷RAM；MEM增加翻译结果T级并对齐缓存S0/S1与queue身份；每lane结果信用2→8/指针和计数窄化以覆盖额外在途周期。两个MEM口和三宽/ALU2/MUL1/DIV1/FMA1等保持，未加FSM，FPU仍base8/FMA min9。LSU/SQ新增完整载荷复用、流水身份、连续双路包和真实满队列检查，原seed/规模保留且只追加；00:05预览22lint/parse全0，源码manifest6f0e33d471db9b7e07c5d07243b05552a0e36713562e78bce81ca795cd327d74。功能尚未执行，无opt/place/route/bitstream/板级证据。C7完整runner将等待C6v2结束，禁止本任务两个整系统综合同时运行。

2026-10-11 23:37 CST 最新：目标仍为KCU105不少于三发射、三宽优先，当前仅整系统综合阶段，无功能/布局布线/bitstream/板级结论。C4同输入AreaOptimized_high策略LUT262123(108.14%)、FF126119、WNS-9.104ns/60级，runner0，仍超资源且时序负；完整报告21文件归档4ae3d4a031e44b7bccbdaf05516146bf6e1ecb975144bdedcc9933a718a0e72e。C5默认策略已于23:26接续整系统综合（源码d7a17af.../152输入a0e2ba06...、23静态/生成项0），未结束。
C6增量包括C5之后FU buffer/L2/Decode Queue RAM布局、PMP局部原始位比较、ROB CSR/SFENCE窄预解码、IQ共享调度位图、LQ捕获载荷RAM。四IQ实际广播宽度组合OOC节省12138 LUT，LQ OOC节省6913 LUT/4416 FF；这些不能直接相加成完整系统结论，功能仍后置。容量/FU/≥3宽不再削减。C6首次源码745efe034ef4df62672172d1af31733f4bad31466d5ada95a581a9bec2205af2，在测试顶层25/24通知参数漏传而解析失败runner1；未生成生产RTL/未综合。接线已修正，准备C6v2快照，待C5结束再使用AreaOptimized_high测量完整系统。所有旧证据/规模/种子保留。

# CISLC-O3 闭环阶梯与实现状态

本文件是**项目当前状态的唯一权威来源**。规则见 [`agent.md`](../agent.md)，
微架构决策见 [`design/`](design/)。

更新规则：任何改变模块状态或闭环进度的提交，必须同步更新本文件对应的行。
"状态"一栏只描述事实，验证一栏只写有证据的结论（见 agent.md 第 3.3 节）。

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

### 2026-10-11 当前工作：后端流水重构与整系统综合

用户确认最终目标：KCU105 上可实现且整体不少于三发射的乱序核心，优先四宽，不能以两宽收尾。
本轮先做综合诊断；最终物理时序/功能闭合不能由综合估算替代。
第二四宽完整综合exit0：LUT298222（123.03%）、FF140406，WNS -13.127ns/82级DCache→CSR，仍超限。
按用户顺序当前默认转为整体三宽，容量/FU/端口沿用第二四宽候选，ROB32/DecodeQ8物理bank仍为四。
当前已写逻辑流水：FU buffer → A0四槽独立元数据保留项 → A1年龄优先级 → A2授权/地址描述符 →
各FU三槽操作数捕获 → RegRead/FU请求。A1每拍推进，被拒绝项释放本次调度占位后留在A0重试。
分配采用并行前缀预算，并预留每路捕获容量（计入授权在途项）；FU等待不再占共享读地址。
三路INT/BR、单FMA连续吞吐、慢DIV隔离、操作数/所有权/取消/随机背压测试已更新但未运行。
旧逻辑分级第一原型 `soc-fourwide-pipe1-20261011-190618` 的lint/整SoC解析/测试顶层解析exit0，
没有该原型的综合或功能结论，不能覆盖当前三宽重写。
三宽首轮被平台旧“四宽退休”断言拦截，已修复3～4宽一致性检查；
重测 `soc-threewide-pipe2v2-20261011-192719` 的lint/整SoC与测试顶层解析/生产SoC及BIOS生成/综合/只读分组均exit0。
该综合快照之后本地继续新增CSR队头请求捕获→架构CSR执行分级；在途CSR持有精确队头并延后IRQ，
以及HPM窄增量/并行上部进位。请求级不新增FSM，普通三宽退休通路不插入等待级。
CSR/HPM后续修改已在独立preview整SoC解析exit0，尚无对应整SoC综合/功能证明。
2026-10-11 20:05取得三宽pipe2v2资源报告：LUT296394（122.27%）、FF150564、latch0，仍超限；
主任务/综合/只读分组exit0；WNS -10.606ns/73级DCache→CSR，依然未满足100MHz综合估算时序。
按用户顺序已进入组件重实现：FP1W RAM、完成队列固定payload槽、LSU结果RAM、LQ直接三条退休位置保护、
读调度窄描述符与固定操作数捕获槽。A0四槽保留完整元数据直到PRF读取，A1/A2只存身份/地址/预算字段。
ready-table A/B无面积收益，默认保持原实现。
组件首轮 `soc-threewide-components1-20261011-200659` 的lint/整SoC及操作数测试解析/生产SoC及BIOS生成/综合报告exit0：LUT286230（118.08%）、FF144484、WNS -11.647ns/67级LQ→LSU replay，仍未闭合。
启动后又修free-list在64-entry配置下把上界64截为6位0而丢失正常release的问题；未覆盖于该快照，
需要后续准确源码重测，不因当前综合成功就宣称此代码功能可用。
独立prepared整SoC解析exit0；当前新增断言、测试/接线更新
需新完整快照综合复验。之后本地已应用显式多写PRF银行、FMA最少9身份槽与trap请求/CSR更新/redirect逻辑分级。
静态 `threewide-components2-preview-20261011-203148` source-manifest
`3e9a9e52e946f7f69dba38fe0c5d50cdfb341becef9522098fff4d9681e29982`：14项解析exit0，
包含整SoC、trap/FPU/operand/commit/HPM/free-list/LQ、PRF FPGA默认/6R3W/generic、completion2/8和前端RAM候选overlay。
此前preview错误引用FPU tag不存在的字段，失败日志保留；现按公开ROB身份宽度映射原测试编号，保持向量/golden/规模。
该preview后新增IRQ候选采样、SQ replay oldest-two平衡树、容量对应位宽的R2/Dispatch/FU预算，并采用独立OOC有LUT收益的RQ RAM。
IFU queue RAM候选增加LUT，未采用。上述较晚改动需新整系统复验。
当前完整快照 `soc-threewide-components2-20261011-204632` 在 Alan 执行：817文件源码manifest
`0bb31d49c93c1d35c0c3436688af92a60fd2f40288f2d4ba83d186aec2a50c68`；
整SoC/lint/操作数及11个相关测试顶层解析、生产BIOS/RTL生成全部exit0，综合仍运行。
生成的150个实际综合输入manifest `a2fc958815ef43246401c8622b11be96090e362a9330c5bfdf89299d55564aa9`，没有快照外源码。
该轮覆盖上述较晚IRQ/SQ/RQ/预算改动，不包含后续操作数载荷存储候选。
组件首轮只读分组有效：A0 -3.358ns/40级、A1 -4.045/42、A2 -5.388/45、捕获 -10.641/64；
这些包含取消/控制路径，不能当作孤立算术延迟。组件首轮最终73文件证据archive
`441d89eb2e75912fe71e4e248eb2a5b9d975039a762a81227e22153299048c95`。
第二轮启动后新增默认改造：操作数A0/捕获载荷改成显式位向量单写RAM，元数据/分支mask独立；
独立完整接口OOC LUT36323→25955、FF52987→2011、LUTRAM12496，功能未验证。
HPM恢复原生counter加法链、OF单独由窄event进位与高位全1决定；同拍读写/计数合同不变，
独立OOC LUT2811→2580、FF1184保持。
新增恢复应用级：C0仅精确接受并挡退休/新HEU与ITLB PTW入场；C1寄存global cancel/committed-map恢复；
非trap同步重取同C1发出，trap请求原有C1 CSR更新/C2 target保持。C0允许年轻推测进度，C1统一取消。
普通retire/issue不经过该事件流水，不新增FSM；新恢复模块500周期测试、SQ40批六项重放测试已写未运行。
第三轮完整 `soc-threewide-components3-20261011-212509-20261011-211940`：823文件source-manifest
`2bae52f60c6e4b08181917a9ba4e90d252237fd13e981382989dcf78f738d0b5`。
16项lint/解析/生产生成exit0，Vivado已在Alan启动；不覆盖前两轮快照。
第二轮完整综合exit0、LUT285294（117.70%）、FF143734、latch0、BRAM175.5、DSP27；
WNS -8.249ns/53级DCache→CSR mip，仍超资源与时序。77文件初次archive
`9cf5db001fbf6041e3b19906a3694587b6a08a3088e7a6630924e0698b9b67d9`，分组诊断另在运行。
第三轮snapshot之后仅SQ测试适配三宽分批入队/退休，原80批四条规模保留；尚未重新解析或运行。
功能吞吐、取消、精确CSR/中断和访存保护仍待后端重构后验证；14个exit0只证明静态解析。

第四轮准备：RDQ与四类IQ的不可变载荷改为按入队writer分银行、按reader复制的RAM，
每个物理槽仅保存最新writer选择和可变mask/就绪元数据；原选择/所有权/取消/接受边沿保持。
ROB把初始异常/后继PC放进分配RAM，晚到更新用独立单写RAM和逐槽选择标志，保留同拍晚更新优先级。
完整接口独立OOC资源对比均exit0：RDQ LUT9991→5890；INT IQ11924→9270；FP11034→7442；
MEM11361→7357；BR4824→3389；ROB21578→10674。不能相加后当作整系统收益。
新增RDQ/IQ各700周期完整载荷模型、ROB80批取消复用及80批正常退休环绕测试，尚未执行。
ROB新测试wrapper第一次解析因unpacked array三元端口表达式报错，保留失败；改为逐lane显式连接，待重测。
第三轮完整综合/报告/runner exit0，1999秒；LUT294923（121.67%）、FF139521、LUTRAM11440、latch0；
100MHz综合估算WNS -5.828ns/58级，PLIC threshold→HPM counter，仍不满足资源/时序。
该快照不包含第四轮RDQ/IQ/ROB存储改造。151实际输入manifest
`b64b7a5bfadf6f84473c0b4f96300e945d7106517447880cd09838511a9ab5f8`，外部源码为空；
98文件证据archive `504378ec69f4bbdf509e73a57e0740fe259aba83bb4707970f8398b530a500a3`。
第二轮最终含分组95文件archive `38ed8d05db038423e16e480c5727a1f30fec4fa7460aeabecff697af4f508414`。
新增可选AreaOptimized_high综合指令实验入口，默认保持LiteX原指令，未运行完整面积实验；
已核对Alan安装的Vivado帮助，生成Tcl仍严格停在synthesis，未添加opt/place/route/bitstream。

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

用户新增重构约束：整核按逻辑职责分级，允许增加延迟，新增流水级不得降低既定资源下的稳态吞吐；
除非必要不新增状态机，现有可重叠推进的状态机改为流水。必要串行控制须逐项说明真实依赖与接受间隔；
逐事务状态/流水 valid 保留，不以改名冒充流水化。候选选择、优先级、读口分配、RegRead、执行与完成的
边界及反压缓冲继续审查，特别处理 A1 整包排空和同拍补入反馈；具体级数尚未冻结。
此为已确认约束，状态机迁移与新增流水尚未完成；功能回归仍后置，连续吞吐也尚未验证。

按用户本轮授权推进 RTL，功能回归暂缓。四宽 Rename 已拆 R1 依赖预处理与 R2 原子分配；
整系统基线 INT 配置四 ALU/一流水 MUL/一迭代 DIV，INT IQ 选择宽度独立为四。
第一削减候选为三 ALU/一 FMA；第二四宽候选为两 ALU/一 FMA，现转三宽，见上述当前结构与下述历史证据。
INT/FP 各 FU、双 MEM lane 和 BR 使用双槽读前 buffer；容量只依赖寄存占用。
第二四宽历史候选为 buffer → A0 请求寄存器 → A1 授权/地址寄存器 → 独立一拍 RegRead → FU。
仲裁改为并行循环 ROB 年龄排名与窄端口预算分配；A1 可部分排空，全部排空后替换包。
基线两个 FMA（后续候选一个）的算术流水为 SP5/DP7，与当前 Breeze CVFPU 版本一致。
所有上述 FU 与成功普通 load 提供完成捕获前的调度通知；真实读前检查不接受通知作为数据，
只接受 PRF ready/真实写回/live 完成头 bypass。历史四宽基线退休总共最多四条；当前默认总退休三条。

已完成的首版快照以 `backend_ooc_wrapper` 为顶层在 Alan 做 KU040/10ns 综合，包含 backend 实际连接的
执行/LSU/L1D/DTLB/PTW/CSR，排除前端与 L2；该次没有整核综合、布局布线或仿真。
用户随后授权整系统 KCU105 标准版综合：前端/后端/L1I/L1D/L2/DDR/CLINT/PLIC/UART/SD一致性DMA与生产BIOS；
不做布局布线/bitstream/功能回归。宽度策略为先维持 Decode/Rename/Dispatch/总退休四宽，
综合后削减容量及FU数量；四宽削减仍不够才转三宽，三宽仍不够再重做组件。
第一四宽削减快照 `soc-fourwide-trim1-20261011-175440`：ALU3/FMA1、ROB32/INTpreg80/checkpoint8/L1D16KiB4way、
INT6R/3W与FP8R/2W。Alan解析/生成/综合各exit0，LUT432321（178.35%）、FF189446、
100MHz综合估算WNS -17.457ns/77级，仍超资源且未满足时序；详见报告。
第二候选四宽历史配置：ALU2/FMA1、ROB32、INT/FPpreg64、checkpoint4、RDQ8、IQ8/8/4/8，
INT4R/2W、FP5R/1W（单组三源FP+双MEM store读口），双MEM/LSQ16及FMA tags8/SP5/DP7保持。
DecodeQ8/ibuf16/FTQ16、BTB256×2、TAGE512行/表与base1024、L2 128KiB4way/slots4；L1I/L1D16KiB。
读口布局/测试模型已按配置推导，第二候选隔离preview在Alan整核与测试顶层解析exit0；
默认RTL已应用，独立完整快照 `soc-fourwide-trim2-20261011-184106` 的整核/测试顶层解析与标准SoC生成exit0，
完整综合/报告exit0（1660秒），LUT298222、FF140406、WNS -13.127ns/82级；不能套用为当前三宽结果。功能测试未执行。
使用未提交工作区源码快照与逐文件 SHA256，不把基底提交 SHA 当成本次修改的 SHA。
当前报告与证据范围见 [后端重构 OOC 报告](tasks/O3-backend-refactor-ooc-report.md)。
Alan后端综合与只读分组诊断均退出0；综合LUT380,730（KU040预算157.07%），
10ns约束下WNS -159.300ns，最差内部路径512级，主体为共享读口串行仲裁及其向IQ传播的容量链。
DRC有3项LUT资源超量错误；无组合环、无无时钟/未约束内部端点。
这些是未布局布线的综合证据，不代表功能验证或可实现；后续优化建议与公开实现调研已记入报告。
512级/资源数字只属于首版快照，不能冒充新增A0/A1和并行仲裁的结果。
新增流水的完整标准SoC基线 `soc-fourwide-20261011-164836` 综合/报告exit0：
LUT506389（208.91%）、FF211422、RAMB36=231/RAMB18=40、DSP38、latch0；
100MHz综合估算WNS -21.941ns，最差内部93级DCache→BR读前buffer控制路径。
DRC仍有3项LUT超量错误，无无时钟/未约束内部端点/组合环/latch环。
基线包含全部标准SoC，且采用削减前的四ALU/双FMA/ROB64等配置；不是当前削减候选或布局布线结果。
以下旧 SHA 的 PASS 都是历史证据，不能覆盖这次重构。新流水行为尚未功能验证。

## 1. 闭环阶梯

每一级是一条能在共享配置所选仿真主机上验收的端到端路径。历史Alan证据保留；当前主机选择见 `/home/chen/leisure/flow/docs/cross-project/simulation-host.md`。用户已决定移除 ITCM，
先打通 ICache→inclusive L2→AXI 取指，再推进分支与数据路径；以下按当前顺序记账。

当前顺序与验收策略以 [`O3-v1-plan.md`](O3-v1-plan.md) 的 2026-10-06 决定为准：L7 → L9 → L10 → L8 → L11；Spike/ACT4 与完整一致性测试推迟到 FPGA，L11 前不综合。

| 级 | 目标 | 验收 | 状态 |
|---|---|---|---|
| L0 | RTL 可解析、`o3_core` 可展开 | `scripts/lint.sh` | Alan PASS（`de9149d`，0 errors、227 warnings） |
| L1（历史） | ITCM 中的直线整数指令按序退休 | 旧 `sim/o3` smoke | Alan 曾 PASS（`a268f16`）；ITCM 已移除，旧验收不再运行 |
| **L4 当前** | **ICache miss → inclusive L2 → AXI RAM → 直线整数退休** | `make -C sim/o3 build && make -C sim/o3 run-smoke` | Alan 回归 PASS（`de9149d`，38 周期、4 条退休、ICache 回填 1 次） |
| **L2 当前** | **taken 分支 / JAL：BRU 解析 → 重定向 → 前端恢复** | `make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1 && make -C sim/o3 run-rv64i-instructions` | Alan PASS（`de9149d`；局部 1/1；整核 76 周期、14 条退休、ICache 回填 2 次） |
| L3 部分闭合 | SQ 依赖/转发 → 流水化 DCache → inclusive L2 → AXI 数据访存与退休 | `make -C sim/cocotb/store_queue SIM=verilator`、`make -C sim/cocotb/dcache SIM=verilator`、`make -C sim/cocotb/backend_issue_queue SIM=verilator`、`make -C sim/cocotb/load_store_unit SIM=verilator`、`make -C sim/o3 run-dcache-data run-dcache-replay` | Alan `a8b3fc6`：Memory IQ 1/1、LSU replay/恢复 2/2；整核 `7d59822` 新门禁实测 `load_replays=1`，71 周期退休 6 条且轨迹 PASS；旧 smoke/分支/数据门禁仍 PASS。SQ 3/3、DCache 3/3 沿用前次 Alan 证据。本行是历史L3证据；多MSHR/load pending与FENCE.I已在L8a验收，B49跨行拆分、AMO/DMA仍未验收；PTW/A-D已在L10接入；不是完整 B03～B05 |
| L3 收尾 | 完成 L3；修 B12 缺口 1（分支解析全局停顿）与缺口 2（ALU RegRead 背压时缺 kill）；重命名改 4 宽（B42）；移除当前级不需要的空壳实例（B46） | 现有 L2/L3 门禁 + 分支密集程序 + 缺口 2 定向测试 | 阶段二实现与验收通过：四宽/16 项、空壳/filelist 清理、U3/U4、缺口 1 与授权 LQ-M；缺口 2 具名/随机/真实仲裁测试通过。Alan `ac2aed1` 全部门禁与 seed 1/7/29 通过，`1b7885d` 补充 LQ-M 通过；分支密集 1967 周期/365 退休，前后差值 0。同最终交付 SHA 的复验以 [报告 §9](tasks/O3-T01-report.md) 的 final 目录为准 |
| L5 | Spike 逐条比对；M 模式 CSR、精确异常、ecall/ebreak/illegal、MRET、committed_next_pc | 按 2026-10-06 用户策略带已知问题收口 | **已知问题退出**：Alan `2cc8a91` build、固定 11/11、新增局部 5/5、riscv-tests 5/5 PASS；随机 178/200（14 rd_wdata、8 mem_kind 失败）；M 模式 84 退休后 MRET timeout；ACT4 M 模式 Sail 签名 trap loop 暂不处理。根因未定位项留待上板抓波形，停止 T03 bug 修复，详见 [T03 报告](tasks/O3-T03-report.md) |
| L6 | M 扩展（MUL 采用 DSP，B43）、完成 FIFO/提前唤醒、JALR；首次 OOC 综合 | 按 2026-10-06 策略：定向 cocotb + lint + 整核短程序 + OOC | 机制及简化功能验证收口：Alan 定向 6/6、lint PASS、整核 297 周期 / 71 条退休 / Spike 0 差异。整核 OOC 812 秒后崩溃，整核 PPA 未取得；局部 MUL/DIV OOC PASS，MUL 16 DSP，见 [T04 报告](tasks/O3-T04-report.md) |
| O3-T04b（L7 前） | 整核 BRAM 映射与 OOC 资源/时序基线；不改机制 | 每个 cache 现有 cocotb + 整核 smoke；整核 OOC 耗时/资源/WNS/最差路径 | **定位报告已提交，改造暂停**：同步 BRAM 与 L1D 接纳前 tag 判定、L2 握手当拍写回 error 存在逐拍合同冲突；用户要求保持接口时序，先提交定位报告。另发现原 OOC 的 DTCM 2 Mbit RAM 推断硬错误；整核基线仍未取得，见 [T04b 报告](tasks/O3-T04b-report.md) |
| L7a | uBTB/BTB/TAGE、FTQ 恢复、RAS、F1 预解码修正与 M-mode HPM | 冻结 spec 与 T05 分步门禁 | **实现与定向功能验收完成**：T05c/d `cbe3372`，Alan cocotb 68/68、四源恢复与两组 l7_predict 正确性/性能 PASS，lint 与整核构建 PASS，见 [T05cd 报告](tasks/O3-T05cd-report.md) |
| L7b | 整数 RVC、跨块 edge 指令与 IALIGN=16 | V1～V8 冻结；T06a→T06b 门禁 | **实现与定向功能验收完成**：spec `01c939a`，T06a `2614064`、T06b `2b50184`；Alan 70/70、77/77 cocotb，四个整核回归与 l7b_rvc 自查 PASS；不含 Spike/ACT4/FPGA，见 [T06 报告](tasks/O3-T06-report.md) |
| L7c | 前端重构：8 项返回队列、FTQ 早释放与训练流水、主 BTB/TAGE 双副本 BRAM、FDIP 预取、loop predictor、特性开关 CSR、性能事件补全 | O3-T12 W1～W12 冻结；T12a→T12b→T12c→T12d 门禁（spec 第 14 节） | **实现与同SHA功能/性能门禁通过**：`c522369`，cloud_chen 58个默认目录251/251、含种子/附加配置453/453（无skip）、原13/12项整核及L7c ON/OFF通过，lint0 errors/357 warnings；loop误预测45→12，冷流3587→2539 cycles，训练stall0；PMP局部综合原端点+2.290ns，L7c/整核布线未证明。见[T12全阶段报告](tasks/O3-T12-report.md)与[最终证据](tasks/O3-T12d-evidence.json)；DMA吞吐回退已登记，L11a未开始 |
| L8a | 非阻塞L1D/L2、四MSHR、双访存管道、事件唤醒、STA RFO、公开PTE协议、FENCE.I | O3-T09 M1～M6及spec12.8；截止前缀按用户批准解释严格比较 | **L8a实现与分层功能验收完成**：cloud_chen，同SHA门禁与周期/统计见 [T09报告](tasks/O3-T09-report.md)；L8b见下一行，L8c未开始，跨行、AMO、MMIO、DMA、litmus、综合/FPGA不在此证据范围 |
| L8b | AMO/LR/SC、MMIO、跨行/跨页拆分、一致性DMA与load顺序重取 | O3-T10 N1–N6及spec12.8 | **N1–N6分层验收通过**（cloud_chen）；最终收尾提交同SHA总门禁结论以T10报告规定的acceptance.json中passed=true生效；详见 [T10报告](tasks/O3-T10-report.md)。Y11/B36与MMIO中断退休问题已修复；不含SoC/FPGA |
| RAM/OOC 修复 | L2 directory、L1D tag/data 映射与 TAGE 综合；busy→LSU→IQ 时序 | 受影响回归与 Alan OOC | 按用户要求暂停；受影响功能回归通过，L2 setup +1.709ns，L1D setup -0.073ns；整核OOC已停止，busy→IQ尚未测到，详见 [修复报告](tasks/O3-memory-ram-ooc-report.md) |
| L8c | 推测load越过地址未知的更老store | 待冻结任务与门禁 | 未开始 |
| L9 | F/D：拆分 CVFPU、FP 重命名、fflags/FS 退休、浮点访存/RVC | T07 定向 cocotb + 整核 FP 自查 + 回归；ACT4 推迟到 FPGA | **单槽 replay 等待环修复，本次指定门禁通过；完整合同验收未完成**（`f0f4106`）：Alan Memory IQ 2/2、整数 replay 自查 121 周期/20 退休、完整 FP 自查 1860 周期/616 退休（另 1 trap）、顺序 FP 与既有五项回归 PASS，lint 0 errors；历史T07采用load按序发射；L8a已改为双发射事件重放，见T09报告；历史证据见 [T07 报告](tasks/O3-T07-report.md) |
| L10 带已知问题收口 | S/U、Sv39 MMU、SFENCE.VMA/satp/PMP、A/D、WFI | T08a→b→c 定向门禁；2026-10-07 用户修订 | T08a `8610b9a`、T08b `2e5333b` 已通过指定既有门禁；T08c `1d0d6f8` 已接入队头 D/CAS/年轻访存排序，Alan 同 SHA 38套件132/132、八项既有整核回归、T08a 全部与 AD 正向程序通过，lint 0 errors。完整 VM 在 cause 15 / PC 0x800001c4 的旧分支断言失败保留，详见 [T08 报告](tasks/O3-T08-report.md)。X2：TLB hit-under-miss/单 miss 槽/单 PTW；X8：SFENCE 先等 SQ 写完成再 PTW idle。L10历史收尾；L8a当前状态见L8a行，L11未开始 |
| L11 | 首版完整 SoC（LiteX，B52）：O3+L1/L2、DDR4、ROM/SRAM、CLINT/PLIC/UART、LiteSDCard+一致性DMA；后续FASE/perf | 用户授权Alan BIOS/Vivado与cloud回归并行；验证提交78db957 | **功能门禁通过，FPGA待结果**：同提交模块461/461、平台补充6/6、整核27目标、SoC S1/S2与断言通过，lint0 errors；CSR/PMA同源、IRQ及MMIO lane修复，Alan BIOS已编译。生产Vivado在运行、调试排队；SD实卡/Linux/物理DDR/上板未验收。见[T11a报告](tasks/O3-T11a-report.md)及[功能证据](tasks/O3-T11a-functional-evidence.json) |

## 2. L4 缓存取指闭环（历史范围；L7a/L7b 已完成定向验收）

### 2.1 范围

- 镜像装入 AXI RAM（`0x8000_0000`）；复位 PC 从该地址开始。
- 顺序取指经过 ICache miss、L2 miss、AXI 四拍回填，再交给后端退休。
- L2 的同组容量替换须先 recall L1I 并 probe L1D；脏副本先写回 AXI。
- 本节描述 L4 取指门禁的历史范围；彼时 L1D 只能应答空副本探测。此后
  L3 已接入基础有效数据行与 load/store，见上表，不能把 L4 通过当成 L3 证据。

### 2.2 验收

```sh
make -C sim/o3 build
make -C sim/o3 run-smoke
```

通过条件：按序退休 4 条指令，PC 依次为 `0x8000_0000/04/08/0c`，
`x1..x4` 写回值依次为 `1/2/3/4`，至少一次 ICache 回填，无超时。

Alan 在 `1d2caeb` 上输出 `icache_refills=1`、`PASS cycles=38 retired=4`、
`RV64I_INSTRUCTION_TRACE_PASS retires=4`。
Alan 在 `de9149d` 上重建并回归得到相同的 38 周期、4 条退休和 1 次回填。
Alan 的持久环境和重建方法见 [`sim/alan-env.yml`](../sim/alan-env.yml) 与
[`sim/o3/README.md`](../sim/o3/README.md)。

### 2.3 L2 直接控制流恢复验收

顺序预测器下，taken BEQ 和 direct JAL 由 BRU 产生带 FTQ 身份的解析结果；
重定向器在 R0 杀掉年轻项并改写取指 PC，在 R1 等待历史/RAS 的同身份恢复完成，
再允许 R2 重新分配。执行重定向会清空尚未交付的 fetch buffer 项；已经发出的
错路缓存请求可完成，但其返回不会进入退休轨迹。

```sh
make -C sim/cocotb/branch_recovery SIM=verilator TEST_SEED=1
make -C sim/o3 run-rv64i-instructions
```

Alan 在 `de9149d` 上局部测试 1/1 PASS（150 ns）；整核输出
`icache_refills=2`、`PASS cycles=76 retired=14`、
`RV64I_INSTRUCTION_TRACE_PASS retires=14`。退休轨迹包含 taken BEQ 与 direct JAL，
并排除两条错路 `addi`。上述历史 SHA 采用顺序预测与每次分支解析保守暂停一拍；O3-T01 已解除 C 拍暂停，M 恢复不变；
JALR、RVC 和 predecode/slow/system 多来源重定向不在本级范围。

### 2.4 缓存取指路径与模块状态

信号流向：

```
AXI RAM 镜像（TB 经 axi_init_* 预装）
  → bpu（预测 PC、分配 FTQ）
  → ftq（demand 发射，携带 ftq_id / rq_idx）
  → icache（双 bank 四拍查找，miss 发 L2）
  → l2_cache（组相联/PLRU，miss 发 AXI，包含关系回收）
  → ICache 回填（四个 16B beat，带身份的 icache_resp_t）
  → fetch_return_queue（按序出队）
  → ifu_f0（长度识别）→ ifu_f1（生成 fetch_entry_t）
  → fetch_buffer → backend（旧数据流：decode → rename → IQ → ALU → ROB）
  → retire_info_o → sim/o3 退休轨迹
```

| 模块 | 状态 | 后续工作 | 测试 |
|---|---|---|---|
| `frontend/bpu.sv` | **闭环简化（L7b）**：快/慢预测、history/RAS 快照、训练；真实长度/edge 与返回地址 | BRAM 映射留后级 | Alan BPU 5/5 PASS，见 T06 报告 |
| `frontend/bpu_slow_check.sv` | **闭环简化（L7b）**：候选排序、缺目标、快慢覆盖；核对长度/edge、真实历史/RAS 地址 | 完整 ISA 一致性留后级 | Alan 1/1 PASS，含字段比较定向向量 |
| `frontend/ftq.sv` | **闭环简化（L7b）**：实际长度/edge 训练；年轻区域任意提交关闭更老空区域 | 完整一致性留后级 | Alan FTQ fixture 3/3 PASS；整核 RVC PASS |
| `frontend/frontend.sv` | **L8a接口接入**：ICache公开Read/ReadData链路与共享PTW，原取指/恢复/精确同步连线保持 | VM_AD=1已在T10通过；预取性能与平台留后级 | 既有前端套件及M5/M6取指回归；见T09报告 |
| `frontend/icache.sv` / `icache_mshr.sv` | **L8a目标实现**：四行MSHR、按PA合并、公开Read/ReadData整行回填，保留ITLB及异常身份；无I目录/IRecall | 预取性能未验收；VM_AD=1已在T10通过 | M4 seed1/7/29各4/4、M5/M6既有取指回归；见T09报告 |
| `memory/l2_home.sv` / `l2_slots.sv` / `l2_probe_engine.sv` / `l2_mem_engine.sv` | **L8a/L8b实现**：非阻塞Home保留，第三DMA端口Read/MaskWrite、一致性Down/Inv及字节合并；Y13断言 | SoC/DDR/设备集成留L11 | M1与N1、M3与N3真实AXI/DMA代理；见T10报告 |
| `frontend/itlb.sv` / `lsu/dtlb.sv` | **L8a接口适配**：DTLB双查询共享数组，I/D各单miss槽、单共享PTW；保留ASID/G/权限/SFENCE/epoch | VM_AD=1已在T10通过；不宣称多walker | MMU seed1/7/29各7/7、公开PTE独立各2/2；见T09报告 |
| `lsu/ptw.sv` / `walk_cache.sv` | **L8a接口适配**：单walker/PMP/PMA/epoch规则保持，PTW物理读走公共访存协议 | VM_AD=1已在T10通过；单walker | M2 PMP客户端、M3物理序列、M4 MMU/PTE与整核AD；见T09报告 |
| `lsu/pte_ad_updater.sv` | **L8a接口适配**：公共PTE CAS、队头D owner/重遍历、接受事务drain，AD内部请求具来源授权 | reservation/AMO留后级 | M2 CAS/PMP、M3 A/D序列、M4 D-refresh回归及整核AD；见T09报告 |
| `lsu/dcache.sv` / `dcache_mshr.sv` / `dcache_writeback.sv` / `dcache_probe.sv` | **L8b实现**：9类AMO、LR/SC、原子前进保护、权限寄存、DMA置I广播及成功PTE A写广播；保留L8a多MSHR/RFO | L8c与FPGA留后级 | N2 MSHR1/4各20例，N3四组合，N6 AMO/MMIO/拆分/DMA；见T10报告 |
| `backend/store_queue.sv` | **L8b实现**：ATOMIC/MMIO/SPLIT项交队头HEU，完成唤醒年轻load，退休直接释放；普通SQ转发/drain保留 | L8c与完整一致性留后级 | N4 seed1/7/29各7例，M5/M6与N6；见T10报告 |
| `backend/backend_issue_queue.sv` | **L8a目标实现**：MEM双发射，删除旧按序load及allow_load门控；源域/唤醒及INT/BR/FP结构保留 | FP提前唤醒及性能优化留后级 | M4直接IQ3/3、L3 kind0/1/2×seed1/7/29；既有early_wakeup原断言通过；见T09报告 |
| `backend/load_store_unit.sv` | **L8b实现**：普通双访存与HEU复用翻译/cache路径，跨行与IO延后到队头，Y14异常不门控S1 SQ查询 | 单D owner/单PTW；L8c留后级 | N4 seed1/7/29各10例、L5各2例；N6跨页fault/D位与全部跨行偏移；见T10报告 |
| `frontend/fetch_return_queue.sv` | **闭环简化（L7a）**：单槽身份匹配、年龄清除；kill 拍保留槽接收匹配响应 | 单槽吞吐限制保留，多项返回队列留后级 | T05b `b122d59` Alan 3/3 PASS；本次未改行为 |
| `frontend/rvc_expander.sv` | **闭环简化（L9）**：整数 RV64C 加四条浮点 RVC，C.LUI nzimm 修正 | 完整 ISA 一致性留后级 | Alan 3/3 PASS（`50ff873`），含 FP RVC 与 C.LUI；顺序整核 PASS |
| `frontend/ifu_f0.sv` | **闭环简化（L7b）**：四条/拍、首拍出队、hold/pend、整数 RVC 展开、edge/D34、kill/截断 | 浮点 RVC 在 L9；ITLB/PTW 在 L10 | Alan 6/6 PASS，含 120 拍 RV64I 随机事务 |
| `frontend/ifu_f1.sv` | **闭环简化（L7b）**：按长度/位置 a～f 核对；直接截断、零指令拍 c′、寄存式请求 | 完整 ISA 一致性留后级 | Alan 18/18 PASS，保留 L7a 17 项 |
| `frontend/redirect_arbiter.sv` | **闭环简化（L7a）**：四源年龄仲裁、busy 替换、接受拍计数；F1 寄存请求已接入 | SYS committed 上下文仍为已知边界 | Alan 仲裁器 2/2、l7_recovery 2/2 PASS；T06 复验通过 |
| `frontend/fetch_buffer.sv` | **闭环简化（L7a）**：按 FTQ 身份/槽位选择性保留，kill 拍阻塞握手 | 吞吐与综合时序留后级 | Alan 2/2、l7_recovery 2/2 PASS；T06 复验通过 |
| `system/hpm_counters.sv` / `system/csr_file.sv` / `system/backend_perf_events.sv` | **L8b接入**：misa.A、十项原子/MMIO/拆分/order/DMA事件；特权CSR及HPM逐拍增量保留 | 平台PMU/FPGA留L11 | N4 CSR11例、既有HPM19例、N6事件记录及拆分精确55自查；见T10报告 |
| `system/commit_ctrl.sv` / `system/wfi_ctrl.sv` | **L8b实现**：FENCE.I只排空committed SQ并同步前端；order_flush队头重取；外部效果至退休间屏蔽IRQ | 平台中断设备留L11 | N4 commit8例、HEU6例；N6中断副作用精确一次；见T10报告 |
| `common/pmp_checker.sv` / `common/pma_checker.sv` | **L8b实现**：主存[0x80000000,2^32)，IO[0x02000000,0x80000000)，完整访问范围权限；IO无执行/原子且自然对齐 | 实际设备与平台留L11 | N2权限/IO，N6精确cause/tval；既有PMP规模保持；见T10报告 |
| `frontend/frontend_sync_ctrl.sv` / `backend/decoder.sv` | **L8b接入**：AMO/LR/SC译码与aq/rl，原同步/操作数身份保留，FENCE.I删除clean握手 | 完整ISA一致性留FPGA阶段 | N4全原子合法/非法编码、旧sync与M5/M6；见T10报告 |
| `frontend/frontend.sv` | **L8a接口接入**：ICache公开Read/ReadData链路与共享PTW，原取指/恢复/精确同步连线保持 | VM_AD=1已在T10通过；预取性能与平台留后级 | 既有前端套件及M5/M6取指回归；见T09报告 |
| `backend/backend.sv` | **L8b总装**：统一HEU/AMO/MMIO/跨行、双物理行顺序广播，IRQ保护保持到owner退休 | L8c/平台集成留后级 | backend旧2例与IRQ回归1例、backend_control1例、M5/M6与N6；见T10报告 |
| `backend/rob.sv` | **L8b接入**：四宽退休前缀遇LQ order标记停止，标记load成为队头后重取；既有D/FP/trap保留 | L5历史问题/完整ISA一致性留后级 | ROB4例、VM_AD=1两配置及N6；见T10报告 |
| `backend/uop_queue.sv` | **闭环简化（L3）**：当前三宽、8项，writer/read-replica RAM；出队接R1接受 | 两拍 rename 回归待后端重构后集中执行 | Alan WQ 900 周期 PASS（`ac2aed1`，seed 1/7/29）仅为历史证据；本次集成未验证 |
| `backend/rename_dep_r1.sv`、`rename_stage_buffer.sv`、`rename_stage.sv`、`rename_map_table.sv`、`free_list.sv` | **2026-10-11 两拍 rename RTL 接入**：R1 按 INT/FP 域生成 src1/2/3 RAW 与 rd WAW 依赖；固定槽暂存；R2 压紧剩余槽、选择编号并原子分配。R1 串行阻塞到退休/取消，实际后端 RAT 关闭旧组内比较 | 功能验证按用户安排暂缓；本轮另授权后端独立 OOC 综合，结果见后端重构报告 | 尚未验证；旧 L9/O3-T01 证据不覆盖此次拆分 |
| `backend/branch_checkpoint_file.sv` | **闭环简化（L3）**：C 释放/清 parent 与不同 tag create 合并；只看拍初空闲，不同拍复用 | 系统整体恢复待 L5 | Alan CK full/C/M 700 周期 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/rename_dispatch_queue.sv`、`dispatch_stage.sv` | **闭环简化（L9）**：四宽前缀增加 FP 分流；FP 访存走 MEM，异常只消费 RDQ | 后续级 AMO 等 | L9 顺序整核功能覆盖；本模块独立门禁未运行；RDQ 本次未改 |
| `backend/backend_issue_queue.sv`、`prf_read_arbiter.sv` | **L8a读口适配**：双Memory发射使用INT 6R/FP 8R预算，保留分域源身份与就绪/唤醒合同 | FP提前唤醒及独立完整合同留后级 | M4真实PRF仲裁、IQ kind0/1/2及既有RR/early_wakeup；见T09报告 |
| `backend/branch_unit.sv`、`alu_pipe.sv` | **闭环简化（L3）**：one-shot C/M 与 JAL 链接解耦；ALU 独立 kill 保留旧 Result | JALR 在 L6；L7b IALIGN=16 已接入，完整目标边界留后级 | Alan 缺口 2 具名/700 事务 DUT/真实 WB 竞争与总装 C 合同 PASS（`ac2aed1`，seed 1/7/29） |
| `backend/load_queue.sv` | **L8b实现**：HEAD仅队头交HEU；DMA/PTE A独立行匹配，同拍完成不漏标，向ROB给order bitmap；保留L8a等待/双重放 | L8c未开始 | N4 seed1/7/29各9例；N3四组合、VM及DMA整核；见T10报告 |
| `core/o3_core.sv` | **L8b总装**：AXI4-Lite主口与一致性DMA行口、HEU/事件接入；原公开L2与PTW链路保留 | SoC/设备/FPGA留L11，L8c未开始 | M5/M6两配置、VM_AD=1及N6四程序；见T10报告 |
| `sim/o3/` | **L8b仿真验收**：4KB MMIO/SLVERR/副作用计数/单笔DMA模型，四新程序及十事件只读统计；严格退休前缀保留 | Spike/ACT4/SoC/FPGA不在T10范围 | N5既有回归与N6四自查程序；最终同SHA证据以T10确认单为准 |

## 3. 其他模块状态概览

以下保留2026-10-03历史概况；当前相关模块以第2.4节及L8a行为准，旧L2/recall/DMA协调器已删除，ICache MSHR已接入公开协议：

- **单模块实现、有 cocotb**：`ubtb`、`main_btb`、`tage`、`ras`。
- **本轮新增局部 cocotb**：`branch_recovery`（BRU/重定向/fetch buffer/ALU kill，Alan 1/1 PASS，`de9149d`）、
  `l2_cache`（2 项）、`dcache` 空副本维护口（1 项）；
  `icache` recall 回归（3 项合计）、`backend` 整核缓存路径（1 项）已在 Alan 通过。
- **单模块实现、有 SV testbench**：`ftq`（`tb/ftq_tb.sv`）、`branch_history`、`history_snapshot_store`（`tb/` 下，仅记录过 lint）。
- **单模块实现、无独立 cocotb**：`fetch_buffer`、
  `decoder`、`axi_master`、`simple_data_sram`；后端主要队列/rename/资源合同已有 O3-T01 cocotb，见上表；
  L1 整核冒烟仅覆盖本轮四条 addi 的路径。
- **空壳/待扩展**：`lsu/*` 的 AMO/DMA/完整维护路径、`system/*` 的后级部分、
  `l2_recall_ctrl`/`dma_line_coord`、`icache_mshr`、预取相关、
  `O3.sv`/`Tile.sv`。`rename_dep_r1` 与级间暂存已于2026-10-11实现并接入，验证待集中执行。

`backend.sv` 保留当前实际数据流，2026-10-02 搭建但未接入的非 L3 目标实例已移除。O3-T01 已移除本级后端空壳实例及独占 filelist 条目；文件保留。
归属：入口/提交/CSR/trap L5，M/FIFO/融合 L6，性能计数 L7，数据预取/非阻塞访存/AMO/LRSC L8，FP L9，PTW/A-D/WFI/PMP/PMA L10，fatal/L2-recall/DMA 协调 L11。
2026-10-11 用户明确要求现在拆分 rename，不等待综合时序触发；R1 依赖与级间暂存已接入实际路径。
接口变更：`rename_stage_buffer` 新增 `enq_count_i`，只保存入口门放行的连续前缀；
`rename_entry_gate.accepted_count_i` 在总装中改接 R1 接受数；Decode Queue 同步改在 R1 接受时出队。
R2 部分接受后保留固定槽位，源依赖与 WAW 依赖的生产者若已离开则读取当前 RAT；
其余依赖转换为压紧后的 R2 lane 编号。全部接受时可同沿装入下一组，部分接受时回压 R1。
误预测、全局 flush 或系统重定向清空暂存并禁止同拍 R1/R2 接受。两域 RAT 的
`INTRA_GROUP_BYPASS` 在 backend 中固定为 0，独立模块默认值保留既有接口行为。

## 4. 已知的文档不一致

- `doc/CISLC_O3.md` 的"当前实现状态"描述的是旧数据流，并引用已删除的
  `rtl/frontend/ifu.sv`、`rtl/backend/issue_queue.sv`。
- `doc/CISLC_O3_frontend.md` 中描述 `ifu.sv` 状态机的章节已失效。
- `rtl/common/o3_cfg_pkg.sv` 保留未使用的空宏 `` `O3_TBD ``；backend 相关过期说明已在 O3-T01 修正。

- B49（2026-10-07）取代 B31 跨 line 报异常：L10 已修正触及模块注释，旧跨 line 异常身份/计数仍保留；硬件跨 line/跨页拆分留 L8。历史 `backend_perf_events.sv` 的旧目标描述待 L8 触及时修正。

- 58 个 RTL 文件头注释仍写着"本阶段不写测试代码和仿真代码"（旧规则，已作废，见 agent.md 第 4.1 节）。

以上随相关模块被闭环触及时顺手修正。

## 5. O3-T02 验证边界（2026-10-06）

冻结规格 §8 Q1–Q10 已实施，只增加退休观测字段，不改变执行行为。
`unified_memory` 是旧 ITCM/软件内存地址门禁，按 Q7 排除 Spike；原 checker
及命令保留，当前 AXI 路径无法用它建立闭环证据，标为历史。
随机 200 种子全部执行，参考端每种子 3000 条，DUT 匹配前缀共 114412 条。
种子 120 通过（3001 条，含 tohost 同拍年轻 lane），其余 199 个均首差异为 PC。
12 条指令的缩减复现位于 `sim/o3/repros/branch_loop.hex`，旧 O3-T01 二进制亦复现。
O3-T01 60 条既有命令和全部新门禁的最终提交复验记录见
[O3-T02 阶段二报告](tasks/O3-T02-report.md)，不得以开发轮次替代同 SHA 复验。
用户已授权随后直接执行 O3-T02-fix；需要改 Dxx/Bxx 决策时才停。

O3-T02 收尾（2026-10-06）：上节 15/51、1/200 是修复前历史失败。
修复后补跑 137–200 为 64/64；重新构建后的同 SHA 全量复验为 O3-T01 60/60、
固定 6/6、ACT4 51/51、随机 200/200（600160 条匹配），无新 bug。
日志 Alan `/home/chen/FUN/CISLC-O3-runs/20261006-o3t02-close/final/`；
收尾文档提交原样复验另存 delivery/，其 sha.txt 与 commands.tsv 为准确交付证据。

## 6. O3-T03 已知问题退出（L5）

接入 rename_entry_gate、commit_ctrl、csr_file、trap_ctrl；ROB 保存队头串行/异常/
实际后继元信息；CSR 在队头一次读改写并写回，trap 不退休故障指令，MRET 自身退休。
RAT/free list 从提交态恢复；SQ 只取消未提交项；LSU 保留已发事务的所有权并丢弃迟到结果。
存储访问在退休前通过只读 DCache 探测确认；probe 不修改数据，成功才 complete Store。
FENCE.I 只排空 SQ + 失效 ICache，完整数据 clean 待 L8。Spike 增加 CSR/trap 事件。
Alan `2cc8a91` 的通过项和三个已知问题见 [T03 报告](tasks/O3-T03-report.md)；L5 带已知问题退出，不宣称完整通过。

O3-T03 首版发现 PRF/ROB unpacked array lane 方向不一致；修正并追加三条静态
指令的固定 Spike 门禁，详情 O3-T03 报告 Bug 1；最小 PRF 门禁在 `2cc8a91` 已通过。

L5 F0 已保留非法短编码位置及返回队列取指错误，交给 ROB 精确 trap；C 仍不执行。
测试 sim/cocotb/ifu_f0 在 Alan `2cc8a91` 2/2 PASS，固定 illegal_zero 门禁 PASS。

## 2026-10-06 L6 合同更新

完成 FIFO 双入队、取消归还与独立单双容量；renamed_uop 携带融合成员 tag；共享 INT IQ 加入 FU 可用性与完成头唤醒；WB extra 源完成口；BRU 目标异常。详见 T04 报告。验证按用户新策略从简；T03 已知问题不再阻塞 L6。

### L6 当前模块状态

| 模块 / 路径 | 当前状态 | 定向证据 |
| --- | --- | --- |
| signed_mul65x65 / mul_execute_unit | DSP 四拍数据通路与完整身份、双结果和按条取消 | mdu DIV=0 |
| unsigned_radix4_divider / div_execute_unit | MSB 对齐 radix-4、符号与 W / 除零 / 溢出 | mdu DIV=1 |
| fu_completion_fifo | 预留信用、双入队、WB 背压、选择性取消 | fu_completion_fifo |
| mul_fusion_detect / rename_stage / dispatch_stage | 两条架构指令、整对接纳、单次执行 | mul_fusion_detect、整核 L6 短程序 |
| backend_issue_queue / backend / writeback_arbiter | 共享 INT IQ 的 MUL/DIV 可用性、额外写回、早唤醒和头部 bypass | early_wakeup、整核 L6 短程序 |
| branch_unit / branch_execute_unit | JALR 重定向 / 链接保持 / RAS 提示；L6 时 IALIGN=32，L7b 已改 IALIGN=16（见 T06） | jalr、整核 L6 短程序 |

最终实现与综合证据以 [T04 报告](tasks/O3-T04-report.md) 为准。

## L9 RTL 交付与基础功能测试（2026-10-07）

先前用户授权写完 T07a/T07b RTL、测试另做；本轮授权补基本功能测试。当前采用 T07b
译码与 misa，RTL 本轮未改行为；未保留由测试宏裁剪 RTL 的过渡模式。实现与验证见
[O3-T07-report.md](tasks/O3-T07-report.md)，不改冻结 spec/设计基线。

| 模块 | 本次 RTL 行为 | 验证 |
|---|---|---|
| `backend/decoder.sv`、`frontend/rvc_expander.sv` | FP 指令表/域/格式/rm、四条浮点 RVC、C.LUI nzimm 合法性 | Alan RVC 3/3 PASS；译码经整核覆盖，独立译码门禁未运行 |
| `backend/backend.sv` | **L8b总装**：统一HEU/AMO/MMIO/跨行、双物理行顺序广播，IRQ保护保持到owner退休；边界：L8c/平台集成留后级 | backend旧2例与IRQ回归1例、backend_control1例、M5/M6与N6；见T10报告 |
| `backend/physical_regfile.sv`、`preg_ready_table.sv` | **L8a/X3**：INT 6R/3W、FP 8R/2W，FP p0普通寄存器；实际写口同拍旁路/ready保持 | M4真实PRF仲裁、M5/M6整数及FP回归；非独立完整PRF合同证明 |
| `backend/fpu/fpu_{fma,divsqrt,misc,conv}_fu.sv` | 直接拆分 opgroup；8 项身份侧表、killed 保留到终结、共同结果保持、FMV 旁路轮转；2026-10-11 两个 FMA 迁为 Breeze FP32 5 / FP64 7 级算术流水 | 原版 Alan FU 2/2 PASS（含 32 组固定种子加法）；本次流水迁移和新增两例尚未运行 |
| `backend/fp_writeback_arbiter.sv`、`writeback_arbiter.sv`、`rob.sv` | **L8a写回接入**：双load头按年龄竞争3 INT/2 FP写口，完成槽随两管道展开；保留kill/flush与FP flags规则 | 经用户批准迁移的WB fixture保持原背压/kill检查，另检查更老load完成；M4旧异常FIFO及M5/M6，见T09报告 |
| `backend/load_store_unit.sv` | **L8b实现**：普通双访存与HEU复用翻译/cache路径，跨行与IO延后到队头，Y14异常不门控S1 SQ查询；边界：单D owner/单PTW；L8c留后级 | N4 seed1/7/29各10例、L5各2例；N6跨页fault/D位与全部跨行偏移；见T10报告 |
| `system/commit_ctrl.sv`、`csr_file.sv` | 实际退休 OR flags、写 FPR/flags 置 Dirty、CSR 写/FS Off/保留 frm 与 SD | Alan CSR 4/4 PASS；commit_ctrl 经整核覆盖，独立门禁未运行 |
| `third_party/cvfpu`、`rtl/rtl.f`、`scripts/cvfpu.vlt` | 2026-10-11 CVFPU 使用 Breeze 同版 `23153ba`，保留 common_cells、统一文件清单与限定 CVFPU BLKANDNBLK 豁免 | 原版 Alan lint PASS：0 errors / 361 warnings；升级版本未运行 lint/功能验证 |

B33 闭环简化：FP FU 不发提前唤醒；INT/FP 消费者由真实目的域 PRF 写授权唤醒。
**代码 SHA `50ff873817305dc2696de1f7457fda1b80c337dd` 已推送。** Alan 9/9 模块用例、
`run-l9-fp-smoke`（890 cycles / 267 retires）与五项既有整核回归通过。
`run-l9-fp` 保留 FAIL：年轻 load 进入单槽 replay 后禁止更老 load 发射，
阻塞依赖该老 load 的 store；纯整数复现也 FAIL。未修改访存设计或删除失败用例。
本次仅记基本执行功能验证；完整 L9 spec 门禁、Spike/ACT4、综合/FPGA/SoC 未运行。

2026-10-07 后续修复更新：上述 `50ff873` 等待环 FAIL 为历史记录；最新代码
`f0f410640a27abe4f62f3cf728f387ab8b6bde6e` 已推送并在 Alan 独立目录通过本次全部指定门禁。
当时Memory IQ load按序发射，store/replay门控保留；这是历史B04/L3简化，当前L8a已替换为双发射事件重放。`run-replay-order` 为 121 周期/20 退休、1 replay；`run-l9-fp` 为
1860 周期/616 退休、1 个预期 trap、2 replay，均 tohost=1。Memory IQ 2/2、lint 0 errors，
顺序 FP 与五项既有回归全部通过，完整命令/exit code 见 [T07 报告](tasks/O3-T07-report.md)。
全套 L9 合同验收仍未完成；本次未运行 Spike/ACT4、访存类 cocotb、综合/FPGA/SoC。

### 2026-10-07 L10 收尾证据

代码 `1d0d6f8369fa69476d07538157be234a88db08bf`；Alan GitHub 独立 clone
`/home/chen/FUN/CISLC-O3-runs/20261007-t08c-1d0d6f8/`，完整命令/exit/log 在 `evidence/final/`。
38 套件 132/132（FAIL/SKIP=0）；八项既有整核回归、T08a 特权与 AD 正向整核通过；
完整 VM cause 15 与正确分支解析同拍触发旧推进断言，保留为已知问题。
跨模块合同与全部自行决定、复现命令见 [T08 报告](tasks/O3-T08-report.md)。
本段是T08历史收尾记录；当前L8a状态见上表及T09报告，L11未开始。

### 2026-10-08 L8a 收尾证据

O3-T09限定非阻塞访存底座；M1～M6与最终spec12.8证据、实际cloud_chen预检、完整SHA/命令/exit/XML/原trace、M5→M6周期与统计见 [T09报告](tasks/O3-T09-report.md)。退休比较采用用户批准的成功tohost截止前缀，仅豁免同拍后槽位的终止自跳转；没有扩大其他例外。完整VM仍失败，首点为PTE A位检查PC0x80000204，未宣称VM通过；不含Spike/ACT4/litmus/综合/FPGA，L8b/L8c未开始。


### 2026-10-08 L8b 收尾证据

O3-T10的N1–N6分层门禁已通过。用户批准B36成功置A时的物理行广播与年轻load重取；四宽ROB退休前缀不得跨过order标记。MMIO触发中断的外部写效果必须先退休，backend保护覆盖HEU完成到退休的空隙。N6原子、MMIO、拆分、DMA程序全部自查/tohost通过，MMIO副作用96次、拆分事件55的精确检查保持。新增模块mem_head_unit、dcache_amo_unit、lrsc_reservation、mmio_axil_master、dma_line_adapter由N1/N2/N4/N6验证。证据与自行决定见[T10报告](tasks/O3-T10-report.md)。

本收尾提交冻结后完整新跑12.8；最终同SHA结论仅在报告指定acceptance.json的sha匹配且passed=true时生效。L8c与L11未开始；未运行Spike/ACT4/litmus/综合/FPGA。


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
