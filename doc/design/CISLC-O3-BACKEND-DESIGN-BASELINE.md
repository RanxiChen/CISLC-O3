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

2026-10-12 00:40最新uBTB训练：T0选行与旧值捕获→T1更新并写表，II1；pending窄CAM计划与前一写完整值旁路保证相邻同址/替换训练顺序。目标地址query/train两份单写RAM，tag/valid/owner/方向/masks元数据独立；快查询仍组合，不增加查询延迟或FSM。训练应用增加一拍，原600周期模型转移/golden保留仅延迟应用，新增1000连续事务检查。25项静态解析通过，功能未运行，完整系统收益待C9。

2026-10-12 00:30：C7/C8在生产生成完成后、Vivado未开始前主动取消（runner143）；LSU新增T级将RR→cache S0从2拍改成3拍，因此DCache内部/line reservation也必须增加一拍，旧快照仅保留静态/生成证据。当前CFG.lsu.cache_s0_delay=3，LSU elaboration断言一致；DCache line/internal packets、probe保护/安装ID/bank/PS下一拍冲突均跟随预留末级，不增加FSM。普通CPU lane仍每拍预约，内部事务仅增加固定延迟。原DCache数据/golden/seed/规模保留，预约驱动按实际配置推进，新增800周期CPU双路+PTW/probe交错身份/成功数据/实际容量检查。当前正在解析3拍与旧2拍DCache fixture；功能后置。C9将包含全部SQ、LSU、恢复边界与预留校正。

2026-10-12 00:25 最新恢复增量：所有提交重定向包均通过recovery_boundary寄存发送，不再让C2 trap target旁路读取提交组合包。C0接受→C1取消/CSR更新→C2目标捕获→C3完整目标送前端；trap transport busy与recovery pending连续持有精确边界，不新增FSM，不影响普通发射/退休吞吐。旧500周期seed/完整包随机检查保留并按授权新延迟更新，新增160组实际trap_ctrl+dispatcher身份/目标冻结/连续busy/复位检查。功能未运行，待当前静态解析与后续完整综合；C7固定输入不含此增量。

2026-10-12 00:08 当前MEM增量：RR/AG发送DTLB查询→下一拍接收翻译结果并发送缓存S0→T注册翻译物理包/异常/priv/need_D→权限/PMP/PMA与SQ forwarding/缓存S1→S2完成。相对于旧AG直接发缓存S0，缓存S0移到翻译结果捕获周期，使缓存S1数据与T包对齐；缓存与LSU身份、代际、掩码一起推进。每路结果信用2→8，count/head/tail按容量窄化，仍两个MEM流水口，未加FSM。新增连续48双路包检查II1和全部96个返回身份，原四请求满队列测试保留并扩到8项真实容量。FPU配置仍8且FMA自动最小9槽，不增加FU/FP带宽。
SQ捕获载荷已与LQ一样分开：双writer银行、HEU+两重放reader RAM，wait_reason/uop.valid可变字段独立；转发地址/数据与已提交排出协议保持。新增160组完整载荷/重复写优先/持有/HEU顺序释放复用检查。
当前仅22项lint/parse通过（含完整FPGA SoC与LSU/SQ fixtures），无功能运行。C6v2整系统仍在综合，绑定其固定旧MEM/SQ输入；上述后续增量将进入C7独立完整快照，不混用结论。

2026-10-11 23:35 当前增量：IQ将所有真实WB、提前通知、完成旁路预译成按物理寄存器索引的INT/FP调度就绪位图，四个IQ共享组合表达式；仍只在源就绪寄存器上升沿更新，下拍选择。位图不是PRF真实ready，最终捕获仍重查真实数据。包括整个preg编码范围，保留非法范围的旧通知比较语义。
LQ不可变捕获载荷使用每AGU writer × (两路重放+HEU) reader的单写RAM，固定owner行保存；可变va/tag/等待/异常/rob_idx/branch mask单独保存。双写相同owner高编号writer优先、分配清written、正确解析掩码/取消/代际迟到响应规则保留，无额外延迟/FSM。ROB在分配时预解码CSR/SFENCE，普通PRF保留及CSR/PTW admission使用窄谓词，串行实际内容仍读完整队头。
这些变化保持FE/Decode/Rename/Dispatch/总INT选择/退休3，ALU2+MUL1+DIV1+FMA1，MEM2、INT4R2W/FP5R1W与现有容量；没有降低宽度或频率。当前测试和静态解析仅是重构准备，尚无功能/物理闭合结论。

2026-10-11 最新Decode队列载荷：固定三条输入writer银行、每个R1读口一份RAM副本，
逐row writer tag跟随实际入队。保留DecodeQ8、三宽连续前缀、旧pre-edge空位/flush优先级，不新增级或FSM。
ROB仍用四个物理bank；文中较早的DecodeQ四bank描述是被替代的历史候选。

2026-10-11 当前计数与ICache存储边界：HPM E0寄存事件合格增量，E1进行64-bit累加；
CSR/RMW用physical counter+pending increment前递架构值，OF仍按本周期事件计算，同拍计数器/配置写优先级保持。
ICache tag载荷是request/fill/PF三个RAM读副本，共用fill唯一writer；valid/PF独立可变，reset/inv只清元数据。
请求tag采样与现有fill dirty replay级不改变；没有新增FSM。对应功能验证待后端重构完成，整系统综合在第五轮。

2026-10-11 后续逻辑边界：WFI只由睡眠状态寄存器释放执行，局部pending唤醒不直接穿透退休控制。
SFENCE在精确head接受之后捕获地址/ASID/x0条件，下一拍统一送DTLB/PTW与epoch更新；commit_ctrl
仍等真实翻译ack再进行前端同步/退休。普通三宽推进不增加空拍；阶段与功能验证见LOOP。
INT IQ按ALU/MUL/DIV分别收集资源允许的最老候选，窄年龄位置并行排序后取前三；
选择规则、每FU预算和部分接受保持，宽payload随后RAM读取。独立OOC小幅+181 LUT换7级路径缩短。

2026-10-11 当前组件存储决定：RDQ/INT-FP-MEM-BR IQ用多writer银行及reader RAM副本，
逐槽最新writer tag指向不可变payload；取消mask和就绪/valid仍为独立元数据。
ROB初始异常/后继PC并入分配RAM，异常与分支结果晚更新各用单写RAM；分配清late选择，
同拍晚更新最后覆盖，与原实现优先级一致。读口/吞吐/取消边界不增加等待级或FSM。
独立完整接口OOC有面积收益；功能与整系统对应收益仍待复验，当前目标及范围不变。

<!-- 2026-10-11 用户授权的后续重构：恢复接受与应用分级、操作数载荷RAM。 -->

当前新增恢复逻辑边界：C0由commit_ctrl确定精确事件并阻止跨边界退休；backend仅局部门控新HEU不可撤销owner和ITLB PTW入场。
`recovery_boundary`在C1广播寄存后的取消、恢复committed rename state，并发出非trap系统重取包；
trap仍在C1更新CSR、C2发已寄存target。C0年轻推测执行可继续，C1统一取消，真实写回只产生推测状态。
正常三宽retire/issue吞吐不插入事件流水；没有新增FSM。实现与新增500周期边沿/身份测试待功能验证。
A0请求与FU capture固定物理槽的宽载荷使用单写RAM，可变owner/branch mask和顺序索引独立保存。
独立完整接口OOC已测面积收益；整系统对应结果尚待components3，不套用到components2。

# CISLC-O3 后端设计基线与决策记录

2026-10-11 三宽组件重实现：pipe2v2整SoC仍296394 LUT（122.27%），因此保持三宽重做组件。
A0四槽持有完整uop直到实际PRF捕获；A1/A2仅身份/源地址/预算描述符，取消覆盖所有在途副本。
每FU三槽操作数payload固定，只有窄顺序索引在取消/消费时压缩。FP单写PRF使用每读口一维RAM副本；
MDU完成队列固定payload槽；LSU结果数据RAM与可变valid/branch mask分离。
LQ直接计算三个连续ROB退休位置的order保护，保持同拍coherence/PTE事件与kill检查；全ROB表仅供局部观测。
这些组件改造不改变FU数量、三宽总退休、双MEM或真实WB置ready/ROB完成规则。功能门禁仍后置。

2026-10-11 后续分级：串行CSR采用“队头操作数/请求捕获 → 架构CSR执行”两级。
请求在途持有原ROB队头、抑制IRQ；真实响应负责完成/异常，合法写仍先退休后接受中断。
原始CSR队头类型负责读口和ITLB/PTW接纳隔离，不从更晚的order/IRQ决策反传读地址。
HPM保持原同拍架构语义，仅以窄事件增量和独立上部进位缩短组合计数/OF路径。
CSR/HPM包含components1综合快照；其后本地又增加trap请求寄存→CSR更新→目标寄存/redirect。
请求与redirect持有精确边界，接受拍立即阻止退休/取消；在途阻止重复事件及新副作用/issue/PTW。
显式PRF多写RAM银行已应用；FMA实际最少9个身份槽覆盖DP7+结果保持+入口信用余量，其他FP组配置8。
另增加IRQ资格/原因采样→提交精确接受级，候选每拍更新，EPC在实际接受时取架构边界。
CSR/trap/不可撤销窗口仍抑制接受，WFI用真实irq_view唤醒；只增加响应延迟，不串行化普通退休。
这些较晚改动尚待新快照解析/综合/功能证据。

**2026-10-11 用户最终目标：KCU105 上资源与时序可满足、整体不少于三发射的乱序核心。**
优先整体四宽；资源削减仍不足时采用三宽，三宽仍不足则重实现组件，不能降到两宽作为交付。
新增流水维持配置允许的连续吞吐；最终可实现结论需要资源、物理时序和功能证据，当前仍先做综合诊断。

**2026-10-11 历史三宽pipe2v2候选（其结果与后续重实现见顶部）：** 第二四宽整SoC综合仍占298222 LUT（123.03%），
因此按用户顺序转为整体三宽：FE交付/Decode/Rename/Dispatch/INT IQ选择/总退休3；其他容量/FU/读写口沿用第二四宽候选。
ROB32和DecodeQ8使用四个物理bank，逻辑lane仍为三，避免除三硬件与ROB退化到32个bank。
FU buffer → A0三槽独立保留项 → A1年龄优先级 → A2授权/地址 → 各FU三槽操作数捕获 → RegRead/FU请求。
A1每拍推进一个候选包，未获授权项保留A0所有权并释放本次in-flight标志重试，不堵住整包。
A2使用有界资源函数的并行前缀树完成INT/FP原子预算；分配前预留每路操作数捕获容量，
计入已授权未捕获的在途项，正常路径目标II=1。慢FU只阻塞自己的捕获队列，不占共享读地址等待FU。
读前仍检查真实数据，CSR/SFENCE复用读口时禁止普通PRF捕获；取消覆盖保留项、优先级、地址包与捕获队列。
原单拍RegRead接口仍负责向FU交付；MEM的LSU/完成credit仍在其真实RegRead接纳时预留，不提前承诺访存完成。
未新增串行状态机；逐槽valid/in-flight用于唯一所有权跟踪。三路连续吞吐、慢DIV隔离与捕获操作数测试已写未运行。

**2026-10-11 逻辑分级第一原型（历史解析快照，已被下述当前结构替换）：** FU buffer → 两槽 A0 请求队列 →
两包 A1 优先级流水 → 两包 A2 授权/地址流水 → 各路 RegRead → FU。
A0 接纳只看本地寄存占用，A1 采样候选并锁存并行循环 ROB 年龄排名，A2 独立完成 INT/FP 原子预算。
每级可以出队旧项并入队新项，无冲突正常路径目标 II=1；候选所有权、分支 mask 与地址映射逐级保存。
同一候选包内按采样时的年龄顺序处理；被拒绝项保留，下一拍继续竞争，取消不重新生成指令身份。
这轮解除下游 read-ready/分配结果到 FU buffer dequeue 的组合反馈；各来源仍可独立排空 A2 头包。
两个包的缓冲隔离本轮反馈，但共享地址头包仍有队头阻塞，后续须审查每路读后容量预留及独立推进。
连续三路 INT/BR 与单路 FMA 的吞吐测试已扩展，暂未执行，不作为功能或时序闭合结论。

**2026-10-11 用户新增约束：按逻辑职责重新流水，除非必要不引入状态机。**
该原则覆盖整核；现有状态机逐项审查，能够允许多个请求重叠推进的实现改为流水。
优先级计算、资源分配、读操作数、执行、完成等按职责划分寄存级；允许增加单条指令延迟，
不得仅因新增流水级降低既定资源配置下的稳态吞吐。无冲突、操作数可用且下游可接收时，
原本支持每拍接收的通路继续每拍接收，各级同时处理不同指令。
以每级 valid/占用、队列和寄存 credit 管理在途请求；缓冲容量覆盖反压传播期间的在途量，
不以固定空拍或“处理完一条再接下一条”替代流水，也不把长组合 ready 链跨越所有寄存级。
候选进入流水后保有唯一所有权，年龄、读口需求、授权、操作数和动态身份随指令对齐；
flush/分支取消、重放、精确异常、退休及真实数据就绪规则保持。
只有存在真实的迭代依赖、不可重叠的架构操作或外部事务约束时，才保留必要的串行控制；
每处须记录具体依赖、串行范围、接受间隔和不能流水化的原因，不能以“协议控制”为一概豁免。
MSHR/事务表的逐项状态和流水级 valid 是必要的在途跟踪，不等同于全模块串行状态机；
仅改名或去掉 enum 不算流水化，验收同时检查连续接收/输出与延迟，而不只检查状态编码。
当前迭代 DIV、FP DIV/SQRT 的吞吐不因本决定自动变为 II=1；其算术结构须单独审查。
当前 A0/A1 仍有整包排空与同拍补入反馈，现有状态机也尚未完成上述迁移；本段为新约束，非完成声明。

**2026-10-11 用户四宽优先路线的第二容量/端口候选（历史综合快照）：** 第一候选整SoC综合LUT432321，仍超KU040。
继续保持Decode/Rename/Dispatch/INT IQ选择/总退休4；ALU2/FMA1、MUL/DIV各1、MEM2，ROB32、INT/FPpreg64、
checkpoint4、RDQ8、IQ INT8/MEM8/BR4/FP8，INT4R/2W、FP5R/1W（单组三源FP+两路FP store）。
DecodeQ8/ibuf16/FTQ16、BTB256sets×2ways、TAGE512行/表与base1024、L2 128KiB4way/slots4。
L1I/L1D16KiB、LSQ16、缓存MSHR4、MUL credits8/FPU tags8/SP5DP7及恢复/一致性/通知机制保留。
减少读写带宽允许buffer与完成队列等待；整体四宽不承诺同类FU或任意四条双源指令都能同拍执行/写回。
FP布局按配置推导；这仍是资源候选，未以解析通过冒充综合、功能或时序闭合。

**2026-10-11 用户资源削减授权的第一候选：** 四宽 Decode/Rename/Dispatch/总退休与 INT IQ 选择4保持；
ALU4→3、FMA2→1，MUL/DIV各1、MEM2保持。ROB64→32、INTpreg96→80、checkpoint16→8、
L1D32KiB8way→16KiB4way；FPpreg64、FMA tags8、MUL credits8、MEM在途2与缓存/MSHR/一致性机制保持。
FP保留稳定的五路标签/仲裁槽位，禁用的第二FMA槽没有buffer/RegRead/FU，所有输出显式无效并拒绝IQ路由。
这是一轮容量/FU候选，资源与功能结论都须绑定新源码证据，不等同于已经满足KU040。


**2026-10-11 用户后续决定：** 整系统保持四宽，先拆分读前仲裁流水，并按真实 KCU105 综合结果削减容量与 FU 数量。
四宽削减仍无法满足资源时才改三宽；三宽仍不满足再重新实现各组件，双宽不作为此路线目标。
进一步流水边界为双槽 FU buffer → 请求寄存器 A0 → 授权/读地址寄存器 A1 → RegRead → FU。
buffer 入队容量只依赖寄存占用；A0/A1 持有完整动态身份与分支 mask，错误解析选择性取消，
通知仅用于调度，真实读仍检查 ready/真实写回/live bypass。A1 未排空包持有授权与地址，允许独立源排空。
这次授权从后端 OOC 扩展到标准完整 SoC 的综合报告，未授权布局布线/上板；功能回归仍按用户决定后置。


更新日期：2026-10-08。**最新：第 41 节 B52（L11 SoC 改用 LiteX，核与 SoC 之间只用 AXI，内存通路直连 LiteDRAM；取代 B28 的“不用 LiteX”与 B44 的前提）。此前：第 40 节 B51（L8 乱序访存微架构：三类等待者与重放接口、64B 行/512 位链路、访存 32 位物理地址、32KB 8 路 L1D 双管道 bank 化、4 MSHR、256KB 8 路 L2、store 所有权预取、L8c 依赖推测、L1I 只读客户端与简化 FENCE.I）。此前：第 39 节 B50（L8 访存以 Breeze v1 MESI 协议与 L2 Home 为机制来源，按乱序高吞吐修改；B08/B41 的协调方式被取代）。此前：第 38 节 B49（能由硬件处理的不交给软件 trap：跨 line/跨页非对齐硬件拆分、`time` CSR 硬件读、Sstc；B31 的“跨 line 报异常”部分被取代）。此前：第 37 节 B48（性能计数器 Zihpm + Sscofpmf）；B45 已暂停。此前：第 36 节 B42～B47（v1 实施计划确认，见 [`../O3-v1-plan.md`](../O3-v1-plan.md)）；B01 改为四宽；B16/B17/B19/B20 已移入附录 A。**

原更新日期：2026-10-02。目标工程：`/home/chen/work/CISLC-O3`。本文暂存于 Flow，仅记录设计与只读源码核对；不代表 RTL、编译、仿真、时序或 FPGA 验证完成。

最新恢复决定：B30 同步前端 D29 的 BOOM 式 RAS 快速修复及系统首笔取指解耦，替换旧 undo；B29 的其余审查入口继续有效。

最新访存决定：B31 已选普通可缓存标量非对齐访问同 line 硬件支持、跨 line 报异常，并加入跨 line 非对齐异常次数计数。**2026-10-07 B49 取代其中“跨 line 报异常”与计数器口径：跨 line/跨页改为硬件拆分完成。**

最新机制共识：B32～B41（第 35 节）记录保守 load 依赖、提前唤醒与完成 FIFO、MULH+MUL 融合、LR/SC reservation、硬件 A/D、committed_next_pc、WFI、fatal 隔离、FP 状态退休、L2 inclusive（组相联、PLRU）回收，以及系统同步由 commit_ctrl 编排；已补入目标工程 RTL 框架（空壳，未编译/验证）。

前端合同见 [前端设计基线](CISLC-O3-FRONTEND-DESIGN-BASELINE.md)，尤其第 16 节及 D09、D22～D28。本文与前端基线互相补充，不覆盖已定前端方案。保留既有前后端代码，整体设计讨论明确后按用户指令进入实现。

**整数算术来源边界（2026-10-01，仍有效）**：仍在微架构设计讨论，不开始 RTL 移植或测试。整数乘除法仅复用 Breeze 对应单元的算法与数据通路，未来再将其 Chisel 实现转写 SV 并接入 CISLC-O3；不复用整个 Breeze 后端或整核。浮点按 B14/B15 的独立决定处理。B16/B17 的 Vivado 路线、B19 的新算法/DSP 优化讨论均为历史方案，不能覆盖 B21 的当前决定。

**最新工作状态（2026-10-02）**：用户已安排其他 agent 根据基线搭建目标工程框架；“本轮不实施 RTL”约束本讨论窗口，不表示整个工程无人实施。当前任务是对已定机制查漏补缺，先讨论并记录共识，再按单独授权补框架。B22～B29 为最新串行执行、屏障、地址预测、trap/xRET 与 Linux 复用决定；历史“暂缓”不再代表当前议程。源码状态均为注明日期的局部快照，新窗口须重新只读检查，不能用空壳或旧注释推翻设计决定。

## 1. 工作方式与当前证据

- 一次讨论一个机制，解释正常流程、冲突和资源代价；字段或容量未定不等于机制不存在。
- 用户确认的新决策记在本文；建议、待定项与实现事实分开。
- 2026-09-30 实时核对目标仓库：`develop`，HEAD `06462b0ebd48cecf0af34b8a87a90a365561894b`。未跟踪文件 `sim/o3/rv64i_instructions.jsonl`、`sim/o3/unified_memory.jsonl`，需保留。相关路径及父目录未发现适用 AGENTS.md；以后操作重新核对。
- 当前已有 Decode Queue、rename、Rename/Dispatch Queue、三类 IQ、执行/写回、ROB 提交；已有组内 RAW/WAW 旁路、映射 checkpoint、分支 allocation mask、LQ/SQ 和分支恢复，不预设全部重写。
- 旧 `doc/CISLC_O3_ARCH_SPEC.md` 中无 MMU、C 不在规划等旧目标不能覆盖新前端基线。
- 2026-10-01 用户明确整核目标为 KCU105 上的 RV64GC、可运行 Linux；SD DMA 是首版系统需要，不只是未来占位。浮点见 B14/B15，CSR/屏障见 B22～B24，异常/中断和返回见 B26/B27，Linux 复用见 B28/B29；设计决定不等于集成与验证完成。
- 2026-10-01 再次只读核对：目标分支、完整 HEAD、两项未跟踪仿真文件与上次一致；父目录及文档路径未发现适用 AGENTS.md/CLAUDE.md。本次仅更新设计文档，不改 RTL、不运行编译/仿真、不提交 git。

