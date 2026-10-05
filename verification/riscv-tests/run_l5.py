#!/usr/bin/env python3
"""Compile unmodified upstream rv64mi bodies with an M-only L5 boot/mailbox harness."""
import argparse,json,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--output',required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[2];src=Path(a.source).resolve();out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=True)
harness=Path(__file__).parent/'l5';cc='/home/chen/opt/act4/gcc-2026.07.15/bin/riscv64-unknown-elf-gcc'
sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=src,text=True).strip()
results=[]
for name in ['csr','mcsr','illegal','sbreak','scall']:
 elf=out/f'rv64mi-p-{name}.elf'
 cmd=[cc,'-march=rv64i_zicsr_zifencei','-mabi=lp64','-mcmodel=medany','-nostdlib','-nostartfiles','-static',
      '-I'+str(harness),'-I'+str(src/'isa/macros/scalar'),'-I'+str(src/'env'),'-I'+str(src/'isa'),
      '-T'+str(harness/'link.ld'),str(src/'isa/rv64mi'/f'{name}.S'),'-o',str(elf)]
 with (out/(name+'-build.log')).open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
 rec={'name':name,'source_sha':sha,'build_command':cmd,'build_code':r.returncode}
 if r.returncode==0:
  command=[str(root/'sim/o3/build/Vo3_tandem_top'),'--spike','--image',str(elf),'--trace',str(out/(name+'.jsonl')),
           '--tohost-address','0x801ff000','--max-cycles','1000000','--max-retires','1000000']
  with (out/(name+'.log')).open('w') as f:r=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,env={k:v for k,v in os.environ.items() if k!='O3_INJECT'})
  rec.update(command=command,run_code=r.returncode)
 results.append(rec);print(json.dumps(rec),flush=True)
(out/'summary.json').write_text(json.dumps({'source_sha':sha,'results':results},indent=2)+'\n')
raise SystemExit(any(r.get('run_code',1)!=0 for r in results))
