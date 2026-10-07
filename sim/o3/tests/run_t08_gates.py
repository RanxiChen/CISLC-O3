import argparse,json,subprocess,time,pathlib,xml.etree.ElementTree as ET
p=argparse.ArgumentParser();p.add_argument('evidence');p.add_argument('--modules',nargs='*');p.add_argument('--core',action='store_true');p.add_argument('--build',action='store_true');p.add_argument('--vm-ad',default='0');a=p.parse_args()
root=pathlib.Path.cwd();out=root/a.evidence;out.mkdir(parents=True,exist_ok=True)
mods=a.modules
if mods is None:mods='ubtb main_btb tage ras branch_recovery fetch_buffer fetch_return_queue bpu_slow_check redirect_arbiter bpu rvc_expander ifu_f0 ifu_f1 l7_recovery hpm_counters csr_file fpu_fu pmp_checker wfi_ctrl decoder commit_ctrl frontend_sync_ctrl icache backend backend_control backend_issue_queue free_list rename_entry_gate rename_map_table rename_stage rob prf_read_arbiter fu_completion_fifo wb_alu_kill trap_ctrl mmu'.split()+['ftq']
commands=[]
def run(name,cmd):
    print('START',name,flush=True);t=time.time()
    with (out/(name+'.log')).open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
    entry=dict(name=name,command=cmd,cwd=str(root),exit=r.returncode,seconds=round(time.time()-t,3))
    if name in mods:
        result=root/'sim/cocotb'/('bpu' if name=='ftq' else name)/('ftq_training_tb_top-results.xml' if name=='ftq' else 'results.xml')
        files=[result]+list(result.parent.glob('*results.xml'))
        latest=max([x for x in files if x.exists()],key=lambda x:x.stat().st_mtime,default=None)
        if latest:
            cases=ET.parse(latest).findall('.//testcase');entry['tests']=len(cases);entry['fail']=sum(c.find('failure') is not None for c in cases);entry['skip']=sum(c.find('skipped') is not None for c in cases)
    commands.append(entry)
    with (out/'commands.jsonl').open('a') as f:f.write(json.dumps(entry)+'\n')
    print('END',name,entry,flush=True)
if a.build:run('build',['make','-C','sim/o3','build','VERILATOR=verilator -j 8'])
for m in mods:
    cmd=['make','-C','sim/cocotb/'+('bpu' if m=='ftq' else m),'-j8','SIM=verilator','TEST_SEED=1','SIM_BUILD='+str(out/('build-'+m))]
    if m=='ftq':cmd+=['COCOTB_TOPLEVEL=ftq_training_tb_top','COCOTB_TEST_MODULES=test_ftq']
    run(m,cmd)
run('lint',['bash','scripts/lint.sh'])
if a.core:
    for target in 'run-smoke run-rv64i-instructions run-l3-branch-dense run-l7-predict run-l7b-rvc run-l9-fp-smoke run-l9-fp run-replay-order run-l10-priv run-l10-vm'.split():run(target,['make','-C','sim/o3',target,'SPIKE_ARGS=+L7_CHECK','VM_AD='+a.vm_ad])
(out/'summary.json').write_text(json.dumps(commands,indent=2))
