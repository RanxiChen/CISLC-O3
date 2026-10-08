"""Independently extract retired CSR-read/SD samples; performance is descriptive.
Architectural PASS, frozen sampling, exact sample identity and switch-off events
are correctness gates. No counter state is accessed in the RTL simulator."""
import argparse,json
from pathlib import Path
BASE=0x80100000
EVENTS=[['COND_BR','COND_MISPRED','TAGE_WRONG','LOOP_USED','LOOP_WRONG','CMT_REGION','TRAIN_STALL','UNUSED','cycles'],
 ['DEMAND_MISS','PF_ISSUED','PF_USEFUL','PF_LATE','PF_UNUSED','PF_THROTTLED','PF_XLATE_MISS','PF_CANDIDATE','cycles'],
 ['CMT_REGION','TRAIN_STALL','FTQ_FULL','RQ_FULL','DELIVER_LT4','BACKPRESSURE','RQ_WAIT_DATA','ZOMBIE','cycles']]
def num(n):return int(n,0) if isinstance(n,str) else n
def extract(path,off):
 samples=[[None]*9 for _ in range(6)];read=None;frozen=False;passed=False;retired=0
 for line in Path(path).read_text().splitlines():
  r=json.loads(line)
  if r['type']=='header':continue
  assert r['type']=='retire',r
  retired+=1;w=num(r['instruction'])
  if w&127==0x73:
   csr=w>>20;op=(w>>12)&7
   if csr==0x320 and op==1:frozen=(num(r['csr_wdata'])&0x7f8)==0x7f8
   if (0xb03<=csr<=0xb0a or csr==0xb00) and op==2 and ((w>>15)&31)==0:
    assert frozen
    read=(8 if csr==0xb00 else csr-0xb03,num(r['rd_wdata']))
  if r['mem_kind']=='store':
   addr,value=num(r['mem_addr']),num(r['mem_data'])
   if BASE<=addr<BASE+432:
    row,col=divmod((addr-BASE)//8,9)
    assert addr%8==0 and num(r['mem_size'])==8 and read==(col,value) and samples[row][col] is None
    samples[row][col]=value;read=None
   if addr==0x801ff000:assert value==1;passed=True
 assert passed and all(x is not None for row in samples for x in row)
 result=[dict(zip(EVENTS[i],((b-a)&((1<<64)-1) for a,b in zip(samples[2*i],samples[2*i+1])))) for i in range(3)]
 assert result[0]['COND_BR']>=12000 and result[0]['UNUSED']==0
 if off:
  assert result[0]['LOOP_USED']==result[0]['LOOP_WRONG']==0
  assert all(result[1][e]==0 for e in EVENTS[1] if e.startswith('PF_'))
 return {'segments':result,'retired':retired}
def main():
 p=argparse.ArgumentParser();p.add_argument('--on',required=True);p.add_argument('--off',required=True);p.add_argument('--output',required=True);a=p.parse_args()
 results={'on':extract(a.on,False),'off':extract(a.off,True)}
 x,y=results['on']['segments'],results['off']['segments']
 results['performance']={'loop_mispredict_reduced':x[0]['COND_MISPRED']<y[0]['COND_MISPRED'],
  'cold_misses_reduced':x[1]['DEMAND_MISS']<y[1]['DEMAND_MISS'],
  'cold_cycles_reduced':x[1]['cycles']<y[1]['cycles'], 'short_training_no_stall':x[2]['TRAIN_STALL']==0}
 Path(a.output).write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results))
if __name__=='__main__':main()