## 2. B01：参数化 rename 宽度（2026-10-05 由 B42 改为四宽）

**2026-10-05**：宽度改为 4，见 B42。下文为原记录。

用户确认后端 rename 宽度参数化，第一版取 6，根据仿真与 FPGA 数据调整。前端仍按序每拍最多交付 4 条，Decode Queue 吸收积累，六宽用于消化积压；不宣称持续六条整核吞吐。Decode、Dispatch、发射、提交宽度不因此自动改成六，端口与容量分别设计。

## 3. B02：依赖预处理 + 原子 rename 两拍（已定）

用户确认：第一拍检查组内依赖，第二拍检查资源、给出物理编号并完成完整 rename。只拆组合计算，不拆开 RAT、free list、ROB 等状态事务。暂不采用跨拍 RAT 访问、第一拍预分配 preg 或推迟 ROB 实际入队；后续时序不满足时，再评估论文中的进一步拆分。

```text
Decode Queue → R1 依赖预处理 → 级间暂存 → R2 完整 rename → 现有 Rename/Dispatch Queue
```

### 3.1 R1：判断依赖谁

对最多六条有序指令，使用架构寄存器编号查找：rs1、rs2 的最近更老写入者，以及 rd 的最近更老同名写入者。前两项用于 RAW 源旁路，后一项用于 WAW 下正确生成 old_dst_preg。

每项逻辑信息为依赖是否存在及生产者槽位；六宽可用 3 位槽位号，具体编码可调整。排除无效 lane、无目的写入及 rd=x0；源比较按读使能。第一拍不读 RAT、不消耗 preg/ROB/LQ/SQ/checkpoint，不修改推测状态。仅在级间暂存接受时移走 Decode Queue 对应指令，并保存 uop 与依赖关系。

### 3.2 R2：给出编号并统一生效

按现有方式检查 preg、ROB、LQ/SQ、checkpoint、RDQ，选择可接受的最老连续前缀。读取当前 RAT、选择新 preg 和各队列编号；若操作数依赖本组仍有效的更老生产者，选择该生产者本拍新 preg，否则选择 RAT 映射。

在同一接受边界统一更新 RAT、free list、ROB、LQ/SQ、checkpoint、目的 busy，并进入 RDQ。一条指令所需资源要么全部获得，要么不分配。x0 不分配新 preg。相同 rd 的最终 RAT 更新取最后一条实际接受的写入；分支快照包含分支自身和更老指令，不包含更年轻指令。

例：I0 写 x5，I1 读 x5 写 x6。R1 只记录 I1 的源来自 I0；R2 假设分别分配 p32/p33，I1 源选择 p32，而不是 RAT 中 x5 的旧映射。依赖比较与最终编号选择因此不再全部落在第二拍。

### 3.3 暂存、部分接受与恢复

第一版采用固定槽位与有效位保存一组，部分接受后保留原槽位编号，不与下一组立即合并。R2 接受前缀离开后，若剩余指令的已记录生产者已离开，就使用当前 RAT；仍在暂存中的生产者继续由本组新 preg 旁路。资源分配与 RDQ 输出按剩余有效指令的程序顺序形成连续前缀，避免物理槽位空洞影响现有接口。

本组全部离开时，可以同拍末接收 R1 的下一组；全部停顿或部分接受时回压 R1。等待不得重复分配。重定向清除被取消暂存指令，并禁止 R2 同拍年轻副作用；R1 没有预分配资源，无需新增归还事务。存活指令的分支 mask 需随解析清理。

原始 PC、长度、异常和动态 FTQ 身份/槽位始终随指令保存，目标字段按前端合同集成，不将旧接口永久冻结。

### 3.4 实现与验证边界

尚未修改 RTL。拟新增依赖预处理和级间暂存，以保存的比较/优先选择结果替代原 rename 内部的组内比较。保留已有资源规划和恢复机制。

后续验证：RAW/WAW 链、同名多写、x0/无目的指令、0～6 条、资源不足的部分接受、长停顿不重复分配、分支在组中不同位置的快照、恢复同拍取消。综合重点观察 free list、RAT 读、最终 mux 和资源回压；目前没有频率收益证据。

### 3.5 参考与不采用的内容

- Safi/Moshovos/Veneris，Two-Stage, Pipelined Register Renaming，2011：<https://www.eecg.utoronto.ca/~veneris/10tvlsi.pdf>。两级定制电路、依赖比较/跨组旁路/RAT 时序；130nm 电路仿真不等同 FPGA 实测。其半周期 RAT、第一拍取得 preg 不作为本版合同。
- Petric/Sha/Roth，RENO: A Rename-Based Instruction Optimizer，ISCA 2005：<https://acg.cis.upenn.edu/papers/isca05_reno.pdf>。Figure 4(a) 的普通两级基线分开依赖比较与源编号修正；move 消除、公共子表达式消除、推测访存旁路、常量折叠未被本设计选用。
- BOOM v4 本轮本地源码 HEAD `54f11b85c9a670ef3dd18bc675994b9a661b06ee`，不同于前端基线研究版本。`rename-stage.scala` 有 ren1/ren2 寄存边界，但同组比较在第二级 BypassAllocations，不能声称它采用本版纯依赖预处理。
- 香山固定提交 `e7bab53e66dfb3c4a1d11cf9519b0396f8576cae` 中提前查 RAT、Rename 给 robIdx、Dispatch 后实际 ROB 入队的分工只作参考，不采用为当前实现方案。

## 4. 访存现状与设计状态

访存主流程已按 2026-10-01 用户要求归档为下面 B03～B11。两路访存为暂行宽度方向；具体 Load/Store 组合、容量、bank 映射、端口与精确流水级数仍待确定，不默认为双读双写。已确认机制与参数未定可以同时成立。

### 当前源码证据（2026-09-30，只读）

- 校正：`backend.sv` 的 Memory IQ 配置为 `OLDEST_ONLY(1'b1)`（2026-10-01 再核对），不能据通用 IQ 的 ready/年龄选择逻辑声称当前 Memory IQ 已允许年轻访存越过队头发射。整个后端不因此等于顺序核。
- `load_store_unit.sv` 当前同拍组合 AGU、SQ 依赖查询、存储请求仲裁。DTCM 为可写 simple_data_sram，范围外访问仿真外部 memory；不是只有 ROM。仅一个 memory Load pending，另有可保持结果槽。
- `store_queue.sv` 已兼任 committed store buffer：执行填地址/数据/mask，ROB 提交标记 committed，队头在存储请求接受后 drain 并释放。未提交年轻项可取消，已提交项保留。
- Load 查询更老 Store，单个 Store 完整覆盖可转发；未知地址/数据或部分重叠保守阻塞。没有多 Store 字节合并。
- `load_queue.sv` 已有分配、地址、outstanding、代际响应检查和提交释放；未实现访存违例 replay。扩展多个在途请求后，事务身份寿命与代际回绕需重新闭合，不能仅靠现有一位 generation 宣称安全。
- 当前没有 DCache/MSHR/DTLB/PMA/PMP 访问流水、精确访存异常闭环。现有 drain 是 store 队头排出，不等于已经完成 FENCE/FENCE.I 的系统同步。

## 5. B03：首版访存组织与范围收缩（已定方向）

目标是在 KCU105 固定资源内先实现可验证、可测量的非阻塞访存，再按仿真、综合/布局布线与 FPGA 结果调优。以 Dcache 为公共数据访问组件：普通 load/store、PTW 实际页表读取和 L1 原子操作复用它；L2 缓冲 DDR 访问，DMA 通过下级协调入口接入。

```text
访存调度/地址执行 → LQ/SQ、依赖检查与重放 → 多 bank Dcache
                                          ↑ PTW + walk cache
                                          ↑ 原子操作
                                          ↕ MSHR / 回填 / 写回
                                     L2 + DMA 行协调 → DDR
                                          ↑ SD DMA
```

- 组相联、写回 Dcache，支持 hit-under-miss，并保留多个独立 miss 在途与同 line 合并能力。流水线等待与事务等待分开；一次 miss 不把整个访问流水线置忙。
- 多 bank 提供实际并行带宽；同 bank 仲裁，tag/meta 访问能力必须配套。不同 line 不保证不同 bank，不承诺两读一写无冲突。
- PTW 首版共享 Dcache，不作为独立目录共享者，也不采用 PTW 独立接 L2/Home 再探测脏 PTE 的旧建议。共享数据路径仍需满足屏障与旧请求取消合同。
- 首版只处理一个 hart 与 SD DMA 的必要一致性，不引入完整多核 MESI/MOESI 目录。
- 不取消 A 扩展；其执行方案见 B09。值预测不进入 CISLC-O3，本轮只保留为以后 Breeze V2 的研究方向。
- L2 不要求复杂多核目录，但下级不能静默成为全部访存的全局串行瓶颈：独立命中继续服务、多个下级请求的能力是设计目标，具体 L2/AXI 组织尚未冻结。

> **2026-10-07 B51：** 具体配置已定，见第 40 节（32KB/8 路/64B、8 个字 bank、4 MSHR、两条都能做 load 与 store 地址的管道）。

**尚属建议的具体配置**：16 KiB/4-way/64 B line/4 个数据 bank/8 个 L1 MSHR，以及“一条 load 地址流水线 + 一条 load/store 地址流水线”。这些不是已确认参数。bank 按整行或行内 word 映射也未冻结；最近建议偏向 word 交错，以避免相邻 load 集中到一个 bank。不能将这些例子升级成用户决定。

## 6. B04：Load 生命周期与事件重放（已定主流程）

1. R2 原子分配 ROB、LQ、目的物理寄存器，保存源编号、PC/长度、FTQ 身份以及恢复信息。
2. 地址源就绪后，由访存调度发射并计算虚拟地址；保存可复用的访问地址、大小与身份。
3. DTLB 翻译、页表权限及 PMP/PMA/访问边界检查完成后，才允许产生有效 load 结果。允许部分 cache 查询并行，不能提前交付未检查数据。
4. TLB miss 挂起相关 load，释放执行流水级；PTW 完成后重试。翻译/权限异常记录至原 ROB 项，不写有效结果，到提交边界精确进入异常。
5. 查询更老 SQ 项，选择按程序顺序正确的数据来源；SQ 与 cache 可并行查询，最终结果统一选择。
6. SQ 完整转发或 cache 命中后，提取字节并扩展，写回目的物理寄存器，唤醒依赖者并报告 ROB 完成。执行完成不等于退休。
7. ROB 按序退休后释放 LQ；分支恢复/异常取消的年轻 load，迟到响应不得写入已经复用的物理寄存器或队列项。

### 6.1 SQ 转发与等待

- 只从程序顺序更老的 store 转发；重叠字节必须满足最近有效旧写入的优先关系。不能任取一条同地址 store。
- 首版采用保守的单 store 完整覆盖转发。相关数据未就绪、部分覆盖或无法安全判定依赖时等待，不立即做多 store 与 cache 字节拼接。
- SQ 完整提供数据时，不因并行 cache 查询报告 miss 而无条件申请下级取数。
- 区分 SQ 数据转发、MSHR 同 line 请求合并、提交写缓冲合并、未知地址依赖推测；它们不是一个机制。

### 6.2 MSHR 与重放

- MSHR 跟踪行事务（地址、下级事务身份、回填状态）；LQ/重放记录跟踪 load 身份、目标 preg、等待原因与唤醒关系。
- cache miss 分配或合并 MSHR；资源不足则等待可用事件，不能伪造已发出状态。多个 load 可等待同一行，但各有指令身份。
- 首版先完成回填安装，再唤醒 load 重查 SQ/cache，不要求回填直接写回 preg。MSHR 完成不等于 load 已完成。
- 重放不重新 rename，不重新分配 ROB/LQ，也不要求退回普通 IQ；等待记录是放在 LQ 内还是独立队列，物理组织尚未冻结。
- bank 冲突、DMA 行保护、SQ 数据未就绪、MSHR 满等需区分等待原因，避免每拍盲目重试。
- 取消与响应身份寿命必须闭合；现有一位 generation 不能未经分析直接沿用为任意长多事务的安全保证。

**尚未冻结**：是否允许 load 越过地址未知的旧 store。起步可保守等待；后续可采用未知地址推测加违例冲刷重执行，不要求选择性重放。已知无关的旧访存不应成为目标版的固定队头阻塞原因。

## 7. B05：Store 生命周期、提交与后台 drain（已定主流程）

```text
R2 分配 ROB/SQ → 地址/数据准备 → 翻译与访问检查 → 执行完成
    → ROB 按序提交 → SQ committed → 后台写 Dcache → 完成确认后释放
```

- 普通 store 通常不分配目的 preg；SQ 保存地址、数据、字节 mask、就绪及提交状态。地址和数据是否分开发射尚未确定，不能把香山的优化当作首版前提。
- 执行完成要求地址、数据和提交前必要检查已具备，不表示已经写 cache。提交前不得产生目标 store 的可见写入。
- 普通 store 检查通过后允许 ROB 退休，再由 SQ drain；不采用所有普通 store 均留在 ROB 等 cache 写完的旧建议。
- 已提交 SQ 项不被年轻路径恢复取消；未提交项按恢复范围撤销。SQ 满允许背压。
- 首版 SQ 兼任 committed store buffer，按序 drain；先不新增独立 SBuffer，也不要求多笔 store drain 并发。（2026-10-07 B51：保持，另加 store 所有权预取，见 40.4 节。）
- cache 请求接受与写完成分开。命中写完得到确认再释放 SQ；miss/资源冲突/DMA 行保护时保留项，等待事件后重试，不重复发送仍在途的同一请求。
- 等待 drain 的 store，包括已提交项，仍可供年轻 load 转发。store 等 miss 不占住 bank 流水级，不全局阻塞独立 load 命中。
- 普通 store 写入 L1 成功即可释放 SQ；以后脏行排出由 cache 负责，不要求原 SQ 项等 DDR。
- 目标版对 MMIO/不缓存访问采取保守路径：到 ROB 队头、满足先前排序后发出，保留 ROB 等结果，成功退休，同步错误在原指令报告。不可把香山文档中的 NonCacheable 提交后路径等同本方案。

## 8. B06：翻译、权限与精确同步异常边界（已定原则）

- TLB hit 不等于访问许可，PMP 成功也不能替代页表翻译及页表权限检查。目标物理地址和 PMA 属性确定后才能完成访问分类。
- TLB miss 不是异常：等待 PTW，成功后与 hit 路径具有相同资格；不因为曾经 miss 就要求普通 store 等 cache 最终写入才退休。
- page fault、PMP/PMA 拒绝及访问边界等同步错误保留原指令身份，向 ROB 报告。故障 VA 与内部 PA 分开保存，不混作异常地址。
- PTW 自身读取页表的物理权限检查，与最终目标访问权限检查分开。
- 普通可缓存标量非对齐访问按 B31：同 line 硬件支持、跨 line 报非对齐异常，不建立双页拆分完成通路；权限检查覆盖全部访问字节。（2026-10-07 B49 取代：跨 line/跨页由硬件拆成两次访问完成，两半分别翻译与检查。）A 扩展首版自然对齐限制见 B09。
- 将来写回的硬件故障不能静默丢弃，也不能伪装成已退休原 store/AMO 的精确异常；硬件错误报告方式待特权/异常设计闭合。
- 本记录固定访存端异常合同；统一异常入口、CSR、xRET、中断边界随后已按 B22/B26/B27 确认，剩余集成审查见 B29。

## 9. B07：共享 Dcache 的 PTW、walk cache 与预取（已定方向）

- PTW 使用 Dcache 物理访问入口，不递归翻译页表地址；与需求访问仲裁，共享最新数据、miss 处理与下级接口。
- 增加小型 walk cache 减少重复页表遍历。缓存层级、条目组织/容量未定；必须具有足够上下文以满足 D26 的 VA/ASID 定向规则，不擅自改为全清。
- PTW 仲裁与资源分配必须保证前进；等待翻译的请求不能占尽其依赖的 cache/MSHR/回填资源。具体保留份额待定。
- SFENCE.VMA、satp、PMP 更新及旧 PTW 迟到响应隔离继续遵循前端 D26～D28；共享 Dcache 不取消这些要求。
- 页表写入后执行 SFENCE.VMA，首版按 B24 等待 SQ 全量排空，确认更早 store 已写入共享 DCache 且后续 PTW 可从该路径看到新值；不要求为此全量写回 L1D 或 DDR。
- stride 地址预取列入本代计划，与值预测分开。先建立需求访问基线；预取需去重、限流、遵守可访问区域，不能读取有副作用的 MMIO，不因预取失败产生普通指令异常。
- 预取可能占带宽、MSHR 并污染 cache；通过 useful/late/unused 和资源竞争计数评价，不能称为零代价。

## 10. B08：SD DMA 按行 clean+invalidate 协调（已确认首版方案；2026-10-07 由 B50 取代）

> **2026-10-07 B50：** DMA 改为 Breeze MESI L2 Home 的一致性 DMA 客户端，本节行事务流程不再实施，见第 39 节。

SD DMA 是当前系统需求。第一版只允许一笔 DMA 行协调事务在途；所有 DMA 行事务探测唯一 L1D，不要求多核目录过滤或共享者向量。PTW 和 AMO 不作为另外的缓存客户端。

### 10.1 行事务流程

1. L2 入口协调器登记目标物理行；Dcache 接受保护请求后阻止该行新的普通 CPU 访问与 AMO，其他行继续。
2. 目标行已经接受的访问完成到安全边界；已有 miss/refill/writeback 必须继续获得服务，并协调至不会有旧数据迟到重新安装的状态。
3. 对目标行 clean+invalidate：缺失则确认无副本；干净副本失效；脏副本先将最新数据可靠交给 L2，再完成失效确认。
4. Dcache 返回 quiesced 后，L2 执行 DMA 读或写。部分行写用最新数据保留未覆盖字节。DMA 不能绕过仍可能持有最新数据的 L2 直接读旧 DDR。
5. 事务所需的数据/一致性动作完成后解除行保护，唤醒 CPU 等待者，按接口约定返回 DMA 完成。

首版 DMA 读也清理并失效，接受随后 CPU 再次 miss 的代价；以后由探针决定是否增加不失效读取，不把该优化当作已定功能。

### 10.2 行保护与前进

- 逻辑上需一条 busy + physical line address 记录，具体字段和握手编码未定。
- 不能仅靠扣住 L2 响应实现保护：L1 hit 不经过 L2。目标行的新请求在 Dcache 接受/执行边界等待或重放。
- 不能堵住完成旧事务所需的响应、回填、写回和探测应答，否则 DMA 与 cache 会互等。包括跨行替换造成的资源依赖，也要列入验证。
- probe 使用维护队列和 bank 仲裁；不是只找空闲 bank，也不能在持续 CPU 请求下永久饥饿。阵列竞争会造成等待，但不预先给每次普通命中增加一致性流水级。
- DMA 协议不替代软件缓冲区交接和 FENCE：启动前应保证先前写入达到 DMA 可见点，完成后才允许消费结果。SQ 未 drain 的数据不能靠 Dcache probe 自动看见。
- DMA 数据一致性不自动替代 FENCE.I 或 SFENCE.VMA。

## 11. B09：A 扩展执行与精确异常（已定基本路线，前进性细节待闭合）

> **2026-10-08 L8b：** AMO/LR/SC、MMIO 与 B49 跨行拆分统一由 ROB 队头执行单元（HEU）执行，启动条件为队头且已提交 SQ 排空；reservation 清除表按 B35 修订注记。见 [L8b spec](../spec/l8b-atomic-mmio-dma-spec.md) 第 4、5 节。

A 扩展分为 AMO 与 LR/SC；reservation 不是乱序调度的保留站。首版在 Dcache 内增加低吞吐原子执行入口，一次处理一条，不复制完整 LSU，不用普通 store 提交后 drain 来拆开原子读改写。

### 11.1 AMO

- 支持 RV64A 所需 .W/.D 及 swap/add/逻辑/min/max（有符号与无符号）语义；.W 旧值返回按规范符号扩展。
- 位于 ROB 队头，地址/权限/自然对齐/PMA 原子支持检查通过，满足先前访存排序后才实际执行。首版不支持非对齐原子访问；不支持原子访问的区域报适当异常，不模拟成普通读写。
- miss 通过 MSHR 等数据，不长时间占 bank；取得有效数据和执行资源后，在短窗口保护目标行，完成读—运算—写，返回旧值。
- 与 DMA 对目标行互斥；CPU、PTW 等同地址冲突访问也不能插入读改写窗口。其他无冲突行可继续。
- 写入前确保完成结果有保存空间；真正修改后即使写回端口背压，也只等待交付，绝不重执行 AMO。普通中断在此不可撤销窗口内延后处理，统一入口遵循 B26。
- 保留 ROB，结果确定后退休。目标数据修改前发现的同步错误报告至原 ROB；AMO 异常按 store/AMO 类，不能因内部读操作改报普通 load 异常。

### 11.2 LR/SC

