"""Trace checker fault injection: reject broken samples and A/B bookkeeping."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from check_l7_predict import extract, compare_groups, SAMPLES

LAYOUT = {'segment1_begin':0x1000,'segment1_end':0x1010,
          'segment2_begin':0x2000,'segment2_end':0x2010,
          'segment3_begin':0x3000,'segment3_end':0x3010,
          'level1':0x4000,'final_checks':0x5000}


def record(pc=0, word=0x13, **kw):
    return dict(type='retire', pc=pc, instruction=word, mem_kind='none',
                mem_addr=0, mem_data=0, mem_size=8, csr_wdata=0, rd_wdata=0, **kw)


def trace(group):
    result=[record(0x1000,0x63) for _ in range(2001)]
    result += [record(0x2000,0x6f) for _ in range(2500)]
    if group=='A':
        d=[[3,1,2,2,10,1,0,0],[5,1,1,2,20,1,0,0],[2,5,0,1,10,1,0,0]]
    else:
        d=[[10,4,1,3,2,2,0,0],[20,8,2,6,4,2,0,0],[10,4,1,3,2,1,0,0]]
    rows=[];state=[0]*8
    for delta in d:
        rows.append(state[:]);state=[a+b for a,b in zip(state,delta)];rows.append(state[:])
    for row, values in enumerate(rows):
        r=record(word=0x32029073);r['csr_wdata']=0x7f8;result.append(r)
        for col, value in enumerate(values):
            r=record(word=((0xb03+col)<<20)|0x2373);r['rd_wdata']=value;result.append(r)
            r=record();r.update(mem_kind='store',mem_addr=SAMPLES+(row*8+col)*8,mem_data=value);result.append(r)
    if group=='A':
        for col in range(3):
            r=record();r.update(mem_kind='store',mem_addr=SAMPLES+384+col*8,mem_data=1);result.append(r)
    r=record();r.update(mem_kind='store',mem_addr=0x801ff000,mem_data=1);result.append(r)
    return result


class CheckTrace(unittest.TestCase):
    def run_trace(self, data, group='A'):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'trace.jsonl'
            p.write_text(''.join(json.dumps(r)+'\n' for r in data))
            return extract(p,group,LAYOUT)

    def test_valid_and_common_events(self):
        a=self.run_trace([dict(type='header',format='cislc-o3-tandem',version=2)]+trace('A'))
        b=self.run_trace(trace('B'),'B')
        compare_groups({'A':a,'B':b})

    def test_reject_common_event_mismatch(self):
        a=self.run_trace(trace('A'));b=self.run_trace(trace('B'),'B')
        for event in ('CMT_REGION','REDIRECT_EXEC'):
            mutant=copy.deepcopy(b);mutant['deltas'][0][event]+=1
            with self.assertRaises(AssertionError):compare_groups({'A':a,'B':mutant})

    def test_reject_faults(self):
        original=trace('A')
        sample=next(i for i,r in enumerate(original) if r['mem_kind']=='store' and r['mem_addr']==SAMPLES)
        faults=[]
        missing=copy.deepcopy(original);del missing[sample];faults.append(missing)
        duplicate=copy.deepcopy(original);duplicate.insert(sample,copy.deepcopy(duplicate[sample]));faults.append(duplicate)
        mismatch=copy.deepcopy(original);mismatch[sample]['mem_data']=999;faults.append(mismatch)
        unfrozen=copy.deepcopy(original)
        for r in unfrozen:
            if r['instruction']==0x32029073:r['csr_wdata']=0
        faults.append(unfrozen)
        wrong_marker=copy.deepcopy(original)
        next(r for r in wrong_marker if r['mem_addr']==SAMPLES+384)['mem_data']=0
        faults.append(wrong_marker)
        wrong_cfi=copy.deepcopy(original);del wrong_cfi[0];faults.append(wrong_cfi)
        trap=copy.deepcopy(original);trap[0]['type']='trap';faults.append(trap)
        for data in faults:
            with self.assertRaises(AssertionError):self.run_trace(data)

    def test_reject_wrong_classification(self):
        data=trace('B')
        target=SAMPLES+64
        index=next(i for i,r in enumerate(data) if r['mem_addr']==target)
        data[index]['mem_data']+=1;data[index-1]['rd_wdata']+=1
        with self.assertRaises(AssertionError):self.run_trace(data,'B')


if __name__=='__main__':unittest.main()