- 每 hart 一条独立 reservation 记录（valid、物理地址/保留范围）；范围与具体清除事件表待定。LR 成功读取后建立记录并独立退休，不把 ROB 从 LR 一直锁到 SC。
- SC 第一版先完成地址和访问检查，再不可分割地检查 reservation 并条件写入。成功写入返回 0；保留失效则不写入，返回非零（首版可取 1），这不是异常。SC 执行成功/失败均清除 reservation。
- LR 故障按 load 类；SC 故障按 store 类。新的 LR 替换旧记录；上下文切换/异常清除合同需和未来特权流程闭合。
- reservation 与 cache tag 分开：单纯 clean、替换或 DMA 读导致的失效不必清除。SC 可重新取行后再校验；DMA 写与保留范围冲突必须清除，且与条件写入具有明确顺序。
- DMA probe 必须保留读/写意图，不把所有 invalidation 无区别地转成 reservation 清除。
- 受约束 LR/SC 循环的前进保证是必需项。公平仲裁、替换/重放影响和异常边界尚需验证；不能仅靠 reservation 位和“允许偶发失败”声称合规。

### 11.3 排序与证据边界

- 保留 aq/rl 字段。首版采用较强排序：阻止年轻访存越过原子指令发射，在队头等待先前访存完成至所需顺序点，原子操作完成后放行。
- 较强排序是性能取舍，不等于只等旧 ROB 退休；已提交但尚未 drain 的旧 store 仍需考虑。
- 此路线可以满足 A 扩展，不等于 RTL 已通过合规验证；LR/SC 前进性、DMA 冲突、异常、内存顺序都需单独验证。

## 12. B10：事件计数与性能归因（已确认加入）

首版使用硬件计数器，仿真增加事件轨迹；不立即引入大容量硬件逐事件日志。读取、清零、统一快照接口需保留，ABI/位宽待定。

> 2026-10-06：读取 ABI 由 B48 确定为 RISC-V Zihpm + Sscofpmf，本节事件进入统一事件编号表，见第 37 节。

| 逻辑事件 | 口径 |
| --- | --- |
| dma_line_transactions | DMA 行事务总数 |
| dma_line_lock_cycles | 行保护有效周期 |
| dma_conflict_loads / stores | 请求因行保护首次进入等待的次数，重试去重 |
| dma_conflict_cycles | 至少一项 CPU 请求被行保护阻塞的周期，同拍不按请求数重复累计 |
| dma_wait_dcache_cycles | DMA 等待旧事务收尾、脏数据交接的周期 |
| ROB 队头直接 DMA 等待 | 队头访存直接因 DMA 保护未完成而不能退休的周期 |
| ROB/SQ 等资源满 | 独立统计，不能因 DMA 同时活跃就全归因 DMA |

同一 load 等十拍记一条冲突请求和相应等待周期，不记十条冲突。load 等待周期不等于整核停顿周期；间接依赖链影响需轨迹或对照实验。

同时保留 bank 冲突、MSHR 占用/满、miss 在途时 hit 完成、SQ 转发与等待、PTW/walk cache 及预取效果的观测。事件名是逻辑口径，不是已冻结的 CSR 编码。

仿真轨迹至少能关联：DMA 保护开始、请求首次冲突、Dcache 清理完成、DMA 完成/解锁、请求重发与完成。

## 13. B11：实现边界与后续主题

### 13.1 仍需细化，但不重开已定主流程

- LSU 发射组合与地址/数据拆分；cache 容量、路数、bank 映射、端口、流水级与 BRAM 映射。
- LQ/SQ/MSHR/写回/回填容量、身份编码和生命周期；资源保留、仲裁公平性与死锁审查。
- 未知旧 store 地址的推测策略、访存违例恢复；B31 已定同 line 非对齐支持，内部拆分/拼接与异常事件接口待落实。
- L2 在途请求与 DDR/AXI 接口；DMA 行协调和在途 fill/eviction 的完整竞态表。
- Sv39 大页/ASID/global、A/D 更新和 walk cache 的具体组织；FENCE 完成握手与 D25～D28 集成。
- LR/SC 前进保证与 reservation 清除表；MMIO/不缓存异常、晚到硬件错误报告。
- 以上为实现前细化清单，不将“字段未定”说成机制不存在。

### 13.2 验证分层

先验证 LSU/cache 单元：转发选择、MSHR 合并与资源满、回填唤醒、取消后迟到响应、SQ 交接与重试；再验证 DMA 同行/异行/部分写/脏行/在途回填竞争及 AMO/LRSC。之后集成 PTW、屏障和整核异常/恢复，用架构测试与内存顺序用例检查。编译、仿真、形式性质、布局布线时序、FPGA/Linux 运行和性能测量分别记录。

### 13.3 讨论进度（2026-10-02 校正）

访存归档之后，已继续讨论分支、乘除法、浮点及 B22～B29。下一窗口审查整核机制闭环，每次只处理一个真正未决的选择；不再以“统一中断暂缓”或旧 FU 讨论顺序为议程。参数和字段未定、框架未接通与机制未定分开列出。

## 14. 访存参考资料与版本边界

- [RISC-V A 扩展 2.1（20240411 固定页面）](https://docs.riscv.org/reference/isa/v20240411/unpriv/a-st-ext.html)：原子语义、aq/rl、设备写与 reservation、受约束 LR/SC 前进保证；具体实现可保守，但需验证。
- 香山 [昆明湖 V2 StoreUnit](https://docs.xiangshan.cc/projects/design/en/kunminghu-v2/memblock/LSU/StoreUnit/)、[StoreQueue](https://docs.xiangshan.cc/projects/design/zh-cn/kunminghu-v2/memblock/LSU/LSQ/StoreQueue/)、[Dcache MainPipe](https://docs.xiangshan.cc/projects/design/zh-cn/kunminghu-v2/memblock/DCache/MainPipe/)：地址/数据分离、提交缓冲与维护流水线。参考页的拍数、容量、NonCacheable 路径不是本设计合同。
- 香山 PTW 曾核对提交 `e7bab53e66dfb3c4a1d11cf9519b0396f8576cae` 的 `src/main/scala/xiangshan/cache/mmu/L2TLB.scala`：独立 Get、sfence 与 flush_latch。独立 PTW 路线现已退出本代首版；文档与提交不混为同一版本。
- BOOM v4 `54f11b85c9a670ef3dd18bc675994b9a661b06ee` 的 `src/main/scala/v4/lsu/lsu.scala`：committed/succeeded、转发、访存顺序恢复。不能把后端参考提交与前端另一提交混用。
- [The BlackParrot BedRock Cache Coherence System，2022 v1](https://arxiv.org/html/2211.06390v1)：L1 原子操作、目录事务、不保留副本的一致性请求。源码曾核对 `fc7c4ae5ad6b21143afc4f378a678bafa422681b` 的 `bp_be/src/v/bp_be_dcache/bp_be_dcache.sv` 和 `bp_me/src/v/cce/bp_cce_fsm.sv`；源码与论文不是同一版本，未在本任务编译/仿真。
- [A Primer on Memory Consistency and Cache Coherence，第二版，2020](https://pages.cs.wisc.edu/~markhill/papers/primer2020_2nd_edition.pdf)：一致性、内存顺序、原子读改写及瞬态竞争。
- [HPDcache，DATE 2024](https://past.date-conference.com/proceedings-archive/2024/DATA/10009_pdf_upload.pdf)：流水化非阻塞 cache、MSHR 与写缓冲参考；论文中的写穿策略不是本设计选择，报告的性能/面积不是我们的证据。
- [Evaluating the Cost of Atomic Operations on Modern Architectures](https://arxiv.org/pdf/2010.09852)：PACT 2015 的扩展版，测试旧 Intel/AMD 微架构，不代表当前 Zen。
- [Analyzing the memory ordering models of the Apple M1，2024](https://www.sra.uni-hannover.de/Publications/2024/wrenger_24_jsa.pdf)：测量分析，不是 Apple RTL 或内部一致性协议的官方披露。

后续修改记录日期、原因与证据。早期的独立 PTW/完整 Home 设想、所有普通 store 等写完再退休、以 TLB hit 概率决定安全性等说法，均不得覆盖本文后来明确的合同。

## 15. B12：分支/跳转后端只读审计（2026-10-01，BRU 组织已确认）

承接前端第 16 节、D08/D09/D22/D23/D24；不重开预测器设计。本节区分当前代码、必须满足的既有合同和建议。目标仓库再次核对为 develop、HEAD `06462b0ebd48cecf0af34b8a87a90a365561894b`，仍只有两项既有未跟踪仿真 JSONL；适用父目录及目标源码/文档子目录未发现 AGENTS.md。本次未修改目标 RTL，未运行编译、仿真、时序或 FPGA 测试。

### 15.1 当前已经连接的正常路径

- `decoder.sv` 支持 BEQ/BNE/BLT/BGE/BLTU/BGEU、JAL、JALR，三类控制流都申请 checkpoint；Dispatch 分流到独立 Branch IQ。
- Branch IQ 单发射，选择最老的操作数已就绪项，允许跳过未就绪的老分支。条件分支等待两源，JAL 无寄存器源，JALR 等待 rs1。IQ 写回唤醒在下一拍参与选择，没有同拍 wakeup-select。
- `backend.sv:640` 起的共享 PRF 读仲裁按 ROB 年龄比较 Integer/Memory/Branch 候选。必须原子获得全部所需读口且 RegRead 可接受，才从 IQ 删除；失败则保持 IQ 项。
- 读值锁存到 `branch_regread_q`；独立 `branch_execute_unit.sv` 是组合执行逻辑，比较条件并计算直接目标、JALR 清 bit0 后目标、实际下一 PC 及链接值。结果在后一个边沿进入 `branch_result_q`，不是 BRU 内部多级比较流水。
- 当前误预测条件为实际下一 PC 与 `predicted_next_pc` 不同。结果槽广播解析一次，`branch_resolution_sent_q` 防止链接值背压期间重复解析；解析不等链接值取得 PRF 写口，也不等提交。
- 无目的写入的条件分支及 rd=x0 跳转由解析网络完成 ROB；写 rd 的 JAL/JALR 竞争共享写口，PRF 写入、唤醒、ROB 完成随写回 grant 一起生效。结果等待时保留，反压前级，不能重执行或覆盖。
- 相对时序：C0 选择/仲裁/读 PRF，末端锁存 RegRead；C1 组合执行，末端锁存 Result；C2 结果解析，并在有写口时交付链接值。ROB 之后按序退休，不把 C2 称为提交。

### 15.2 误预测恢复与当前缺口

已有代码按 branch mask 撤销年轻项；RAT 从分支自身之后的快照恢复，free list 回收该分支之后的分配，ROB/LQ/SQ tail 从 checkpoint 恢复，checkpoint 文件释放本分支及年轻后代。分支自身和更老指令保留，JAL/JALR 自身的新目的映射保留。RDQ/IQ、LSU 及写回端有取消路径，Decode Queue/fetch 暂存清除错误路径。

但不能据此称分支后端已完备：

1. **解析造成全局暂停**：当前任何 `branch_resolution_i.valid`（包括预测正确）都阻止 IQ 选择、读口授予、rename/dispatch 和 ROB 退休。这是当前实现的保守控制，不是前端合同要求；不能从单发射 BRU 推出整合后能持续每拍处理一条分支。
2. **停顿 ALU RegRead 的取消风险**：`backend.sv:1750` 附近，当年轻 `alu_regread_q` 所在 ALU 的旧结果未取得写口，`alu_regread_ready=0`。若此拍发生误预测，代码只通过 `resolved_branch_mask` 清位，没有独立清除该年轻槽的 valid。之后旧结果被消费时，这条年轻指令可能已失去取消标记并进入结果槽。写回仲裁对已有 Result 的 kill 不能替代 RegRead 的 kill。此为静态控制路径发现，尚未由定向仿真复现；后续必须验证“较老结果背压 + 年轻 RegRead + 分支误预测”组合。
3. **目标设计恢复接口尚未落实**：当前解析结构携带 `ftq_idx/branch_pc`，未携带完整动态 FTQ 代际、显式槽位及历史/RAS 恢复引用；尚未实现 D24 多来源完整请求仲裁和恢复完成握手。前端历史/RAS 恢复、提交训练及 FTQ 生命周期按既有基线实施，不能因当前 RTL 缺失就重新列为未讨论机制。
4. **目标与异常边界**：BRU 尚无执行异常输出；现有 `PC_WIDTH=39` 会把目标运算截为 39 位，不能据此证明 RV64GC/Linux 所需的完整目标地址检查。运算已用 `inst_len` 计算顺序 PC/链接值，可承接原始 2/4 字节长度，但不等于 RVC 整条集成已验证。统一异常入口承接 B26；本条源码缺口仍须以新窗口实时审计为准。

按目标合同，获胜执行重定向须立即禁止被取消年轻指令的副作用，恢复后端推测状态，并让前端恢复对应 FTQ 入口 E/C 与 RAS 状态、应用真实控制流，再开始正确路径预测。2026-10-02 D29/B30 将 RAS undo 替换为入口索引/占用数/栈顶修复，并给出固定短恢复目标；恢复期间出现有效的更老请求按 D24 替换。预测表仍提交训练，不能把“立即恢复”改为“立即训练”。

### 15.3 本轮只提出一个实现选择

**2026-10-01 用户确认**：沿用独立单发射 BRU，保留“RegRead → 组合执行 → Result 保持”的寄存边界，以及“解析/重定向与链接值写回解耦”的组织。暂不增加第二条分支执行管线，也不增加比较器内部流水级。

资源代价为一套条件比较/目标运算和两个可保持槽；共享 PRF 端口继续可能造成等待，JAL/JALR 写回背压也可能延迟后续分支执行。后续先修正确性及落实既有恢复接口，记录 branch-ready 等待读口、结果槽阻塞、解析暂停周期、误预测到正确路径重新交付的周期；基于综合/时序和性能证据再调整。预测正确时是否消除全局暂停属于之后的局部控制优化，本轮未确认，更不能声称已实现。

## 16. B13：整数乘除法 FU（加入范围已定，具体结构为建议）

2026-10-01 用户要求继续加入整数乘除法及 F/D 执行单元。当前仍处于设计讨论，不修改 RTL。

- 当前 `rtl/backend/mul_execute_unit.sv` / `div_execute_unit.sv` 支持相应运算语义，但未接入当前 backend，decoder 尚未接受 M 扩展编码。
- 两模块在请求接受时组合算完整结果，再用固定计数器延迟返回；乘法使用 `*`，除法/取余使用 `/`、`%`。这不是已切开运算关键路径的真实多拍微结构，也没有结果 ready 或指令身份/取消接口。
- 建议一个可流水乘法 FU（MUL/MULH/MULHSU/MULHU/MULW），以及一个迭代除法/取余 FU（DIV/REM 及 unsigned/word 变体）。除法忙不阻塞乘法或普通 ALU；具体乘法 DSP 映射/切分、除法 radix、拍数、IQ 和端口以后单独落实，不把旧计数器参数冻结为目标延迟。
- 每笔接受请求保存 ROB/动态身份、目的寄存器及恢复关系；输出 valid/ready 保持结果，真正获得整数写口时完成 PRF 写入、唤醒及 ROB 完成。被取消运算可以提前终止或完成后丢弃，但不得覆盖复用后的寄存器；结果和请求槽身份寿命必须闭合。

## 17. B14：复用 Breeze 流水化 CVFPU，拆为后端 FU

### 17.1 用户确定的范围与版本核对

用户指定复用 Breeze 为 100MHz 调整过的 FPU，保留内部运算及流水改动，拆出独立 FMA 和其他 FU，不沿用当前 Breeze 统一顶层包装的接法。

本轮实时核对 Flow HEAD `8ccdfb261dabdc79381cf66f7792bdabcf204695`；CVFPU 子模块 HEAD `1b220f3bc89df99e246b72e3574a3a533cf87653`，子模块工作区干净。其提交包含 `cdb4c70` 的 FMA 加法前切分以及 `1b220f3` 的转换舍入前切分。当前 `FlowFpnewWrapper.sv` 配置：

- 标量 RV64D（FP32/FP64），`DISTRIBUTED`。
- ADDMUL：FP32 3 个流水寄存边界，FP64 4 个。
- DIVSQRT：THMULTI，配置 2 个寄存边界；不代表迭代运算只需两拍。
- NONCOMP：1；CONV：4，保留舍入前弹性流水级。
- ADDMUL/NONCOMP 按格式 PARALLEL；DIVSQRT/CONV 为 MERGED。拆分首版保留这些配置，不暗中改成共享一套 S/D FMA 数据通路。

**2026-10-11 用户更新**：复用 Breeze 后续增加的 FPU 算术流水切分，两个对称 FMA
均采用 FP32 5 级、FP64 7 级 `DISTRIBUTED`。本次实时来源为 Flow
`2051dd0bb9a0c701bb95fd3f1e755ae175023093`、CVFPU
`23153ba10a0ab8c6ee774b5e1a928007c3b2adcc`（相对上述 `1b220f3` 只改 `src/fpnew_fma.sv`）。
FP32 边界为输入、加法前、和、未舍入规格化、舍入结果/状态；FP64 额外在宽移位前
寄存对齐控制与规格化控制。级数不包含 O3 的 RegRead 和包装结果保持槽。
FMA 允许多个请求在途，接受仍由原生 ready 与每 FU 的 8 项身份容量共同限制；
结果背压时保留身份到 WB 或取消排空。CONV 舍入前切分已在原版本内，沿用 4 级。
先迁移流水 RTL 和补测试代码，功能验证按用户安排暂缓；用户后续授权后端独立 OOC 综合，
结果与边界见 [后端重构报告](../tasks/O3-backend-refactor-ooc-report.md)。

`docs/linux/act4-single-regression-20260911.md` 保存了相同 CVFPU 提交在 Flow 集成下的 F 82/82、D 114/114 历史测试记录。本轮仅核对记录，未重跑；这些不是 CISLC-O3 的测试证据。Flow 后来的单核 100MHz 板级记录也不能证明拆分后的新乱序核心达到 100MHz；本轮未追溯相同 bitstream 的完整 FPU 构建链。

### 17.2 已确认的分组与数量（2026-10-01 更新）

| 目标 FU | 操作 | 复用层次 |
| --- | --- | --- |
| FP-FMA/ADDMUL ×2 | 每个支持 FADD/FSUB、FMUL、四种 fused multiply-add，S/D，由 uop 选择运算 | 两套 ADDMUL opgroup，保留内部 `fpnew_fma.sv` |
| FP-DIVSQRT ×1 | FDIV、FSQRT，S/D | DIVSQRT opgroup，保留 THMULTI |
| FP-MISC ×1 | FSGNJ/FMIN/FMAX、FEQ/FLT/FLE、FCLASS，S/D | NONCOMP opgroup |
| FP-CONV/MOVE ×1 | FCVT.S.D/D.S、浮点与 W/WU/L/LU 转换；FMV 位搬运由薄包装处理 | CONV opgroup + 原始位搬运逻辑 |

用户确认第一版两个相同的 FMA/ADDMUL 单元；每个按 uop 执行加、乘或融合运算，其他三组各一个。独立 FMA 是从统一 FPU 外壳中拆出算术 FU，不把 fused 指令拆成先 MUL 再 ADD；必须维持一次舍入。不另设专用 FADD 或 FMUL FU。

可以例化五个 `fpnew_opgroup_block`（两套 ADDMUL，加另三组），保留需要的 format slice 与算术叶模块，替换 `fpnew_top` 的统一输入分流/输出仲裁。各 FU 有独立 in/out valid/ready、在途身份和结果保持，分别竞争目的寄存器域的写回。不能继续用 `busy` 把整个 FP 子系统锁成一次只能做一条。两条三源 FMA 同拍发射最多需提供六个源值，结果也可能同拍竞争写口；这些是带宽需求，不是已经冻结六读双写端口。IQ 组织、端口和整体发射宽度仍待落实，不能从 FU 数量直接推出五发射。两套 ADDMUL 首版均保留原有 S/D 格式组织，新增资源需后续综合检查。

移除顶层时必须迁移其语义：输入 NaN-box 检查、输出扩展/boxing、分类结果及整数结果处理。FMV 是位搬运，不能错误套用普通算术的 NaN 替换规则；单精度写 FPR（包括 FLW）保持规定的 NaN-boxing。复用 opgroup 层可减少手工重接 format 和结果扩展的风险。

当前包装 `TagType=logic` 且 tag 固定 0；新包装必须携带唯一请求身份。建议用请求槽号及代际关联侧表中的 ROB、目的域/preg 和当前分支依赖，正确解析时更新侧表，误预测时标记年轻请求 killed。不能把原生 `flush_i` 当作按年龄取消：它会清掉同一 FU 中仍有效的更老操作。首版可让 killed 运算完成并在出口丢弃，槽位保留到返回终结；结果身份不能提前复用。是否加入内部选择性 kill 后续按恢复开销决定。

### 17.3 商业参考的核对边界

本轮核对 Arm Cortex-A76 Software Optimization Guide，Version 8.0，PJDOC-466751330-7215，§2.1（印刷第 7 页）、§3.11（第 18～19 页）、§3.12（第 20 页）：两条 FP/ASIMD 执行流水线存在功能不对称；浮点除法/开方使用 V0，转换、位搬运也有具体路径归属。公开资料支持按资源能力调度、区分长延迟运算和转换通路，但不是其内部 RTL 的全部切分图，更不能说所有商用核心都按本节四组组织。

来源：[Arm 官方指南](https://documentation-service.arm.com/static/5ed4bd67ca06a95ce53f917d?token=)。本节四组建议主要依据本地固定版本 CVFPU 的既有 opgroup 边界及 KCU105 复用成本，不复制 A76 的 SIMD 宽度、FU 数量或延迟。

## 18. B15：独立浮点重命名，64 个物理浮点寄存器

2026-10-01 用户要求浮点寄存器重命名、数量 64。本记录按 **32 个架构 FPR 映射到 64 个 64 位物理 FPR** 理解并记录；不是将 RISC-V 架构 FPR 扩成 64 个。容量参数化，首版取 64。

- 增加 FP speculative/committed RAT、FP free list、FP ready 状态以及分支恢复所需的 FP 映射快照和分配记录；与整数域分开。`f0` 是正常可写寄存器，物理 FP 编号 0 也不照搬整数 p0 的恒零逻辑。
- 原始内容 `64*64=4096 bit`，不是整个多端口 FPR 的 FPGA 资源估计；读口复制、写口仲裁、旁路和 checkpoint 另计。32 个架构映射占用后，初始可用重命名预算为 32 个目的版本，不等于最多只能有 32 条浮点指令在途。
- R1 的同组 RAW/WAW 比较增加整数/浮点域与第三源；R2 原子分配相应目的域的 preg、ROB、LQ/SQ 和 checkpoint，不将 FP RAT 更新另拆一拍，不要求普通整数指令消耗 FP preg。
- 每个源和目的带寄存器域及有效位；FMA 有三个 FP 源；FCVT/FMV、比较/分类可跨整数和浮点域。FMV.X/FCLASS/浮点比较写整数 PRF，FMV.F/I2F 写 FP PRF，不能按所在 FU 推断目的域。
- FLW/FLD 使用整数地址源、写 FP preg；FSW/FSD 使用整数地址源和 FP 数据源，进入既有 SQ，提交与 drain 遵守 B05；不会因为是浮点指令而绕过访存合同。
- 写回只在结果仍有效且获目的域写口时写 PRF、置 ready、唤醒并报告 ROB；按序提交更新对应 committed RAT、归还该域 old_dst。分支恢复保留分支及旧指令，撤销年轻 FP 映射与分配，并隔离 FU 的迟到结果。
- 算术 status 的五个 fflags 先随该指令存 ROB，退休时按程序顺序并入架构 fflags，错误路径不更新架构状态。dynamic rm 必须读取程序顺序正确的 frm 并随请求锁存，不能使用执行时任意当前值；与 frm/fflags/fcsr 的 CSR 读写、FS Off 检查及 Dirty 状态的精确边界随后续 CSR 设计闭合。相关 CSR 首版统一采用 B22 串行化；fflags 退休合并、FS 状态和 trap/xRET 的同拍仲裁仍需落实。

示例：`fmadd.d f1,f2,f3,f4` 将 f1 的新版本分配为 fp32；随后 `fadd.d f1,f1,f5` 的源使用 fp32，目的另分配 fp33，old_dst=fp32。若分支位于两条之间，恢复保留 fp32 映射并回收 fp33；不得取消那条更老的 FMA。

本轮仅更新独立后端设计记录；前端合同继续由第 16 节互相引用，不修改现有前端及目标后端 RTL。FP 分组及数量已经确认；整数乘除法的最终来源与阶段边界见 B21，B16/B17 的 Vivado 选择已被后续决定替代。

## 21. B18：复用 Breeze 自研整数乘除法（2026-10-01，源码已核对，替换建议待确认）

状态：本节的源码核对继续有效；来源已按 B21 确认。B19 曾讨论另写优化数据通路，但后续用户明确沿用 Breeze 乘除法算法与数据通路，不能再将 B19 当作首版方向。

用户询问是否可以改用 Breeze 当前自研实现。建议可以复用算术数据通路，重新适配 O3 FU 控制；此前 B16/B17 的 Vivado 路线可作为后续资源/时序评估的备选。这里没有声称用户已经确认替换，更没有修改或集成 RTL。

- 当前 `BreezeBackend.scala` 实例化 `RiscvMulUnit` 和 `RiscvDivUnit`。乘法内核 `design/src/main/scala/multiplier/SignedMul65x65.scala` 是 signed 65×65、130 位积，Booth 部分积与 Dadda 压缩树分两级，最后一级进位传播加法；代码有三道寄存边界，延迟 3 拍、启动间隔 1。不是组合乘法后加倒计时。Breeze 在后端做 sign/zero extension，包装选择 MUL/MULH/MULHSU/MULHU/MULW 的结果。
- 除法内核 `design/src/main/scala/divider/UnsignedRadix4Divider.scala` 单请求迭代，每拍串联两步 restoring radix-2 运算，外层每拍处理两位商。按操作数最高有效位对齐，最多 32 次迭代；该数字不是包含输入预处理、接收和输出保持的 FU 总延迟。`RiscvDivUnit.scala` 恢复商/余数符号并做 W 结果符号扩展；Breeze 后端另外处理有效输入、绝对值、除零和有符号溢出。移植必须包含这些语义，不能只复制包装。
- 当前包装没有输出 ready；乘法全局 flush 清空全部有效 token，除法 flush 终止当前请求。O3 必须携带 ROB 身份及复用代际、目的物理寄存器和恢复信息，逐条取消年轻操作，保留老操作。除法只有一个在途请求，可依据其身份决定是否 abort；乘法流水中可能同时有老/年轻操作，不能整体 flush。
- 乘法流水不能停顿，需在发射时为必然返回的结果预留缓冲容量，写回竞争时保持结果；除法的单拍 out_valid 同样需要结果保持。具体缓冲容量、端口和仲裁尚未冻结。
- （**2026-10-05 由 B47 取代：手工翻译为可读 SV，生成的 Verilog 只作等价对照**）Chisel 算术 RTL 生成普通 SystemVerilog 后可加入现有 Verilator 工程，同一数据通路也用于 FPGA 综合，不需要厂商加密仿真模型。仍要整理生成入口、文件依赖以及验证断言的仿真/综合处理，不能假定现有 Breeze 测试直接覆盖 O3 包装。

现有源码包含乘法数值/流水/flush 测试和除法定向、随机、flush 测试；本轮只阅读，没有重跑。没有获得本核心接入、编译、仿真或 100 MHz 时序证据。乘法为手写压缩树，不能假定会自动充分利用 FPGA DSP；除法一拍两次串联比较/减法也是需测量的时序路径。资源/时序评估后再决定是否改数据通路或使用 Vivado 备选，维持前端第 16 节接口及 B12 恢复合同。

## 24. B21：最终范围澄清与下一窗口交接（2026-10-01，已定）

### 24.1 本轮最终决定

- **讨论阶段**：继续微架构设计，尚未进入 RTL 实施。用户说明“将 Breeze 乘除法改为 SV 加入 CISLC”是在澄清未来实现来源，不是要求立即转写、集成或运行测试。本轮只更新文档。
- **复用范围**：仅整数乘除法对应的算法和数据通路，不扩大为整个 Breeze 后端/整核复用。CISLC-O3 继续从现有 rename、IQ、PRF、ROB、恢复及访存框架演进，不预设全部重写。FPU 的独立来源与拆分决定仍见 B14/B15，不能从“乘除法复用”推导其他模块复用。
- **乘法**（**2026-10-05 由 B43 取代：改用 DSP 实现**）：沿用 `SignedMul65x65` 的 signed 65×65 Booth/Dadda/末级加法三级实际运算流水及启动间隔 1 的方向，保留 RISC-V 乘法变体所需的输入扩展和结果选择。未来转写 SV 后的周期对齐、O3 包装额外延迟、资源及时序须独立验证。
- **除法**：沿用 `UnsignedRadix4Divider` 的单请求、按有效位对齐、每次迭代两步 restoring 运算方向；最多 32 次迭代不是整个 FU 固定延迟。包含后端原有输入/绝对值预处理、除零与有符号溢出、商/余数符号恢复及 W 语义。未来转写 SV，不在本阶段换成 radix-2 或全流水除法。
- **资源优化后置**（乘法部分已由 B43 提前）：先形成可验证、可测量的整合版本并加探针，再依据仿真、时序和 FPGA 数据优化。当前不引入 Vivado 算术 IP 或 DSP primitive，不把历史 Breeze 报告作为新核心达到 100 MHz 的证据。

### 24.2 已定合同、未闭合细节、实现缺口

| 机制 | 已定合同 | 仍需讨论或实现的内容 |
| --- | --- | --- |
| 分支执行/恢复 | 单 BRU，RegRead→EX→Result 保持；解析/重定向与 JAL/JALR 链接值写回解耦；执行纠错、提交训练 | 按 B12 落实 D24 统一恢复接口；背压槽的年轻操作取消；正确解析暂停是否优化；异常/完整目标边界 |
| 整数 M FU | Breeze 数据通路方向，未来 SV；乘法流水、除法单请求迭代 | IQ/发射归属、身份/代际、结果保持、容量预留或流水停顿、选择性取消、特殊值完成路径、写回公平性 |
| F/D FU | B14 的两套 FMA/ADDMUL；DIVSQRT/MISC/CONV-MOVE 各一套；复用已调整 CVFPU 内部流水 | FP IQ 组织、读口/写口及跨域仲裁、请求身份寿命、年轻结果隔离、boxing/fflags/frm 等集成细节 |
| FP rename | 32 架构 FPR→64 个 64 位物理 FPR；独立域；R1 增加域/第三源，R2 原子事务 | 具体表/快照组织、端口与恢复时序；不能因为目标已定就声称 RTL 已有 FP rename |
| 非阻塞访存 | B03～B11 的缓存、LQ/SQ、重查、PTW、DMA、原子与精确检查合同继续有效 | 具体容量/端口/bank/流水、未知地址旧 store 策略、违例恢复及全链路实现；机制未实现不等于未讨论 |
| Linux 特权范围 | 单 hart RV64GC/Linux、SD DMA 必需；前端同步合同继续有效 | 已定主流程见 B22/B26/B27；B28/B29 复用 Breeze Linux 经验，剩余是 O3 集成与实现审查 |

本节是 2026-10-01 交接记录。当前下一窗口议程以 B29 及后续 B30 更新为准；流水乘法完成端背压仍是实现合同检查项，不再指定为唯一下一讨论主题。

### 24.3 交接证据

本轮再次只读核对目标：`develop`，HEAD `06462b0ebd48cecf0af34b8a87a90a365561894b`；仍只有两个既有未跟踪文件 `sim/o3/rv64i_instructions.jsonl`、`sim/o3/unified_memory.jsonl`。本轮未修改目标源码、未编译、未仿真、未综合、未做时序或 FPGA 测试；没有创建乘除法 SV 移植文件。下窗口须重新核对，而非把本快照当永久状态。

## 25. B22：Zicsr 首版串行化与成本计数（2026-10-02，已定范围）

用户决定第一版采用 BOOM 式保守 CSR 串行化，但阻塞点放在本项目的 **Decode→Rename 边界**，不是照搬 BOOM 的 Dispatch 阻塞实现。Decode 按程序顺序识别串行指令；同组只放行它及更老的连续前缀进入 Rename，年轻指令留在前端/Decode 缓冲中，不分配物理寄存器、ROB 项或 IQ 项。CSR 指令本身正常 Rename、分配 ROB；更老指令可继续执行和退休。串行指令等待成为 ROB 队头后，进入容量很小的独立串行执行通路；其提交之前保持年轻指令的 Rename 阻塞。前端缓冲容量不足时正常反压取指。这样不在多路 ROB 分配组合路径增加同组串行截断判断，也不为 CSR 之后的年轻指令引入重命名恢复需求；是否改善时序须待实现后测量。同组若有多条串行指令，只放行至最老的一条，剩余留待下一次放行。

CSR 首版按一条在途的请求/完成握手设计，可先尝试源寄存器读取、CSRFile 读/计算、旧值写回、退休的短流水；若 CSRFile 或写回时序不满足目标，允许将内部读改写拆成多拍或变延迟操作，外部串行边界不变。CSR 到 ROB 队头且更老指令已退休后，先完成地址、权限、只读限制和操作合法性检查。非法访问只在该 ROB 项记录同步异常，不更新 CSRFile。合法操作在 CSRFile 接受并完成该请求时取得应返回的旧值、按 Zicsr 读改写语义更新架构 CSR，并把需要的旧值送往 `rd` 写回；必须按操作码处理访问抑制：CSRRW/CSRRWI 在 `rd=x0` 时不读 CSR；CSRRS/CSRRC 在 `rs1=x0`、立即数变体在 zimm=0 时不写 CSR，但仍读；CSRRW/CSRRWI 的零源仍会写零，不能统一按零源禁止写入。CSRFile 的架构更新发生在执行完成点，可以早于 ROB 退休；一旦更新，CSR 指令不可再被异常、冲刷或重放取消，提交控制须保证它最终完成写回并退休。更新前若遇到同步异常，则不得有 CSR 写入。写回口/缓冲容量需要在允许架构 CSR 写入前得到保证，不能在写入后因为资源背压而丢失该指令。

中断只在指令边界仲裁：若选在 CSR 执行前进入中断，则不得启动该 CSR 写入；若 CSR 已更新，则先让它退休，再根据更新后的 CSR 状态判断待处理中断。对影响中断使能/待决/委托判断的 CSR 写入，须在执行后及时重新评估中断条件。CSR 提交后才能解除 Decode 阻塞；若它改变了年轻指令依赖的取指、翻译或译码状态，前端需丢弃相应缓冲指令并重新取指，但不涉及恢复年轻指令的 Rename 状态。影响前端的 CSR 同步承接 D27/D28；异常入口和 xRET 按 B26/B27，特权语义复用边界见 B29。这里“ROB 队头可执行”不等于当前已存在可工作的 CSR FU/CSRFile。对照来源：[BOOM v4 固定提交的 core.scala](https://github.com/riscv-boom/riscv-boom/blob/54f11b85c9a670ef3dd18bc675994b9a661b06ee/src/main/scala/v4/exu/core.scala) 在执行期驱动 CSRFile，源码明确说明它依靠 CSR 串行化避免提交前架构写入的推测风险；[BOOM CSR 执行文档](https://github.com/riscv-boom/riscv-boom/blob/master/docs/sections/execution-stages.rst)；[RISC-V Zicsr 规范](https://docs.riscv.org/reference/isa/unpriv/zicsr.html)；[RISC-V 特权规范的中断条件](https://docs.riscv.org/reference/isa/priv/machine.html)。[香山 V2R2 CSR 设计文档](https://docs.xiangshan.cc/projects/design/zh-cn/kunminghu-v3/backend/CSR/) 记录部分只读 CSR 可乱序执行，本项目暂不引入这一优化。

首版加入三个逻辑上为 64 位的性能计数器，具体读取地址、清零、快照和溢出规则留待性能计数 ABI 统一确定：

| 计数器 | 加一条件 | 用途 |
| --- | --- | --- |
| `csr_retired` | 一条 Zicsr 指令实际提交握手一次 | 与累计 `instret` 比较，估计动态 CSR 指令频率；等待多拍不能重复计数 |
| `csr_wait_empty_cycles` | CSR 已进入 ROB、等待成为队头，且此前仍有更老 ROB 指令的每一拍 | 量化等待前序指令退休的周期 |
| `csr_block_younger_cycles` | CSR 串行化阻止 Decode→Rename 放行，且前端/Decode 缓冲中确有年轻指令等待的每一拍 | 量化有实际年轻指令需求时的阻塞周期 |

周期计数由相应阻塞状态/握手生成单拍事件，指令数仅在提交握手时生成单拍事件。`csr_retired / instret` 可说明频率，两个周期计数与总周期数比较可说明阻塞占比；这些计数不是 IPC 损失的直接换算，阻塞原因可能重叠，不能相加后当作总停顿。以后在相同配置与工作负载下结合 IPC、CSR 类型分布及计数，判断是否值得研究香山式选择性乱序只读。

本节记录已确认的 Decode 阻塞位置、CSR 执行期架构写入/提交边界及计数口径；独立串行队列的具体端口、CSRFile 内部拍数、与异常/中断入口的详细仲裁电路仍待设计。`csr_file`、`commit_ctrl`、性能事件模块在 2026-10-02 目标工程中仍是框架空壳；本次只改 Flow 设计文档，未修改目标 RTL、未编译或仿真。FENCE/FENCE.I/SFENCE.VMA 的排空与完成条件已经由 B23/B24 确定。

## 26. B23：普通 FENCE 与 FENCE.I 首版完成边界（2026-10-02，已定范围）

普通 FENCE 和 FENCE.I 共用 B22 的 Decode→Rename 串行阻塞：只让串行指令及更老的同组前缀进入 Rename；串行指令分配 ROB，等成为队头后进入独立的一项串行寄存器，年轻指令在其退休前不能进入 Rename/IQ。这里的一项寄存器是逻辑容量目标，具体能否与 CSR 复用同一物理项、源操作数/完成端口如何仲裁，留给 RTL 接口设计。

**普通 FENCE**：首版 Decode 保留 `pred/succ` 编码，按 `pred` 是否含普通内存写 `W` 选择额外等待；无需动态扫描此前执行过的指令。FENCE 到 ROB 队头时，更老的 load、CSR 和不缓存 MMIO 已按 B05/B22 的完成后退休合同结束，年轻指令尚未进入执行。若 `pred.W=1` 且存在需要排序的后继集合，串行项等待 SQ 后台 drain 至空：所有更老普通 store 均得到 DCache 写完成确认，不能以请求接受代替。SQ 的 drain 在 ROB 无老项时仍自主推进；可给出维持到完成的加速请求，但不绕过 DCache 冲突或完成握手。若 `pred.W=0`，不为该 FENCE 强制排空普通 SQ，队头即可完成；例如仅含 I/O 的 FENCE 不因普通缓存 store 未排空而等待。`pred=0` 或 `succ=0` 的无排序提示编码不需要额外等待。由于年轻指令在 Decode 被统一阻塞，首版不依 `succ` 区分年轻指令放行范围；`FENCE.TSO` 可按更强的 `FENCE RW,RW` 处理。此方案依赖已定的 CSR/MMIO 完成握手覆盖其对外效果，并依赖 DCache 写完成与下级内存排序合同；这里不新增全 DCache 脏行写回作为普通 FENCE 动作。规范允许简单实现采用更强排序：[RISC-V FENCE](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html)；CSR 读写在 FENCE 中分别按 `I/O` 归类：[Zicsr CSR ordering](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html)。

> **2026-10-07 B51：** FENCE.I 不再遍历 L1D 写回脏行，`fencei_dcache_evict_cycles` 取消，见 40.7 节；下段只作历史记录。

**FENCE.I**：用户选择低频、低硬件复杂度的保守数据侧路径，具体前端顺序见 D25。串行项暂停新取指、预取并丢弃 Decode/前端中比 FENCE.I 年轻的旧指令，同时等待 SQ 中老 store 全部写入 DCache 并收到完成确认。然后遍历 L1D 的全部 tag/meta，跳过非脏行；每个脏行复用 B08 按物理行 clean+invalidate 维护能力，将最新行数据可靠写到 L2，确认后置该行无效。等全部扫描及在途脏行写回完成，再处理旧 ICache miss/预取结果并全量失效本地 ICache。前端返回同步完成后，该 ROB 项才可标记完成并退休；退休后从 FENCE.I 下一 PC 重取，不能只凭 SQ 空、写回请求发出或单拍 flush 脉冲放行年轻指令。若所有有效 DCache 行都脏，最坏要写回并逐出全部这些行；干净 DCache 行不因 FENCE.I 扫描而逐出。写回目标是 ICache 回填可见的 L2，不要求把整个 DCache 或 L2 写到 DDR，也不对普通 ICache miss 增加逐行探测。该维护控制器要在 B08 既有单行 DMA 协调与写回响应之间保证仲裁和前进；具体 FSM、端口、写回并发度及周期数待实现。规范依据：[Zifencei](https://docs.riscv.org/reference/isa/unpriv/zifencei.html)。

首版增加两个逻辑上为 64 位的性能计数器，读取地址、清零、快照和溢出规则留待性能计数 ABI 统一确定：

| 计数器 | 加一条件 | 用途 |
| --- | --- | --- |
| `fencei_retired` | 一条 FENCE.I 实际 ROB 退休握手一次 | 与 `instret` 比较，观察动态调用频率；等待多拍不能重复计数 |
| `fencei_dcache_evict_cycles` | FENCE.I 的 DCache 全行扫描/脏行写回逐出阶段处于 busy 的每一拍，包括扫描干净行及等待 L2 写回确认 | 与 `fencei_retired` 比较得到每次数据侧维护的平均周期；不包含此前 SQ 排空及此后的 ICache 失效/重取 |

这两个计数不能单独换算为 IPC 损失；若 FENCE.I 频率或逐出成本显著，再用相同工作负载下的 IPC、前后 I/D miss 和周期分布评估 I/D 一致性或更细粒度维护方案。本节是设计决定，目标 RTL 仍为空壳/占位，未编译、仿真、综合或测量。

## 27. B24：SFENCE.VMA 首版 SQ 排空与翻译同步（2026-10-02，已定范围）

SFENCE.VMA 沿用 B22 的 Decode→Rename 串行阻塞和一项串行执行通路；到 ROB 队头后，先等已提交 SQ 全量排空，所有更早的普通 store 均收到 DCache 写完成确认，不能只看 SQ 请求已被接受。首版不识别哪些 store 实际写过页表，统一等待；SQ 后台正常 drain 即可，不要求强制逐出 L1D 脏行。该合同以 B07 的 PTW 共享 DCache、页表写入对后续 PTW 可见为前提；若以后 PTW 改为绕过 DCache，必须重新设计可见性握手。

SQ 排空后，按前端 D26 的 rs1 虚拟地址、rs2 ASID、global 与页大小规则，同步失效 ITLB、DTLB、预取翻译记录及 walk cache 中匹配的旧状态；隔离或等待匹配范围内旧 PTW 的迟到结果，防止其在失效后重新安装旧翻译。前端丢弃 SFENCE.VMA 之后携带旧翻译/权限快照的取指工作，完成同步握手后，该 ROB 项才可标记完成并退休，再放行年轻指令。具体请求/应答、PTW 取消与 generation 标记留待接口设计。这里不全清物理标记 ICache，也不执行 FENCE.I 的 L1D 脏行写回逐出；SFENCE.VMA 仅同步本 hart 的地址翻译。当前只记录设计，未修改目标 RTL 或验证。

## 28. B25：stride load 地址预测首版（2026-10-02，已定主流程）

用户决定加入按动态 stride 预测**标量 load 自身有效虚拟地址**的能力，为以后可能加入的 V 扩展积累访存预测基础；V 扩展本身的指令/流水设计本轮不展开。它不同于 B07 已计划的下一缓存行 stride 预取，也不同于旧 store 与 load 的依赖预测；B03 不做值预测的决定保持不变。

首版按下列主流程设计，不要求在 Fetch 阶段无 LQ 身份地提前发 load：

1. 预测表按 load PC 区分，记录上次退休的有效虚拟地址、相邻地址差值 stride 与置信状态。只用成功退休的普通、可缓存标量 load 真实地址训练；看到连续稳定的差值后，预测下一次地址为 `last_va + stride`。表深、tag 宽及置信门槛待资源测量确定。为避免同一静态 load 多个在途实例重复使用同一个预测地址，首版在该 PC 的前一预测实例退休或被取消前抑制下一次预测；取消不能训练。上下文切换至少隔离/失效旧预测状态，不能把前一地址空间的缓存结果误当当前结果。
2. Rename/LQ 分配后，携带 LQ/ROB 身份及足够的 generation，将预测虚拟地址作为提前访存候选。它优先级低于正常需求访问，端口、MSHR 等资源不足时直接跳过预测，不阻塞正常 load。提前请求只在当前 DTLB 命中、翻译及页权限/PMP/PMA 检查允许、目标为可缓存且无副作用的普通内存时发出；首版预测路径不启动 PTW，不向 MMIO 发请求，预测失败或无映射不能产生该 load 的架构异常。推测路径被清除、翻译上下文变化后，迟到结果不得装入已复用的 LQ 项或写回物理寄存器。
3. 在提前请求发出前，检查比该 load 更老的 SQ store/未完成原子操作：未知地址、与预测访问字节重叠、或尚不能确定安全性的情形，首版跳过提前取数。若提前返回，将候选数据暂存在对应 LQ 项，不标记该 load 完成，不写回目的物理寄存器，也不唤醒依赖者。DCache 行若在取数后受到 store、AMO、DMA 等写入/失效，必须使候选数据失效或提供可验证的新鲜度版本；做不到时退回正常 demand 读取，不能使用过期的暂存值。
4. 正常 AGU 仍计算真实地址，照常执行真实地址的翻译、权限与访问检查以及旧 SQ 依赖/转发选择。仅当预测地址与真实地址一致、相关检查成功、旧 store 依赖已安全判定且暂存数据仍新鲜时，才可用提前结果完成 load。若地址不同、数据失效或检查不通过，丢弃暂存结果并按真实地址走既有 LQ 重试/DCache 请求；架构异常只来自真实执行。首版不让依赖指令提前消费预测结果，因此误预测恢复局限于本 load，不增加下游依赖链选择性重放。

上述是提前取得并验证 load 数据，不只是预取一条缓存行。若额外的 SQ 检查、新鲜度跟踪或端口成本太高，允许保留同一 stride 表，把预测请求降级为只暖缓存、真实 load 重新读数据的测量对照模式；不能把降级模式宣称为已实现提前 load 完成。性能事件至少区分符合置信门槛的预测候选、实际提前请求、地址命中、提前数据被真实 load 采用、地址错误/新鲜度失效、资源或安全门槛跳过，以及额外 DCache/MSHR 流量。具体事件名、CSR 编码、表容量和实现拍数待定；用同负载的 IPC/负载等待周期与额外流量评估收益，不能只看地址命中率。目标 RTL 尚未实现该机制，本节不代表已编译、仿真或测量。

资料边界：Shen/Lipasti《Modern Processor Design》第 5 章约印刷页 275～278 将 stride 引导的数据预取与 load 地址预测分开；参考 [Austin/Sohi, Zero-Cycle Loads](https://ftp.cs.wisc.edu/sohi/papers/1995/micro.zcl.pdf)。[RISC-V V 扩展访存规范](https://docs.riscv.org/reference/isa/unpriv/v-st-ext)本身已定义连续、定步长和索引访存的地址生成方式；因此地址预测是可选性能优化，不是实现 V 扩展的正确性前提。以后可复用提前访存接口，不能由此推定 V LSU 已设计完成。

## 29. B26：精确异常与中断的已定提交边界（2026-10-02，已定原则）

同步异常随产生异常的动态指令保留 ROB 身份、PC、cause 与 tval。提交按程序顺序退休该指令之前的所有更老指令；遇到故障指令时停止，**故障指令本身不退休**，它之后的年轻指令全部取消。提交/恢复控制在这个精确边界发出 trap 请求，CSRFile 完成陷阱状态更新，再用处理程序入口 PC 重定向前端。不能把“提交到异常指令”误写成“故障指令正常退休”。架构异常/委托与 trap CSR 语义按 B29 复用 Breeze 经验；O3 多来源事件接入仍须核对。

中断只在指令边界仲裁。若串行 CSR 指令已开始执行并更新了架构 CSR，必须先完成写回及 ROB 退休，再按更新后的 CSR 状态判断是否进入中断；不得在架构 CSR 已更新但该指令未退休的窗口插入中断。其他不可撤销操作也须先到各自已定的安全边界。没有这种在途操作时，完成本次选定的退休前缀后，可在下一条未退休指令之前进入中断。中断边界不能切开一条指令，也不能让年轻指令在 trap 请求后继续退休。待决/使能/委托语义按 B29 复用；空 ROB 时的下一 PC 来源和 O3 接入握手仍需闭合，原子更新时序见本节下文。

此处固定的是提交语义，不限定把控制电路全部放进 ROB 阵列本体；ROB 提供队头顺序与异常元数据，提交控制仲裁并驱动 CSRFile/前端。目标工程当前仍只有框架/占位，未按本节完成 RTL 或验证。

参考实现边界：BOOM 固定提交 `54f11b85c9a670ef3dd18bc675994b9a661b06ee` 的 [v4 ROB](https://github.com/riscv-boom/riscv-boom/blob/54f11b85c9a670ef3dd18bc675994b9a661b06ee/src/main/scala/v4/exu/rob.scala) 在提交逻辑中仅允许提交组队头异常触发 `com_xcpt`，不让故障项正常退休，并产生 flush；[v4 Core](https://github.com/riscv-boom/riscv-boom/blob/54f11b85c9a670ef3dd18bc675994b9a661b06ee/src/main/scala/v4/exu/core.scala) 将 `com_xcpt` 的 PC/cause/tval 延后一拍送 CSRFile，再用 CSR 的 `evec` 重定向前端。BOOM 的 [v4 Decode](https://github.com/riscv-boom/riscv-boom/blob/54f11b85c9a670ef3dd18bc675994b9a661b06ee/src/main/scala/v4/exu/decode.scala) 会把当时的中断标成微操作异常，最终仍到 ROB 队头处理；这并不要求本项目照搬其 Decode 采样点。本项目的中断在提交边界按当时有效 CSR 状态仲裁，尤其要遵守串行 CSR 执行后先退休再复核的约定。

**2026-10-02 补定 trap 请求/重定向主流程**：提交控制在上述边界锁存一次 trap 请求，至少携带异常/中断区分、精确 EPC 候选 PC、cause，以及同步异常所需的 tval；同步异常的 EPC 是故障指令 PC，中断的 EPC 是被中断边界后的下一条尚未退休指令 PC。提交控制从选择该 trap 起阻止继续退休，清除年轻推测状态；CSRFile 作为架构 CSR 唯一状态所有者，接受请求后按当前特权/使能/委托状态更新对应的 epc、cause、tval 与陷阱状态，并给出处理程序入口 PC 及完成确认。前端只在该更新确认后接受系统重定向，从处理程序入口重新取指；迟到旧路径结果不得重新进入有效流水。`trap_ctrl` 可以承担请求整理与重定向控制，但不得另存一份独立的架构 CSR 状态。M/S 委托、`xtvec` 与状态位语义按 B29 复用 Breeze；信号编码、空 ROB 时 EPC 来源仍待落实，这里没有宣称目标 RTL 已实现。

**随后确认的退休互斥与紧凑时序**：正常退休与 trap 触发不在同一拍发生。若提交组中异常前还有更老指令，只退休该正常前缀，停在故障指令之前；下一拍故障指令成为最老有效项后触发 trap，不退休该项或任何年轻项。异常本来已是最老项时直接触发，不再额外插入等待拍。中断也先完成选定退休前缀，在无正常退休的 trap 拍处理，并遵守串行 CSR/其他不可撤销操作的安全边界。因此恢复可直接采用拍初 committed 状态，无需 trap 拍的同拍退休旁路。

时序目标为：周期 N 接受 trap，flush/恢复与 CSRFile 专用硬件 trap 更新、入口 PC 计算并行；N 末恢复推测 RAT、free list 和队列有效性，更新陷阱 CSR 并锁存重定向；N+1 前端开始按处理程序入口 PC 取指。不经普通 Zicsr 读改写执行通路，不额外串行等待一拍恢复完成；这是控制时序设计目标，实际取指返回还受前端流水及 ICache 命中影响，目标频率尚未验证。恢复沿用分支恢复的广播/取消机制，但选择 committed 边界；保留已提交 SQ 项及其后台 drain，取消未提交项，隔离迟到结果。free list 的提交态恢复记录具体采用位图还是等价结构仍待接口设计；不把既有分支 checkpoint 恢复当作已完成全局 trap 恢复。

## 30. B27：MRET/SRET 由队首正常提交触发（2026-10-02，已定主流程）

用户确认 MRET/SRET 到 ROB 队首、通过权限与合法性检查后，由该指令的正常提交直接触发 trap return；不要求先送普通 FU 执行完成。CSRFile 经专用返回控制恢复相应特权/中断使能状态，给出 mepc/sepc 返回 PC，提交控制清除年轻路径并重定向前端。正常返回指令本身退休，不产生新的异常 cause，也不把当前 PC 覆盖进异常 EPC；不合法则走 B26 的同步异常路径且不退休。B26 的“trap 入口与正常退休不同拍”针对异常/中断进入，不禁止合法 xRET 的退休与返回状态更新同拍。状态位和中断重新评估的架构语义按 B29 复用 Breeze；WFI 的 O3 停顿/唤醒接入及返回目标检查的异常归属仍需审查，当前未实施 RTL。

## 31. B28：首版面向 Linux 的自建 SoC（2026-10-02，已定范围与候选参考）

> **2026-10-08 B52：** “不采用 LiteX 框架、SoC 使用 Vivado IP 与自写逻辑集成”被取代，改用 LiteX，见第 41 节。单 hart RV64GC/Linux 平台范围、CLINT/PLIC 机制复用与定时器路线不变。

用户明确首版按单 hart RV64GC/Linux 完整平台需求设计；不采用 LiteX 框架，SoC 使用 Vivado IP 与自写逻辑集成。此要求取代任何把 Flow 的 LiteX/LiteDRAM 集成方式直接继承到 CISLC-O3 的假设。借鉴 Breeze 已有的软件可见接口及验证经验，不把其板级或 Linux 历史结果算作 CISLC-O3 验证结果。具体 IP 型号、地址图、启动介质和中断控制器实现尚未全部冻结；既有 SD DMA 需求保持在首版系统范围内。SD 控制器选型见 B44（2026-10-05）。

本轮核对 Breeze：`litex_wrapper/flow/rtl/FlowClint.sv` 和 `FlowPlic.sv` 是独立 SV 模块，当前带 64-bit Wishbone slave；`fpga/kcu105/target.py` 负责地址译码、总线和 msip/mtip/mtime/meip/seip 接线。可参考其寄存器与 gateway/claim/complete 机制，后续改接 AXI/AXI-Lite 等选定总线时必须重查字节地址、访问宽度、写 strobe 和握手，不能把原包装直接当 AXI 外设。`design/src/main/scala/core/RegFile.scala` 包含 M/S pending、enable、delegation 仲裁、软件 STIP 路径及可选 Sstc 路径；核内 CSRFile 应承接这些架构语义。

候选平台分工：DDR4 控制器/PHY、时钟复位、AXI 互连/CDC、UART 可选 Vivado IP；核、cache、CLINT/PLIC 兼容控制、启动 ROM/装载逻辑及 SD DMA 协调由自写或审计后复用模块承担。首版已选择 CLINT/PLIC + OpenSBI 传统定时器转发路径，具体见 B29；首版不依赖 Sstc。UART 更换后应同步 OpenSBI 驱动、Linux 配置、设备树和控制台参数；CPU 时钟与 mtime 时间基准必须分别描述且与硬件一致。启动路径需要 DDR 可用和镜像装载成立，再交给 OpenSBI/DTB/Linux，不能直接沿用旧 LiteX BIOS 装载假设。

## 32. B29：Linux 经验复用与机制审查交接（2026-10-02）

### 32.1 已确认的复用范围

用户已确认传统定时器路线，并要求后续 Linux 特权、中断控制器等常规机制复用 Breeze 经验，不再逐节重新讲解或重新选择。首版链路为 `CLINT mtime/mtimecmp → MTIP → M-mode OpenSBI → 软件 STIP → S-mode Linux`。Linux 通过 SBI set_timer 设置下一事件，OpenSBI 编程比较值并清除旧 STIP、重启机器定时器中断；机器定时器到期后由 OpenSBI 屏蔽 MTIE 并置 STIP，交给 S 态处理。具体固件实现须与所选 OpenSBI 版本核对；首版不依赖 Sstc，未禁止未来添加。（2026-10-07 B49：v1 加入 Sstc，Linux 优先使用 `stimecmp`，传统 SBI set_timer 路径保留为 OpenSBI 回退。）

CSRFile 承接 M/S pending、enable、delegation、trap entry/return 及软件 STIP 语义；平台提供 MSIP/MTIP/MEIP/SEIP 等输入，不能把平台反映的只读 pending 位误做普通可写寄存器。PLIC 的 priority、pending、enable、threshold、claim/complete 与设备中断接线沿用 Breeze 的经验。复用意味着以已审查实现为依据迁移语义和验证经验，不是照抄 Wishbone/LiteX 包装、旧核数、源数、地址或时钟参数，也不把 Breeze 的测试结果算作 CISLC-O3 已通过。

源码入口：Flow 的 `design/src/main/scala/core/RegFile.scala`、`litex_wrapper/flow/rtl/FlowClint.sv`、`litex_wrapper/flow/rtl/FlowPlic.sv`；原接线参考 `fpga/kcu105/target.py`。B28 的自建 SoC、不使用 LiteX 和首版 SD DMA 范围保持不变。

### 32.2 本窗口已定机制索引

| 机制 | 当前有效决定 |
| --- | --- |
| 串行阻塞与 CSR | B22：Decode 截断同组年轻前缀；CSR 自身入 ROB，等老指令退休后进入独立小通路；执行完成可更新 CSR，随后必须退休；三个成本计数器 |
| 普通 FENCE | B23：需排序且 pred.W 时等 SQ 正常 drain；否则不额外排空普通 SQ；年轻执行由 Decode 阻塞 |
| FENCE.I | B23：SQ drain、扫描并写回逐出 dirty L1D 到 L2、旧 I 请求隔离和 ICache 失效、完成后重取；次数与数据维护周期计数 |
| SFENCE.VMA | B24：先全量 SQ drain，再按既定 VA/ASID/global 规则同步翻译状态；不要求 dirty DCache sweep |
| stride 地址预测 | B25：预测 load 有效地址并提前取数，真实 AGU/权限/SQ/数据新鲜度验证后才写回；未来 V 设计未展开 |
| 异常与中断 | B26：精确提交边界；fault 本身不退休；串行不可撤销操作先完成并退休；trap 拍无正常退休，专用 CSR 更新与恢复并行 |
| MRET/SRET | B27：合法队首指令自身正常退休直接触发返回、状态恢复和重定向；非法走异常 |
| Linux 平台 | B28/B29：单 hart RV64GC/Linux；Vivado IP + 自写 SoC；复用 Breeze 常规机制，传统 OpenSBI 定时器路线 |

### 32.3 下一窗口怎么查缺口

先完整阅读两份基线，再只读检查目标工程当前状态和相关框架。对每项发现分清：**设计已定但 RTL 未实现**、**已有合同需要接口细化**、**真正缺少行为选择**。不能把这三类混成“机制都没设计”，不能把旧源码 TODO 当作尚未讨论的证据。用户确认一个机制后记录，再按实施授权补框架；本次查漏只修改文档。

优先审查下列接缝，它们是检查入口，不是本轮新决定或已经证明存在的 bug：

- B26 的空 ROB 中断 EPC/下一架构 PC 来源；异常、中断、xRET、分支恢复同时发生时，按 D24 架构边界和年龄规则落实整套请求选择；不能再次打开“异常是否退休”的议题。
- 全局 trap 恢复 committed RAT/free list/队列的实际通路，以及前端 E/C、RAS 恢复完成条件。后续 D29/B30 已选择 BOOM 式 RAS 快速修复，并允许系统入口首笔取指与预测恢复解耦；系统 committed 预测上下文来源及提前取指身份/元数据接入仍待闭合。不能把普通分支的 FTQ 检查点机械当作系统边界，也未选择清空 RAS 或复制 BOOM 系统 flush 清零历史。
- B09 的 reservation 清除与 LR/SC 前进性、B07 的 PTE A/D 更新原子性：先检查已有合同和实现，再判断哪一项确实需要设计选择。普通非对齐/跨页访问的支持边界随后已由 B31 确定，不再作为未决范围。
- B15 的 fflags 退休累积、FS 状态与 CSR/trap 的原子更新，WFI 停顿/唤醒在 O3 中的接入，以及不可撤销 MMIO/AMO 的中断安全边界。标准语义参考 Breeze，重点检查乱序接入带来的差异。

每次只挑一个需要选择的机制，讲正常路径、冲突/恢复、必要状态和资源代价。必要时查 BOOM、香山、规范或论文，给出具体版本和行为证据；不主动开启整套 Linux 基础课程，不重新提出已否决的复杂一致性路线，不将表深、mux 编码和位宽包装成新机制。框架、编译、仿真、时序、FPGA/Linux 和性能测量证据分别记录。

本次查漏修正了文档前部“统一中断暂缓”、B21 的旧下一窗口议程、B22 对已定屏障仍写待讨论等过期表述，补齐已确认的定时器与 Breeze 复用决定，并在前端第 16.4 节标出恢复时序接缝。没有修改目标 RTL、运行测试或取得新性能证据。

## 33. B30：BOOM 式 RAS 快速修复与恢复交接（2026-10-02，已确认）

用户在查阅 BOOM 源码与论文比较后确认采用前端 D29 方案，完整合同见前端第 6.2 节；本节同步后端交接，不重复发明另一套恢复协议。

- RAS 暂定 16 项环形寄存器数组；每个 FTQ 保存区域入口 `{top_idx,count,top_addr}`。取消原逐条 undo，保留 D23 的完整 E/C 快照和 D09 事件资格规则。
- 执行纠错按 D24 选唯一赢家，恢复入口 E/C 和 RAS 索引/占用数/保存栈顶，再应用一次核实后的控制流动作。BRU/预解码须提供准确类型、原始长度及目标，不能继续采用错误的预测类型。
- 普通分支目标时序：R0 接受重定向并读检查点，R1 恢复及修正，R2 从正确 PC 发起正常预测。要求 E/C 宽读取、恢复优先仲裁、RAS 栈顶修复与正确压栈双写选择及旁路；这是从前端接受重定向起算的实现目标，不是整核误预测惩罚或已验证的频率。
- 接受深层 RAS 被错误路径覆盖后仍可能导致后续 return 误预测的取舍；真实 JALR 执行继续纠错。不得继续宣称 RAS 全内容精确恢复，不改变架构正确性要求。
- 恢复请求及快照返回绑定身份；更老请求或同位置更高优先级请求替换时，旧恢复不得写回或错误解除阻塞。预测表仍按原上下文在提交时训练。
- 系统入口已知 PC 的首笔取指允许与恢复解耦，保留 B26 的 N+1 发起取指目标；普通分支不采用停用预测器并后台慢慢撤销的路径。系统 committed 预测上下文来源、空 ROB/已释放 FTQ 边界及提前请求的返回槽/元数据交接仍须闭合，见前端 16.4。

依据为 BOOM v4 `54f11b85c9a670ef3dd18bc675994b9a661b06ee` 的 FTQ `ras_idx/ras_top` 保存修复及前端写回；并非此前前端研究的 58ef2720。BOOM 该版系统 flush 清零全局历史主体的行为没有被选入本设计。D29 的占用数、双写与 R0～R2 是本项目适配决定。论文与固定源码链接见前端 6.2。

本次只更新两份设计基线；目标工程的 `ras.sv` 等仍保留旧框架，未修改 RTL、未编译或仿真，不覆盖其他 agent 的改动。B29 是审查入口，B30 是最新恢复决策补充；余项继续区分已定待实现、接口细化和真正行为选择。

## 34. B31：同 line 非对齐访问支持与跨 line 异常计数（2026-10-02，已确认；跨 line 部分 2026-10-07 由 B49 取代）

> **2026-10-07 B49：** 本节“跨 line 报地址非对齐异常、不建立双页拆分完成通路”及 34.1 计数器口径已被第 38 节取代；同 line 部分、MMIO 不拆分、A 扩展自然对齐继续有效。

用户选择方案②：普通可缓存内存的标量非对齐 load/store（包括相应浮点访存）在同一条 cache line 内由硬件支持；跨 line 则报告地址非对齐异常，不发出该指令的数据读写。MMIO 不进入这条普通内存拆分路径，A 扩展仍按 B09 要求自然对齐。该决定不涉及取指跨块拼接，也不扩展至 V。

- 判定为 `line_offset + access_size <= line_bytes` 时落在同 line；比较须保留进位，不能因窄位宽溢出误判。跨 line 的 load/store 分别使用相应地址非对齐 cause，保留原指令 PC、有效地址及动态 ROB 身份，按 B26 精确处理。
- 同 line 内可能跨 bank/数据口粒度，需要内部拆分与拼接，但仍是一条架构指令、一次完成/退休。权限检查覆盖全部访问字节；load 在数据及检查全部完成后才交付，store 在检查及数据齐备后才能完成并等待退休/drain，遵守 B04/B05。具体阵列端口和拆分状态待实现。
- 在 64B line、4KiB 最小页的组织下，普通标量访问跨页必然跨 line，因此本路径不新增双页翻译、拼接完成机制。不承诺非对齐访问整体原子性；MMIO、PMA/PMP 拒绝及其他异常的完整优先级按访问检查接口细化。
- 软件对跨 line 非对齐异常的处理/模拟能力须另行核对，不能以未来编译器优化代替运行时合同。编译器可通过已知对齐、循环前导、运行时路径选择或小粒度访问减少此类事件，但不能假定动态地址的 line 位置总能静态判定。

### 34.1 新增一个 64 位逻辑计数器

`misaligned_crossline_traps`：一条普通标量 load/store 因上述跨 line 限制，最终在 ROB 最老位置被正式接受为地址非对齐 trap 时加一。计数对象是实际陷入次数，不是所有推测地址检测次数，也不是所有同 line 非对齐访问。

- LSU 将跨 line 非对齐原因随异常身份保存到提交端；只在 B26 的 trap 接受握手计一次。故障指令不退休，不能用该指令的 retire 脉冲计数。
- 错误路径被取消不计；等待、内部重放、异常 valid 保持多拍不重复计；同一 PC 返回后再次执行且再次正式陷入，属于新一次事件，重新计数。
- 不统计取指、预取/地址预测候选、LR/SC/AMO、普通 MMIO 错误或最终选为其他 cause 的异常。load/store 首版合计，不额外增设两个分类计数器。
- 用同一测量窗口的 `1000 * delta(misaligned_crossline_traps) / delta(instret)` 表示每千条退休指令的此类异常次数；分母为零时不报告比值。这是异常密度，不是“所有访存中有多少比例非对齐”。分母含测量范围内的异常处理/模拟指令，编译器对照实验须保持采集范围一致。
- 若以后要统计占全部架构访存尝试的比例，需另有同范围的访存分母，包含成功退休与相应故障尝试，不能直接将本计数除以成功退休的 load/store 后冒称完整发生比例。本次只确认新增上述一个计数器。
- 读取地址、清零、统一快照及溢出规则随性能计数 ABI 确定。该次数不能直接换算成周期或 IPC 损失。

本次仅记录用户选择与计数合同，并更新旧待定项；未修改 CISLC-O3 RTL、未编译或仿真，计数器尚未实现。

## 35. B32～B41：本轮确认的机制共识（2026-10-02，已确认）

以下十项为 B31 之后用户明确确认的共识，随后同日补入目标工程 RTL 框架（只有类型、接口、模块边界、接线与合同注释，新模块均为空壳；未编译、仿真、综合或测试）。字段、容量、拍数仍未冻结的部分在各条中单独写明，不能把“参数未定、框架未连接”当作机制缺失。

### 35.1 B32：保守 load/store 依赖

> **2026-10-07 B51：** L8a 维持本节；L8c 改为推测越过 + store 地址确定时查 LQ 冲刷 + 1 位等待表，取代“首版不加入推测越过与违例恢复”，见 40.5 节。“不能用固定超时无条件越过”继续有效。

- load 遇到地址未知的更老 store 时，等待相关依赖条件解除（该 store 地址写入 SQ，或被取消/提交排出后重新判定）。
- 不能把“等几拍”实现成固定超时后无条件越过；首版不加入未知旧 store 地址下的推测越过与违例恢复。替代 B04 6.2 节末“尚未冻结”的表述。

### 35.2 B33：提前唤醒与完成 FIFO

**2026-10-11 用户更新（后端重构）**：以下原有“FIFO 中尚不可交付的条目不能提前唤醒”
改为区分调度通知和实际数据可读。ALU、MUL（含融合的两条目的）、DIV、全部 FP FU、
成功普通 load，均可在下一拍进入完成保持槽/FIFO 前通知 IQ；FIFO 尾部也允许通知。
通知只让消费者离开 IQ 到自己的读前 buffer，不置 PRF ready、不标 ROB complete。
读前 buffer 必须再检查各源的真实 PRF ready、当拍真实写回或 live FIFO 头部 bypass，
并原子取得全部读口后才能进入独立 RegRead；尚不可交付的尾部结果使消费者在 buffer 等待。
完成头持续广播使晚到消费者可见，实际写回继续承担 PRF ready/ROB 完成。
DIV 和 load 不从启动时预测固定结束拍，而在实际成功结果及入队容量已确定时通知。
store 没有目的寄存器通知。

本次确定配置为 Decode/Rename/Dispatch 四宽、Rename 两拍、INT IQ 每拍最多选择四条，
四个 ALU、一个流水 MUL、一个迭代 DIV；FP IQ 每拍最多选择两条，两个 FMA、
DIVSQRT/MISC/CONV 各一个；MEM IQ 两条、两个读前 buffer 和独立 RegRead。
每个 INT/FP FU 独立拥有一个读前 buffer，BR 保留原有路径。
INT 选择宽度与 ALU 数量分别配置；退休总宽度保持四条，INT PRF 仍为 6R/3W、FP 为 8R/2W，
四个 ALU 不承诺每拍四条双源指令都有读口。普通访存的 replay/cache/提交后 SQ 排出合同保留。
用户授权先实现 RTL 并仅做后端 OOC 综合、分析时序，功能回归留待后端重构完成后一并处理。

- 对能确定结果交付时间的流水 FU，支持提前一拍安排依赖指令。memory 不强求提前唤醒；迭代除法不能从启动时假定固定延迟，只能在结束时间已确定时使用。
- FU 完成端使用局部 FIFO 吸收写回仲裁等待。已选的 FIFO 头部结果可参与 bypass，不要求先写 PRF；FIFO 中尚不可交付的条目不能提前唤醒消费者。
- 不可停顿流水线必须有完成空间预留；结果被仲裁推迟时，不能破坏已经发出的唤醒承诺。晚到消费者、PRF 写入和 bypass 退出之间不得有数据可见性空洞。
- 这取代 B21“流水乘法完成端背压与结果容量”待讨论项；FIFO 深度、承诺提前量与 PRF 读写交接拍数待定。

### 35.3 B34：MULH 类 + MUL 执行融合（本项目方案）

- 在 Decode Queue 输出、Rename 之前匹配程序顺序相邻的 MULH/MULHU/MULHSU + MUL：源寄存器顺序一致，前条 rdh 不得覆盖源寄存器。可覆盖 buffer/本拍输入边界，但不任意向前搜索，也不为未来可能的配对强行等待。
- 保留两条指令的 rename 目的映射、两个 ROB 身份和两次架构退休；只形成一次乘法执行请求，携带两个结果归属，交付高低两个结果。第二条是“不独立执行的融合成员”，不是普通 NOP。
- 成对资源接纳必须完整，否则不融合或等待，不能留下半个融合对。结果可通过完成 FIFO 分拍交付；取消和迟到结果按各自身份过滤。单步、触发器、异常等不能安全合并的情况不融合。
- 这是本项目方案，不能写成 BOOM/香山已实现同样的双结果融合。

### 35.4 B35：LR/SC reservation（补全 B09 11.2 清除表与前进性）

> **2026-10-08 L8b（用户确认 Y3/Y4）：** 清除表修订——L1D 处理到保留行的任何 Inv probe、或把保留行逐出时清除；Down probe 不清除。原因：B50 精确目录下行被逐出后 DMA 写不再 probe L1D，按下文“cache 替换不清”会让 SC 错误成功。下文“不清”列表中的“cache 替换”“L2 容量回收”不再适用，其余不变。前进性采用 Breeze 的 LR 后 80 拍同行 probe 保护窗口（窗口到期本身不清除 reservation）。见 [L8b spec](../spec/l8b-atomic-mmio-dma-spec.md) 5.3 节。

- 一条独立 reservation，以物理 cache line 为冲突粒度，并保留 LR 地址/大小用于配对；首版只允许同物理地址、同大小的 SC 成功。不设固定超时；不从 LR 到 SC 一直锁住 cache line。
- LR 在队首执行，读取数据与建立 reservation 处于一致的访问边界。SC 先完成地址/权限/对齐/PMA 检查，miss 可以取行等待；最终在短保护窗口内重新检查 reservation 并条件写入，不能提前锁定成功。新 LR 替换记录；SC 成功或失败都清除。
- 清除：本核 store/AMO、DMA 写、PTW A/D 实际更新与保留行冲突；reset、trap 入口、合法 xRET、进入 debug；首版 SFENCE.VMA/地址空间切换。
- 不清：普通分支恢复；cache 替换、clean、writeback、DMA 读引起的失效（以及 B41 的 L2 容量回收）。
- DMA 写在取得行保护权时与 SC 明确排序，不能仅看到排队请求 valid 就清除。没抢到资源应等待，不能拿 SC 失败替代公平仲裁。SC 回填及最终执行须有前进保障，不能被重复替换或 DMA 读无限抢占。

### 35.5 B36：硬件 A/D 更新，常用路径保持流水线

- TLB 命中、权限和 A/D 都满足时走原 load/store 流水线，不新增流水级。更新状态机放在旁侧，普通 load/store 不经过它。
- A 位可以在推测翻译中原子更新，完成更新后才交付可使用的翻译。
- 成功把 PTE 的 A 位从 0 置 1 时，在 DCache 实际写入的同拍向 LQ 独立广播该 PTE 物理行。已执行、未退休的同行普通 load（含 SQ 转发、同拍成功完成的 load）置 order_flush，到 ROB 队头不退休而冲刷该 load 及更年轻指令并从其 PC 重取。被取消、有异常或由 HEU 完成的 load 不标记。比较不匹配、写入失败、写前取消不广播。与 DMA Inv 同拍的不同物理行分别匹配，不能丢失任一来源；不伪造 dma_write，不计 DMA 事务或读写事件，实际重取计 ld_order_flush。内部 PTW 更新不受 HEU 队头门控，常用命中路径不增加流水级。（2026-10-08，T10 Y11 用户批准补丁。）
- store 遇到 D=0 时标记 needs_D 并释放 PTW 槽位，到 ROB 队首再做非推测更新；首版慢路径可重新遍历，不要求每个 SQ 项保存完整 PTE 快照。D=0 慢路径阻止年轻访存越过，已执行的年轻访问纳入重放/排序处理。
- DCache 提供内部“完整 64 位 PTE 比较 + 条件置 A/D”入口。比较不匹配时重新遍历检查，不能直接 OR 后覆盖，也不是立即报 page fault。更新错误归属原指令，在退休前处理。
- 取消、SFENCE.VMA、satp 切换不仅要过滤旧响应，还必须阻止失效上下文发起新的 PTE 写入。内部 PTW 更新不能被外部 AMO 的 ROB 队首门控卡死。

### 35.6 B37：committed_next_pc

- 提交端维护“已退休前缀之后的下一架构 PC”：普通指令用原始 PC + 真实指令长度，控制流用真实后继 PC；同拍多条退休取最后一条实际退休指令的后继。
- 正式 trap/xRET 生效后更新为入口/返回目标；普通分支恢复不修改；复位初始化到启动入口。
- 用于中断精确 EPC，尤其 ROB 为空时；同步异常仍用故障指令 PC；不允许用推测取指 PC 代替。闭合 B26/B29 中“空 ROB 中断 EPC 来源”的审查入口。

### 35.7 B38：WFI

- WFI 在 Decode→Rename 串行阻塞年轻指令。合法 WFI 在队首正常退休后进入等待，committed_next_pc 指向其后继。
- 等待期间暂停新指令推进，不关闭整核时钟；SQ drain、cache 回填、DMA 协调、中断检测继续工作。WFI 不额外充当 FENCE。
- 唤醒条件与正式中断条件分开：对应单项使能且 pending 的中断即可唤醒，不额外要求全局 MIE/SIE 打开，也不按委托结果屏蔽唤醒。醒后满足 trap 条件则进入中断，否则从后继继续。
- 入睡同拍已有唤醒条件则不睡，不能只检测后续边沿。权限/TW 等合法性按既有特权规则处理。

### 35.8 B39：晚到不可恢复写回错误

- 首版只做 sticky fatal + 执行隔离，保持到复位：停止新指令推进和后续正常退休，但保留必要的在途总线收尾。
- 失败写回不能按成功释放，维护/DMA 不得虚假完成。普通精确异常不升级成 fatal。synthesizable 的 fatal 状态不能用仿真 $fatal 代替。
- 不做软件恢复、自动重试、RNMI 或完整 Debug Mode。详细错误记录与调试以后接 FASE，本轮不扩展成 BEU/RAS 子系统。闭合 B06 中“晚到硬件错误报告方式”的待定项。

### 35.9 B40：浮点架构状态退休接入

- fflags 随原指令保存，按实际退休项 OR 合并，一次交给 CSRFile。
- 退休写架构 FPR 时置 FS Dirty，不比较新旧数据；退休项带非零 fflags 时也置 Dirty，即使结果写整数寄存器。软件写浮点 CSR 时，在既定串行更新点置 Dirty。
- 错误路径不更新架构 fflags/Dirty。接好 CSR、trap 与退休事件的互斥，不给普通 FP 执行增加状态阶段。闭合 B15 末尾的 fflags/FS 待落实项。

### 35.10 B41：L2 inclusive 与回收（2026-10-07 由 B50 取代回收与协调方式）

> **2026-10-07 B50：** L2 的包含关系、替换、回收与 L1 探测改按 Breeze MESI L2 Home 的目录与 probe 机制，见第 39 节；本节“组相联、PLRU”“容量替换不清 LR/SC reservation”“不在普通访问路径增加查询口或流水级”继续有效，其余以第 39 节为准。**2026-10-07 B51：** L2 只对 L1D inclusive，L1I 不进目录、不被回收，见 40.7 节。

- L2 已纳入首版，不是可选的新增模块。采用 inclusive，覆盖 L1I 和 L1D。**2026-10-02 用户同时确认 L2 组相联、PLRU 替换**；框架按 tree-PLRU 落实（每 set ways-1 位，命中与安装时更新，选 victim 时跳过正在回收、在途或受保护的 way，路数取 2 的幂）。
- L2 淘汰前保护目标行，定向失效两个 L1，协调在途回填，防止旧响应重新安装。L1D 脏副本先交回最新数据再确认失效；inclusive 不代表 L2 数据始终最新。首版每次探测两个 L1，不要求先建精确的 L1 驻留目录。
- 收齐确认、接管最新数据，并为必要写回提供可靠保存位置后，才能复用 way。容量替换不清 LR/SC reservation。
- 启动回收前预留接收/写回所需资源；探测应答不依赖普通 miss 的空闲 MSHR；资源不足时推迟新回收，不堵旧事务完成。
- 同一物理行由统一事务状态确定顺序，兼容读 miss 合并；回填、L1D 写回、淘汰、DMA 不能各自独立修改同行状态，不同行继续并行。
- 完整 L1D 行写回不需要先读 DDR；正常 inclusive 情况下，该写回应命中 L2 项或同行在途事务；正在回收时并入回收事务，不重新分配；既无驻留项又无在途事务时，应暴露包含关系错误，不能用自动重新分配掩盖。
- 总原则（用户同日确认）：简单情况要快，不改常规 load/store 流水线。回收探测与 DMA 探测共用 L1D 维护入口，L1I 回收走 ICache 维护入口，都不在普通访问路径上增加查询口或流水级。

### 35.11 同日确认的实现归属

- FENCE.I/SFENCE.VMA/satp/PMP 的系统同步由 commit_ctrl 统一编排。FENCE.I 顺序为：SQ drain → L1D 脏行扫描写回 L2 并逐出 → 前端同步（停取指/预取、隔离旧请求、ICache 全失效）→ 退休并重取。frontend_sync_ctrl 只做前端部分，不再自行发起 DCache clean。

### 35.12 仍未确认，不得冻结

- “L2 整行收齐、无错误并安装后再交付 L1，暂不 early restart”仍只是建议。
- L2 容量、路数、bank、MSHR/回收槽/写回缓冲数、AXI 宽度/ID、具体流水拍数未冻结。
- 系统 committed 预测上下文来源，以及首笔取指与恢复元数据的交接仍需闭合（前端 16.4）。

## 36. B42～B47：v1 实施计划确认（2026-10-05，已定）

用户确认 [`../O3-v1-plan.md`](../O3-v1-plan.md)。以下六项为新决定，其余已定机制不变。

### 36.1 B42：机器宽度统一为四

- 解码、重命名、派发、提交宽度均为 4；`o3_cfg_pkg` 的 `be.rename.width` 由 6 改为 4。取代 B01 的六宽重命名及“六宽消化积压”的理由。
- B02 的两拍重命名（R1 依赖预处理 + R2 原子分配）**机制保留**，作为闭环简化推迟实现：先沿用现有单拍重命名（组内旁路在 `rename_map_table`）扩为四宽；综合数据表明重命名成为关键路径时再拆分。R1 槽位号随宽度改为 2 位。

**2026-10-11 用户更新**：现在直接将实际后端 rename 拆为四宽 R1/R2，不再等待综合时序触发。
仍按 B02 保持 R1 无资源预分配、R2 同边界原子事务及固定槽部分接受机制。
本轮仅实施 RTL 重构，验证及发现的问题在后端重构完成后集中处理；实现状态见 `../LOOP.md`。

### 36.2 B43：乘法改用 DSP 实现

- 取代 B21 中“沿用 `SignedMul65x65` Booth/Dadda 树”的乘法部分。参照 Breeze T01 的新实现：65×65 有符号乘法后接 4 级寄存器，由 Vivado 推断 DSP48E2 并允许寄存器重定时，4 拍、每拍可接收一条。RISC-V 各乘法变体的输入扩展与结果选择不变。
- 理由：Breeze 旧乘法器单核约 6.8k LUT 且未用 DSP；O3 为四宽，面积压力更大。
- O3 包装要求不变（ROB 身份、按条取消、完成 FIFO，B33/B34）。除法仍按 B21 沿用 radix-4。

### 36.3 B44：SD 卡使用 AXI Quad SPI + SPI 模式

> **2026-10-08 B52：** 前提“不使用 LiteX”已撤销，SD 控制器改由 L11 spec 在 LiteX 方案下重选（候选 LiteSDCard），见第 41 节。

- 不使用 LiteX 框架（B28），Xilinx 也没有可用的免费 PL 端 SD 主控 IP。v1 使用 Vivado AXI Quad SPI IP 以 SPI 模式访问 SD 卡，Linux 使用 `mmc_spi` 驱动，OpenSBI/启动程序使用 SPI 模式读取镜像。
- 带宽为几 MB/s，满足启动与镜像加载；不追求 SD 原生 4 位模式的吞吐。
- B08 的 SD DMA 行协调合同保持：若 SPI 控制器经 DMA 访问内存，按 B08 处理；若由 CPU 以 PIO 方式搬运，DMA 行协调可作为闭环简化推迟，但接口保留。具体在 L11 的 spec 中确定。

### 36.4 B45：Spike 逐条比对作为每级门禁

> 2026-10-06 用户决定暂停：L6 之后不再运行 Spike 比对，推迟到 FPGA 阶段，见 `O3-v1-plan.md` 第 3 节“验收调整”。

- 从 L5 起，每一级的验收都包含与 Spike 的逐条退休比对：PC、指令、整数/浮点写回值、访存地址与数据、异常 cause/tval、CSR 写入，差异为 0。
- 比对按提交顺序进行；长延迟结果晚到时按目的寄存器关联。比较不一致时停止并输出两侧状态、周期和前若干条退休记录。
- 这是对乱序核正确性和实现 agent 幻觉的主要防线，不能以“ACT4 通过”替代。

### 36.5 B46：不再并行搭建目标结构

- 目标结构只在其所属闭环级接入，接入方式是替换旧数据流中对应部分；替换完成后删除被替换的旧代码和空壳。
- 不在当前级的空壳从 `backend.sv` 移除实例化，不列入 `rtl/rtl.f`，文件保留到所属级。
- 修订 `agent.md` 第 1.3 节“不要删除尚未迁移的旧数据流代码”的适用范围：被本级替换的旧代码应在本级删除。

### 36.6 B47：Breeze 组件手工翻译并做等价对照

- 复用 Breeze 的 Chisel 组件时，手工翻译为可读的 SystemVerilog，不直接使用 Chisel 生成的 Verilog。
- 验证：以同一提交的 Chisel 生成 Verilog 为参照。寄存器结构一致的模块用 Yosys `eqy` 做形式化等价检查；结构不一致的用 Verilator 并排运行两份 RTL、随机激励逐拍比较输出。参照 Verilog 只用于验证，不进入 `rtl/`。
- 组件清单与所属级见 `O3-v1-plan.md` 第 4 节。

## 37. B48：性能计数器采用 RISC-V Zihpm + Sscofpmf，供 Linux perf 使用（2026-10-06，已定）

用户确认：计数器从一开始就按 RISC-V 标准实现，SoC 完成后用 Linux `perf` 读取；Sscofpmf（溢出中断采样）也在 v1 实现。本节取代 B10、B22、B23 及前端第 12.1 节中“读取地址、清零、快照、溢出规则待定”的部分，事件口径不变。

### 37.1 软件可见接口

- 沿用现有 `mcycle`/`minstret`；新增可编程计数器 `mhpmcounter3`～`mhpmcounter(3+N-1)` 及对应 `mhpmevent`，N 参数化，首版 N=8。其余 `mhpmcounter`/`mhpmevent` 只读为 0（标准允许）。
- `mhpmevent` 低位为事件号，0 表示不计数；事件号全核统一编号（前端、后端、访存、DMA 等事件均进入同一张表），一个事件每拍可加大于 1 的增量（同拍多事件不丢失）。
- `mcountinhibit` 逐个暂停计数器；`mcounteren`/`scounteren` 控制 S/U 模式对 `cycle`/`instret`/`hpmcounterN` 的读取权限。
- Sscofpmf：`mhpmevent` 高位 OF(63)、MINH(62)、SINH(61)、UINH(60) 可写；无 H 扩展，VSINH/VUINH 只读为 0。计数器从全 1 回绕且 OF=0 时置 OF 并挂起本地计数溢出中断 LCOFI（`mip`/`mie` 第 13 位，可经 `mideleg` 委托给 S 模式）；`scountovf`（0xDA0）给出各计数器 OF 位的只读视图，受 `mcounteren` 屏蔽。
- 软件路径：Linux `riscv_pmu_sbi` → SBI PMU → OpenSBI 配置 `mhpmevent`；事件号与计数器的对应关系写在设备树 `riscv,pmu` 节点。`perf stat` 用于计数，`perf record` 依靠 LCOFI 采样。

### 37.2 分级实现

| 级 | 内容 |
| --- | --- |
| L7 | M 模式 Zihpm：`mhpmcounter3～10`、`mhpmevent3～10`、`mcountinhibit`；事件选择器；接入前端预测事件（uBTB lookup/hit、快慢比较四类、慢覆盖、target_missing、预解码/执行重定向、RAS）。冻结事件编号表 |
| L8～L10 | 各级把本级事件加入编号表；L10 随 S/U 模式加入 `mcounteren`/`scounteren`、用户态读权限、Sscofpmf 的 OF/模式过滤位、`scountovf` 与 LCOFI 中断及委托 |
| L11 | OpenSBI PMU 与设备树配置；在 FPGA 上用 `perf stat` 与 `perf record` 验证 |

### 37.3 已知边界

- 采样中断不是精确归因：`perf record` 记录的是中断进入时的 PC，可能与触发溢出的事件相隔若干条指令（skid）。首版接受，不做精确事件采样。
- 一次只能同时观测 N 种事件；需要更多事件时分多次运行。
- 计数器加法器、事件选择器的面积与时序在 L11 综合时核对。

## 38. B49：能由硬件处理的不交给软件 trap（2026-10-07，已定）

### 38.1 原则

用户确认：凡 RISC-V 允许“软件处理（trap 后模拟、SBI 调用、为记账而报异常）”与“硬件处理”二选一的地方，**选硬件处理**，并尽量放在旁路、与正常流水线并行，不给常用路径增加流水级。可以为此增加硬件与合同要求。依据：乱序核上每次 trap 都要清空流水线并串行化，代价远大于额外硬件。

- 规范对硬件的限制仍须遵守（例如 D 位不得推测置位，B36 已按此在队首非推测更新）。
- 已符合本原则、不改：B36 硬件 A/D、B07 硬件 PTW、B40 FS Dirty 硬件维护、B48 计数器 S/U 直接读取（经 `mcounteren`/`scounteren`）。
- 以后各级 spec 遇到规范允许 trap 模拟的点，默认给出硬件方案；改动已定 Bxx/Dxx 仍须用户确认。

### 38.2 跨 line / 跨页非对齐访存：硬件拆分（取代 B31 跨 line 部分）

- 普通可缓存标量 load/store（含 FLW/FLD/FSW/FSD）跨 cache line 时，LSU 拆成两次 line 内访问并拼接，仍是一条架构指令、一次完成/退休；不再报地址非对齐异常。
- 跨 4KiB 页时两半分别翻译、分别做页表权限/PMP/PMA 检查（D 位、A 位按两页各自处理）。任一半有异常时整条指令精确报告：cause 取该半的 page fault/access fault，`tval` 为出错那一半的首个虚拟地址（规范允许的选择，固定此口径）。
- load 在两半数据与检查全部完成后才交付；store 两半检查与数据齐备后才完成，drain 时两半写入。不承诺整体原子性（规范不要求）。
- 继续不拆分：MMIO / 非可缓存区域（报地址非对齐异常，保持 B31）；A 扩展 LR/SC/AMO 自然对齐（B09，规范要求）。
- 计数器：B31.1 的 `misaligned_crossline_traps` 改为性能事件 `misaligned_crossline_split`，统计**退休**的跨 line 拆分访存条数（错误路径、重放不计）；事件号随 L8 加入 B48 编号表。
- 归属：L8（随 Breeze 访存翻译与乱序优化一起实现）。L10 的 DTLB/PTW 接口须允许同一指令发起两次翻译请求，不得假定一条访存只有一个虚拟页。

### 38.3 `time` CSR 硬件读

- `time`（0xC01）由硬件直接返回 CLINT `mtime` 的值，不 trap 给 OpenSBI 模拟。核顶层增加 `mtime_i` 输入（来自 CLINT，或核内与之同步的副本）；读取受 `mcounteren.TM`、`scounteren.TM` 控制，未授权时按规范报非法指令。
- `mtime_i` 与 CPU 时钟的关系、跨时钟域方式在 L11 SoC 集成时确定；L10 仿真由 testbench 驱动。
- 归属：L10 实现 CSR 与权限；L11 接 CLINT。

### 38.4 Sstc

- 加入 Sstc：`stimecmp`（0x14D）、`menvcfg.STCE`（bit 63）。`STCE=1` 时 `mip.STIP = (time >= stimecmp)`，由硬件维护，S 模式可直接设定时器，不经 SBI ecall；`STCE=0` 时保持传统软件 STIP 路径。`mcounteren.TM=0` 时 S 模式访问 `stimecmp` 非法。
- 不做 H 扩展的 `vstimecmp`。
- 归属：L10 实现 CSR、`menvcfg.STCE` 与 STIP 比较；中断交付随 L11 中断控制接入。OpenSBI/设备树在 L11 声明 `sstc`。
- 取代 v1 计划第 5 节“不在 v1”中的 Sstc，及 B28/B29 中“首版不依赖 Sstc”的表述（传统路径保留为回退）。

### 38.5 影响范围

- 设计基线：B06（第 8 节）、B31（第 34 节）、B28（第 31 节）已加取代注记。
- v1 计划：L8 加 B49 跨 line 拆分；L10 加 `time` CSR、Sstc CSR；L11 加 Sstc 中断交付与 OpenSBI 配置；第 5 节删去 Sstc。
- RTL 头注释中引用 B31“跨 line 报异常”的位置（`load_store_unit.sv`、`dcache.sv`、`dtlb.sv`、`commit_ctrl.sv`、`backend_perf_events.sv`、`rob.sv`、`o3_types_pkg.sv` 的 `crossline_misalign`）随所在模块被 L8/L10 触及时修正，记入 `LOOP.md` 第 4 节。

## 39. B50：L8 访存以 Breeze v1 MESI/L2 Home 为机制来源，按乱序高吞吐修改（2026-10-07，已定方向）

### 39.1 用户决定

- L8 不自行重新设计缓存一致性：采用 Breeze v1 访存子系统（`~/flow-mem`，分支 `feat/v1-mem-skeleton`，参考 `docs/coherence-l2-rtl-spec.md`、`docs/l1d-rtl-spec.md` 与 `design/src/main/scala/{l1d,l2,coherence}/`）的 MESI 协议与 L2 Home 结构。
- 单核配置 `nCores=1`：客户端为 O3 的 L1D、L1I 与 SD DMA 各一个（Breeze 协议已有这三类客户端，见其 spec 1.1 节）。DMA 一致性由协议保证，取代 B08 的按行 clean+invalidate 协调与 B41 的自建回收/探测方式。
- **复用层次是机制，不是逐行翻译。** 沿用：协议消息与 MESI 状态、目录、L1D 的 MSHR/写回/probe 状态机、L2 的慢槽/probe 引擎/内存引擎状态机、流水级划分、节拍安排与同拍冲突规则。按乱序核的高吞吐要求修改规模与并发度。
- （2026-10-07 B51：参考改为 `/home/chen/leisure/flow` 提交 `a304cc2`，见第 40 节。）
- 开工时间：Breeze 访存仿真测试稳定后（其 `docs/v1-mem-plan.md` 第 4～7 步）。开工时重新核对当时的 Breeze 提交，并在 L8 spec 中固定参考提交号。

### 39.2 按乱序吞吐修改的已知项

- L1D 非阻塞：多 MSHR、hit-under-miss、同 line 合并；L1D 多笔 Get 同时在途，链路 `id` 宽度、RSP↓ 缓冲深度、L2 慢槽数随之扩展（Breeze v1 锁定 1 个 MSHR，但其结构按 N 写）。
- 接 O3 的 LQ/SQ、事件重放与精确异常（B03～B05、B32），以及 L9 起的浮点访存。
- B36 硬件 A/D：L1D 增加“完整 64 位 PTE 比较 + 条件置 A/D”入口（Breeze PTW 只读，A=0 报 page fault，不符合 B49）。
- B49 跨 line/跨页非对齐硬件拆分；B09/B35 的 AMO 与 LR/SC reservation 接入。
- L10 的 PTW 访问 L1D 采用与 Breeze `PtwMemIO` 同形的接口（物理地址请求；64 位数据 + 访问错误响应），L8 替换 L1D 时 PTW 侧不改。
- L1I 不接收 snoop（Breeze 协议如此）；指令与数据写入的同步继续由 FENCE.I（D25）保证，DMA 写入代码页后由软件执行 FENCE.I。

### 39.3 待定（L8 spec 闭合）

> **2026-10-07 B51：** 下表各项已在 40.2 节闭合。

| 项 | Breeze v1 | O3 现状 | 待定内容 |
| --- | --- | --- | --- |
| 行大小 | 锁定 32B（一行一拍 256 位链路） | 64B（D11，ICache 按 64B） | 保持 64B 并改链路为 512 位或两拍，或 O3 改 32B（牵动 ICache、B31/B49 跨 line 判定） |
| 物理地址 | 锁定 32 位，PMA 判 ≥2^32 为不存在 | `paddr_bits=56` | 倾向沿用：可缓存区在 4 GiB 以下（KCU105 DDR 满足），≥2^32 由 PMA 判不存在 |
| MSHR / 慢槽 / 在途上界 | 1 / 2 / Get 1 | cfg 建议 4～8 | 按吞吐与资源定 |
| L2 容量、路数 | 参数推导 | cfg 现值 | L8 spec 定，L11 综合后调整 |

### 39.4 验证

- B47 的等价检查只适用于逐行翻译的组件，不适用于本节（结构已修改）。L8 用 O3 自己的测试，借用 Breeze 的校验思路：黄金内存逐 load 比对、SWMR 与目录一致性监视、看门狗、极小 cache 压力配置。
- 验收仍按 2026-10-06 策略：本级机制定向测试 + 整核自查；litmus 与完整一致性测试推迟到 FPGA。

## 40. B51：L8 乱序访存微架构（2026-10-07，用户确认）

在 B50 的方向下闭合 39.3 节待定项，并确定 Breeze v1 访存改为乱序核所需的结构。机制参考固定为 Breeze `/home/chen/leisure/flow` 分支 `feat/pcie-fase-20260920` 提交 `a304cc2`（Breeze 访存计划第 4～6 步的 Alan 证据在此提交；`~/flow-mem` 的 `feat/v1-mem-skeleton` 停在骨架阶段，不再作为参考）。L8 spec 开工时如 Breeze 有新提交，重新核对后再改参考号。

### 40.1 组织原则：三类等待者

- **流水线**只做固定拍数的工作，永不因慢请求停顿。L1D 的 S0/S1/S2/PS 与 L2 主流水、快路径沿用 Breeze。
- **行事务状态机**管理以 cache 行为单位的慢操作：L1D MSHR、写回槽、probe 处理，L2 慢槽、probe 引擎、内存引擎，以及 PTW。机制沿用 Breeze，数量放大。
- **LQ/SQ** 管理指令身份与等待原因。慢请求离开流水线回到 LQ/SQ 项，状态机完成后发出事件（如“MSHR k 安装完成”“MSHR 有空位”“PTW 完成”），等待者重新发射并再走快路径（即 B04 6.2 节的流程）。
- 取代 Breeze 的 `s2Hold`（后端停在 WB 等 L1D）：L1D 在 S2 给出 `Hit`（带数据）、`Miss(mshr_id)` 或 `Replay(原因)`。`s1Kill/s2Kill` 改为请求自带 LQ/SQ/ROB 身份与代际，按身份取消，迟到结果丢弃。
- 例外：AMO、aq/rl LR/SC、MMIO 等到 ROB 队头才执行的独占类请求，沿用 Breeze 的独占路径（B05、B09）。

### 40.2 几何与宽度（闭合 39.3 节）

| 项 | 决定 | 理由 |
| --- | --- | --- |
| 行大小 | 64B（D11 不变）；L1D/L1I/DMA 与 L2 之间的协议链路数据 512 位，一拍一行 | 保留 Breeze “一行一拍”的节拍与同拍冲突规则；一行等于 KCU105 64 位 DDR4 的一次 BL8 突发；ICache 不改行大小 |
| 物理地址 | 架构可见部分保持 `paddr_bits=56`（satp、PTE、TLB、PMP）；L1D/L1I/L2/链路使用参数 `mem_paddr_bits=32` | KCU105 的 DDR 与 MMIO 均在 4 GiB 以下；与 Breeze 一致，省 tag/目录。进入 cache 之前由 PMA 把 ≥2^32 判为不存在，报 access fault，PTW 读也一样，不得截断高位 |
| L1D | 32KB、8 路、64 组（每路 4KB，VIPT 无别名） | 64 组时 BRAM 深度用不满，16KB→32KB 的 BRAM 块数相近；代价是 8 路 tag 比较 |
| L1D MSHR / 写回槽 | 4 / 2，参数化；支持同行合并 | 覆盖两条 AGU 的常见并行度 |
| L1I 在途 Read | 等于 ICache MSHR 数（现为 4），链路 `id` 2 位 | Breeze L1I 为 2（demand + 预取），O3 前端已有 4 |
| L2 | 256KB、8 路（512 组），参数化；BRAM 不足时退回 128KB 8 路，L11 综合后调整 | inclusive 下 L2 约为 L1 总量的 8 倍；8 路减少替换造成的 L1 回收 |
| L2 慢槽 | 8，参数化 | 满时 REQ 反压（Breeze 依赖纪律允许 REQ 接收依赖其他链路）|
| RSP↓ 输出 FIFO | 每个客户端深度 = 该客户端最大在途响应数（L1D = MSHR + 写回槽 = 6） | 沿用 Breeze 规则，S2 写入时必有空位 |
| AXI 内存引擎 | 读在途 = 慢槽数；写缓冲 2～4；数据位宽在 L11 随 MIG 定 | |

### 40.3 L1D 结构

- 两条 load 管道，S0/S1/S2 沿用 Breeze 三级划分。**两条 AGU 管道都能执行 load 和 store 地址**，都连接 SQ 查询（取代 B03 的“一条 load + 一条 load/store”草案）。
- 数据阵列按 8B 字分 8 个 bank。两条管道访问不同 bank 时并行；同 bank 不同 set 时较年轻的一条 `Replay(bank)`。整行操作（回填安装、写回读出、probe 读出）一拍访问全部 bank，一拍完成，取代 Breeze 每拍一字的串行整行操作（Breeze 不分 bank 是因为 4 核 BRAM 不够；O3 为单核）。
- tag/状态阵列提供两个读口：放 LUTRAM 并复制两份，写时两份同写。具体实现可由 spec 调整，但必须保证两条管道同拍查 tag。
- 沿用 Breeze：快照失效（同 set 在读阵列与判定之间被改写则重查，改为 `Replay`）、S0 与 PS 的冲突检查、PS 写级、锁定 way 的 PLRU、refill 错误只清 tag、LR/SC reservation、AMO 独占路径、阻塞 MMIO、`PtwMemIO` 形式的 PTW 入口。
- MSHR 只跟踪行事务（地址、GetS/GetM、目标 way、回填数据与错误），不保存原请求，也不负责回放。等待同一行的 load 记在 LQ 项里（等待原因 + `mshr_id`），可以有多个；安装完成后唤醒它们，重新走快路径（B04 已定“先安装后唤醒”）。回填数据直接转给等待 load 的旁路以后由测量决定。
- 预留一个 MSHR 给 PTW 和 ROB 队头请求，保证前进（B07）。预取永远不占用最后一个空闲 MSHR。

### 40.4 Store 路径

- 保持 B05：SQ 兼任 committed store buffer，按序 drain，经 PS 写入 L1D；不新增独立 SBuffer。
- **新增 store 所有权预取（RFO）**：store 地址翻译并检查通过后（可早于提交），若该行不在 L1D 或只是 S 态，就以低优先级发 GetM 预取。它不改变架构可见顺序，只为让提交后的 drain 命中，避免 SQ 队头 miss 卡住全部 store。遵守 40.6 节的预取纪律。

### 40.5 访存依赖

| 关系 | 处理 | 阶段 |
| --- | --- | --- |
| store→load 同地址 | SQ 转发：程序序最近的一条更老 store 完整覆盖时转发，部分重叠则等待（B04 6.1 节不变） | L8a |
| 更老 store 地址未知 | L8a 保持 B32 保守等待；L8c 改为推测，见下 | L8a / L8c |
| load→load 同地址，DMA 改写 | L1D 处理使某一行失效的 probe 时，在 LQ 中查找该行上已执行、未退休的 load，从最老的一条起冲刷重做（保守但低频）| L8b |
| store→store | SQ 按序 drain，天然满足 | — |
| FENCE、AMO、LR/SC、MMIO | 到 ROB 队头，按 B09/B23 先等 SQ 排空再执行；aq/rl 按语义处理 | L8b |

**L8c 访存依赖推测（取代 B32 “首版不推测”的部分）：**
1. load 可以越过地址未知的更老 store 先执行。
2. store 地址确定时，在 LQ 中查找更年轻、已执行、字节重叠的 load；查到就从该 load 起冲刷重做。这一步是正确性保障，必须完整。
3. 按 load PC 索引的 1 位“必须等待”表：发生第 2 步冲刷的 load 置位，置位后按 B32 等待；周期性清零。表深在 spec 中定。
4. 测得冲刷仍多时再升级为 Store Set。B32“不能用固定超时无条件越过”继续有效。

### 40.6 预取

| 预取 | 阶段 |
| --- | --- |
| store 所有权预取（40.4 节） | L8a |
| L1I 下一行预取 | 保留 O3 前端现有的 |
| L1D stride 预取（B07） | L8c |
| load 地址预测（B25） | L8c，在 stride 之后 |
| L2 流式预取 | 暂不做，FPGA 实测 DDR 延迟确实是瓶颈后再定 |

共同纪律：与现有 MSHR 和 cache 内容去重；不占用最后一个空闲 MSHR；不访问 MMIO，不为预取启动 PTW；失败静默丢弃，不产生架构异常；带 useful/late/unused 计数（B10、B48）。

### 40.7 L1I 与 FENCE.I（取代 B23、D25 的数据侧部分）

- L1I 是协议的只读客户端：只发 `Read`，不进 L2 目录，不接收 snoop，没有 MESI 状态。L2 处理 `Read` 时，若该行在 L1D 为 UNIQUE，先向 L1D 发 Down probe 拿到最新数据（Breeze L2 spec 4.4 节），所以 L1I 每次 miss 都拿到 L2 层面的最新数据。
- L2 对 L1I 不是 inclusive 的：L2 替换不回收 L1I 行，删除 O3 现有 L2 对 L1I 的回收逻辑（B41 的“覆盖 L1I”部分不再适用）。L1I 只读，取指与 store 的一致性由 FENCE.I 保证。
- **FENCE.I** 改为：(1) 等 SQ 排空，所有更老 store 都得到 L1D 写完成确认；(2) 整个 L1I 置无效；(3) 冲刷前端（fetch buffer、FTQ 中年轻项、预解码结果），并按 D25 隔离旧 ICache miss/预取的迟到返回；(4) 从下一条重新取指。**不再遍历 L1D 写回脏行**：L1I 重新 miss 时，L2 会通过 probe 拿到 L1D 的脏数据。这与 Breeze 的做法一致（FENCE.I 只等 `drained`）。
- B23 的两个计数器中，`fencei_retired` 保留；`fencei_dcache_evict_cycles` 不再有对应阶段，取消。现有 RTL 中 `dcache.sv` 的 clean-all 路径、`commit_ctrl.sv` 的 `dcache_clean_all_busy_i` 与事件 `BE_FENCEI_DCACHE_EVICT_CYCLE` 在 L8b 删除；事件编码是否保留为恒 0 由 spec 定。
- 软件责任：自修改代码/JIT、加载程序，以及 DMA 写入代码页之后，由软件执行 FENCE.I。

### 40.8 L2

- Breeze L2 Home 机制整体沿用：S0～S2 主流水、REQ 到 S2 才握手、同 set 串行、快路径 + 慢槽、probe 引擎、Put 缓冲、精确目录（`nCores=1`，客户端为 L1D、L1I、DMA）。
- 规模按 40.2 节。L2 数据阵列一行 512 位：spec 先核对 Breeze L2 读数据的方式；倾向先比 tag 再只读命中的那一路，不要 8 路同时读 512 位。

### 40.9 分步与验收

| 步 | 内容 | 验收 |
| --- | --- | --- |
| L8a | 非阻塞底座：40.1 节重放接口、bank 化 L1D 与两条管道、4 MSHR + 合并、L2 Home 与 8 慢槽、协议链路、L1I 改为客户端、store 所有权预取 | 移植 Breeze 单核测试思路（黄金内存、SWMR 与目录监视、看门狗），MSHR=1 与 4 各跑，加极小 cache 压力配置随机测试；整核既有回归 |
| L8b | A 扩展、FENCE、FENCE.I（40.7 节）、PTW 与硬件 A/D 接回、B49 跨行拆分、DMA 客户端、probe 触发的 load 顺序冲刷 | 定向测试 + 整核自查 + 看门狗 |
| L8c | 访存依赖推测与 1 位等待表、L1D stride 预取、B25 | 冲刷正确性定向测试；IPC 与性能事件前后对比 |

litmus 与完整一致性测试按 2026-10-06 策略推迟到 FPGA。按 B47，结构已修改的组件不做逐行等价检查。

### 40.10 资源

按上述几何，BRAM 粗估为 L1D 数据约 64 块 BRAM36（8 个字 bank × 每 bank 512 位宽，64 组只用到 BRAM 深度的 1/8；2026-10-07 写 L8a spec 时修正，原估 16～32 块有误）、L2 约 60～70 块，合计约 130/600。LUT 主要花在 LQ/SQ 地址比较、两条管道的 8 路 tag 比较、512 位多路选择和 L2 慢槽上，数字以 L11 综合为准。

## 41. B52：L11 SoC 改用 LiteX，核与 SoC 之间只用 AXI（2026-10-08，用户确认）

> 2026-10-09 用户修订：第一版完整 SoC 包含 LiteSDCard 与一致性 DMA，先写代码后补测试。Breeze 组件复制/手工翻译到 O3，不 fork、不加子模块、不在构建时跨仓库引用；具体接口与适配见 L11a spec 第 15 节。

- **取代**：B28 的“不采用 LiteX、Vivado IP + 自写 SoC”；B44 的 SD 控制器选型前提；计划中 L11 的“Vivado MIG”。B28/B29 的平台范围、CLINT/PLIC 语义复用、定时器与 Sstc 路线不变。
- **理由**：B28 拒绝 LiteX 的顾虑是 Wishbone 桥的性能损失。Breeze 已在同一块 KCU105 上实现 SOC-axi 接法（`/home/chen/leisure/flow` `docs/cluster-soc-rtl-spec.md`、`fpga/kcu105/target.py`）：核内存口 AXI4 经 SoC 侧路由器直连 LiteDRAM 的 AXI 端口，可缓存通路不经过 Wishbone；只有 boot ROM/SRAM 与 AXI-Lite MMIO 经 LiteX 自带桥进入主总线，均为低带宽或阻塞单字访问。采用 LiteX 可复用 Breeze 的 KCU105 target、AXI 路由（R/B 按 AR/AW 顺序）、BIOS 冒烟、LiteDRAM 仿真模型，以及 LiteX 的 SD 加载、设备树生成与 Linux 主线驱动。
- **边界**：O3 核对 SoC 只暴露 AXI4 内存口与 AXI4-Lite MMIO 口（L8a/L8b 已有）。不修改核内 L1D/L2/后端行为来适配 SoC；SoC 侧不得吞响应或改顺序（同 Breeze C1/C2）。
- **DDR**：LiteDRAM（USDDRPHY）。O3 L2 内存口位宽在 L11 spec 中按 LiteDRAM native 口确定（L8a X10 的“随 MIG 改”改为“随 LiteDRAM 改”）。上板后用 HPM 测 L2 miss 延迟；若 DDR 延迟成为瓶颈，再评估在 LiteX 内改接 MIG，不在 L11 首版做。
- **DMA 一致性**：O3 已有一致性 DMA 客户端口（`o3_core.sv` 的 `dma_req_*`，L8b）。任何 SoC 侧 DMA 主设备（如 SD 控制器）写主存必须经该口进入 L2 Home，不得直接写 LiteDRAM 绕过 cache 一致性；做不到时首版改用 CPU PIO。具体在 L11 spec 中确定。
- **待 L11 spec 闭合**：SD 控制器及其 DMA 接法、UART 型号、地址图（是否沿用 Breeze `config/breeze_mcu_platform.json`）、LiteX 主总线是否改 `bus_standard='axi'`、CLINT/PLIC 的 AXI-Lite 接法、FASE 接入、启动链（LiteX BIOS → OpenSBI/DTB/Linux）。

## 附录 A：已被取代的历史决策

以下各节已被后续决定取代，仅作历史记录保留，不得据此实现。

### A.1 B16：整数算术 IP 的来源约束与候选（2026-10-01）

#### A.1.1 用户明确的筛选要求

仅考虑独立算术库/IP，不为复用乘除法而 clone 另一套 CPU 或引入其配置/流水线框架。CVA6、Rocket、VexiiRiscv 的 CPU 内部组件退出移植候选；此前只下载少量文件到 /tmp 做只读核对，没有 clone 或引入依赖。用户进一步授权：独立开源实现不合适时，可以采用 Vivado IP。此授权不表示 IP 已生成或 RTL 已接入。

#### A.1.2 独立库的实际核对

- BaseJump STL 固定提交 `3753148c8f57cbbd878d2b535070c51a5b00c390` 是独立 SystemVerilog 硬件库，符合来源要求。
- `bsg_misc/bsg_idiv_iterative.sv`：参数化 width，signed/unsigned，输出 quotient 与 remainder，支持每次迭代 1/2 bit，使用输入 valid/ready 和输出 valid/yumi；控制器 DONE 保持至消费。可作为 64 位迭代 DIV/REM 候选。依赖同库基础模块，需要显式列出小规模依赖闭包；本轮未编译或验证 width=64。没有独立 kill/tag 端口，需 O3 包装保存身份并管理取消，不能当作整核 reset。
- 同提交 `bsg_misc/bsg_mul_pipelined.sv` 采用 Booth/compressor 结构，实际 generate 只支持 width=16/32，不能仅修改参数就得到 64 位流水乘法；也不把 ASIC 结构自动说成 KCU105 DSP 优化方案。迭代 `bsg_imul_iterative.sv` 可进一步评估，但不是当前高吞吐乘法的首选。
- 独立 `risclite/verilog-divider` 提交 `e73dec16750b45bd9e01d82848251e564a4d5354` 的 `divfunc.v` 可参数化并用 STAGE_LIST 切分，输出无符号商/余数，但没有结果 ready/背压或取消接口；不是即插即用的 RV64M FU，当前不优先。

源代码：[BaseJump divider](https://github.com/bespoke-silicon-group/basejump_stl/blob/3753148c8f57cbbd878d2b535070c51a5b00c390/bsg_misc/bsg_idiv_iterative.sv)、[BaseJump multiplier](https://github.com/bespoke-silicon-group/basejump_stl/blob/3753148c8f57cbbd878d2b535070c51a5b00c390/bsg_misc/bsg_mul_pipelined.sv)、[独立 divider](https://github.com/risclite/verilog-divider/blob/e73dec16750b45bd9e01d82848251e564a4d5354/divfunc.v)。本轮只读审查，不将项目测试或历史性能移作本核心证据。

#### A.1.3 Vivado 乘除法 IP（来源已确认，配置待定）

用户随后明确“用 vivado 的 ip”：整数 MUL 与 DIV/REM 均采用 Vivado IP。独立开源候选只保留为研究记录，不继续推进 BaseJump 的首版接入。

后续用户已明确改为仅复用 Breeze 的整数乘除法，未来转写 SV，见 B21。以上仅保留此前选择，不表示已生成 IP，不再是当前实施路线。

本轮核对 AMD 官方 Multiplier v12.0 PG108（2015-11-18）及 Divider Generator v5.1 PG151（2021-02-04），实际安装工具的版本以后生成时复核。

- **乘法建议**：优先使用 Multiplier Generator，64×64 unsigned、完整 128 位结果、DSP 实现及真实流水寄存配置。RISC-V MUL/MULW 取低位；MULH/MULHSU 可在包装中根据原操作数做高半部符号修正，避免为每种符号组合复制 IP。PG108 输入上限为 64 位，不能未经核对提出 65×65 配置。流水级数依 OOC/整核时序确定，valid/tag 随运算推进，出口有容量或统一停顿机制保证不会丢结果。
- **除法建议配置**：使用 Divider Generator 的 Radix-2 integer remainder 模式。PG151 的 High Radix 只支持 fractional 输出，不能把它直接等同同时返回 RV64 DIV/REM。Clocks per Division、延迟、Blocking 与 output TREADY 具体配置待定，不默认需要满流水除法吞吐。
- Vivado 除零商/余数不能当作 RV64M 规定值：PG151 明确这些输出 undefined。包装必须独立处理除零、signed overflow 和 word 输入/输出语义；状态、ROB 身份、背压和取消同样由核心侧负责。
- 以上是建议，未生成 IP、未修改 RTL、未运行 OOC 综合/仿真/整核时序。未来为厂商实现保留统一 FU 包装与明确的仿真模型入口；模型通过不等于 FPGA IP 或整核时序通过。

官方来源：[PG108](https://docs.amd.com/api/khub/documents/idOj3Pp9ocZdMoFz3IpkjQ/content)、[PG151](https://docs.amd.com/api/khub/documents/c_0ZEADkbrJCz1MvCirYoQ/content)。

### A.2 B17：Vivado IP 的仿真交付与整核验证路线（2026-10-01，建议待落实）

状态：历史参考，随 B21 确认复用 Breeze 整数乘除法而退出当前路线。不要求为本代首版建立本节厂商模型/替代模型双入口。

用户要求先仿真再 FPGA。本轮重新只读核对 `sim/o3/Makefile`：当前整核使用 Verilator + C++ 驱动；没有生成 Vivado MUL/DIV IP。本地 PATH 查到 Verilator，未查到 Vivado/xsim；不据此断言其他目录、Windows 或远程主机未安装。

#### A.2.1 官方模型的证据

- PG108 v12.0 IP Facts：Multiplier 提供 encrypted VHDL simulation model；可验证选定流水配置及 CE 控制。它不是可直接加入 Verilator 的普通 SV 文件。
- PG151 v5.1 IP Facts 及 Appendix A Simulation Changes：Divider 提供 encrypted VHDL 模型，该模型相对最终 netlist bit/cycle accurate；官方模型可检验 AXI4-Stream 接受、返回、背压和复位。
- PG151 Chapter 5：另有 C shared-library 数值模型，bit accurate，但不 cycle accurate，不模拟延迟、接口信号或 tuser；除零数值也不构成架构语义保证。不能仅把 C 模型接到 DPI 就声称验证了 IP 握手或核心性能。
- XSim 支持混合语言；UG900 2022.2 的 `export_simulation` 可导出 xsim/questa/vcs 等脚本，不包含 Verilator。Verilator 官方 Input Languages 说明其不能使用 encrypted RTL。

#### A.2.2 建议保留两个相互对照的入口

1. **XSim 真实 IP + 同一 FU 包装**：固定 Vivado/IP 版本和 XCI/生成 Tcl 参数，生成 simulation output products，添加包装及 SV testbench，运行 behavioral simulation。通过脚本记录请求接受、结果返回、复位/取消以及 ROB/目的身份；无需先做整核布局布线。可以进一步将后端 RTL 纳入 XSim，原 Verilator C++ 驱动需另作适配，不能声称原二进制能直接驱动 XSim。
2. **Verilator 快速整核**：包装内算术 IP 例化可切换为项目自有的 SV 行为模型。核心侧真实的调度、身份、写回、恢复控制包装保持相同；模型需要覆盖具体配置的 CE/流水推进、接口缓冲/握手、结果稳定、复位等可观察行为，不能只用 `*`、`/` 算值再任意等几拍。
3. 用同一组带周期的输入激励在 XSim 官方模型和 Verilator 模型下运行，并逐周期对比接受、返回和数值。覆盖连续请求、输入两路不同步、长时间输出背压、复位以及恢复当拍/迟到结果。IP 模型自身的核对与 RISC-V FU 包装的特殊值/取消测试分开归因。官方模型对照通过后，才把行为模型用于性能评估；仍需说明采用的是模型，非 FPGA 测量。

XSim 工程已添加 IP、包装和 testbench 后，可以 `generate_target simulation [get_ips {...}]`，再 `launch_simulation -mode behavioral`；或使用 `export_simulation -simulator xsim -directory ... -force` 导出批处理脚本。此为建议流程，IP 名称、工程入口及运行脚本尚未创建或验证。

以上没有改变“RTL 仿真 → 综合/时序 → FPGA”的证据顺序；官方 IP 模型仿真与快速行为模型仿真必须分别记录。本轮只更新文档，没有创建 IP、修改 RTL、编译或运行仿真。

来源：[PG108](https://docs.amd.com/api/khub/documents/idOj3Pp9ocZdMoFz3IpkjQ/content)、[PG151](https://docs.amd.com/api/khub/documents/c_0ZEADkbrJCz1MvCirYoQ/content)、[UG900 2022.2 export_simulation](https://docs.amd.com/r/2022.2-English/ug900-vivado-logic-simulation/export_simulation)、[Verilator Input Languages](https://verilator.org/guide/latest/languages.html)。

### A.3 B19：新自研整数乘除法的 FPGA 优化方向（2026-10-01）

状态：本节为历史候选研究，已被 B21 的“复用 Breeze 整数乘除法，优化后置”决定替代。DSP 映射、unsigned 64×64 高位修正和 radix-2 改法均未进入当前首版方案。

用户允许采用新的自研实现，以优化旧 Breeze 资源开销。当前仍在设计讨论，不直接修改 RTL。新数据通路为优先方向；B18 保留旧实现的审查结果，B16/B17 保留 Vivado 备选，不继续按旧乘法树直接移植。

#### A.3.1 资源证据边界

本轮读取 `docs/plans/2026-09-10-kcu105-bram-ila-resource.md`：源提交 `cbcee530960d0aae51902c9b2fe54006bf21a0a9`、四 hart、50 MHz 的历史 routed checkpoint 归因中，整数 multiplier 触及 5,431 个 CLB site，其中 1,513 个仅由该组占用。这是四核汇总的重叠位置集合，不是单个乘法器 LUT 数，也不保证重写会释放等量 CLB。该表没有整数 divider 的独立面积归因；FPU 的 divide/sqrt 不能当作整数除法面积。文档所列本地原始报告目录本轮未找到，不能声称已复核原始 rpt 或最新 100 MHz 关键路径。

#### A.3.2 本轮重点：DSP 映射的自研乘法 FU（建议，结构细节待定）

旧 `SignedMul65x65` 显式构造 Booth 部分积和 Bool 级 full/half adder 的 Dadda 树，不能期待综合器可靠还原成 DSP 乘法。建议新 FU 用普通可综合 RTL 表达分块乘法和寄存流水，让小乘法映射到 DSP48E2，而非继续扩大 LUT 压缩树。AMD UG579 v1.11 的 DSP48E2 为 signed 27×18 乘法；无符号块必须考虑额外符号零位，不能直接把任意 unsigned 27×18 当作一块 DSP 能容纳。

建议计算一个 unsigned 64×64→128 位积 P。MUL/MULW 取低位；MULHU 取 P[127:64]；MULHSU 的高半部在 a 为负时减去 b；MULH 再在 b 为负时减去 a，运算按 64 位模数。这样不必构造 65×65 的完整有符号树。符号修正是独立可流水的宽减法，不能忽略其面积和时序。

流程：操作数就绪且取得发射/结果容量后，捕获输入、操作及身份；DSP 小乘法并行产生部分积，后续寄存边界逐级合并，最后符号修正及结果选择，进入可保持的完成缓冲。建议保留每拍接收一条乘法的能力，不冻结三拍延迟；块宽、DSP 数、合并方式、流水级数需要 OOC 和整核数据决定。每拍一条需要相应并行硬件，不能同时声称大幅复用 DSP 而不影响吞吐。

正常写回竞争时保持结果；发射前预留返回容量，或另行设计可靠的流水停顿协议。误预测时逐条清除年轻 token，保留老操作，迟到数据不可更新 PRF/ROB；身份与数值随相同寄存边界推进。代价是 DSP、合并/修正逻辑、流水寄存器和完成缓冲，收益目标是减少 LUT/布线压力，不承诺具体百分比或已达到 100 MHz。

仿真使用同一份普通 RTL，包括实际寄存流水中的小乘法表达式；综合引导 DSP 映射。属性只作引导，必须检查实际 DSP/LUT 归因。若后续必须直接例化厂商 primitive，需另行闭合其仿真路线，不能称普通 Verilator 已支持未处理的 primitive。

#### A.3.3 除法后续单独闭合

建议评估每拍一步 radix-2 迭代，采用固定移位和复用加减通路，减少旧实现每拍两次串联比较/减法及动态对齐网络的开销；最坏迭代数可能由 32 增至 64，早退出及 FU 总延迟另定。此为资源/时序与延迟的交换，不声称 radix-2 必然优于旧实现。没有冻结除法算法或修改其 RTL。本轮未生成、编译、仿真或综合新 FU。

参考：[AMD UG579 v1.11](https://docs.amd.com/api/khub/documents/pTysoma4TYgNH95BrY1Sbw/content)。保持前端第 16 节交付及 B12 恢复合同。

### A.4 B20：先落实 SV 流水乘法与迭代除法，优化后置（2026-10-01，方向已定）

最终澄清见 B21：这里的未来 SV 实现是转写 Breeze 的整数乘除法，而非重新选择算法；“待会改为 SV”不是当前开始编码的授权。除法沿用 Breeze 数据通路方向，尚待闭合的是 O3 控制与接入细节。

用户明确：先将当前多拍乘法改为可流水执行的实现，资源优化以后再讨论；当前 Breeze 算术实现是 Chisel，后续乘法、除法都改为 SystemVerilog。本轮仍为设计记录，用户说“待会改为 SV”，不据此提前修改 RTL。

- **乘法机制已定**：实现真实寄存分级的流水运算，支持不同乘法指令重叠执行，以每拍可接受一条为首版设计目标。不能只在接收时组合完成乘法再倒计时，也不能仅在完整组合乘法后加延迟寄存器就称拆分算术关键路径。Breeze `SignedMul65x65` 已有三级实际算术流水，可作为结构参考；移植到 SV 后的具体延迟及寄存边界仍需验证，不冻结 100 MHz 结论。
- **除法方向**：SV 实现真实迭代运算，单元可保持单请求在途；不要求与乘法一样每拍接受一条。算法、迭代位数和总延迟另行闭合，避免将“乘法可流水”自动扩大为“除法全流水”。
- **实现来源**：首版采用项目自有普通 SV 算术 RTL，不例化 Vivado 算术 IP 或 DSP primitive；仿真和综合使用相同数据通路。未来是否优化 DSP 映射、位宽、压缩树或迭代结构依据测量再定，B19 不再作为当前首版要求。
- **O3 控制合同继续有效**：身份/操作/目的物理寄存器随数值推进；完成结果遇写回竞争可保持；发射与结果容量协调；恢复逐条取消年轻操作而保留老操作。符合前端第 16 节和 B12，不能直接照搬 Breeze 全局 flush。

当前 O3 的 `mul_execute_unit.sv` / `div_execute_unit.sv` 是已有 SV 占位实现，Breeze 内核为 Chisel；必须区分这两个来源。本轮没有修改它们，没有编译、仿真、综合或时序证据。后续进入实施时再落实 SV 文件、接口、测试与整核集成。
