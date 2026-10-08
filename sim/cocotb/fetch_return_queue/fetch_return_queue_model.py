"""Independent transaction/order model for L7c RQ, including pending zombies."""
from dataclasses import dataclass
@dataclass(frozen=True)
class Inputs:
 rst: bool=False
 reserve: bool=False
 reserve_id: int=0
 reserve_pc: int=0
 reserve_idx: int|None=None
 response: bool=False
 response_idx: int=0
 response_id: int=0
 response_data: int=0
 brief_done: bool=False
 brief_id: int=0
 deq_ready: bool=False
 kill: bool=False
 kill_all: bool=False
 kill_self: bool=False
 kill_id: int=0
 kill_slot: int=0
 head: int=0
@dataclass
class Entry:
 ftq_id: int
 pc: int
 data: int|None=None
 zombie: bool=False
class ReturnModel:
 def __init__(self,depth=32):self.depth=depth;self.slots=[None]*8;self.order=[]
 @property
 def entry(self):return self.slots[self.order[0]] if self.order else None
 @property
 def free(self):return next((s for s,e in enumerate(self.slots) if e is None),0)
 def visible(self,i):
  e=self.entry;ready=any(e is None for e in self.slots) and not i.rst and not i.kill
  brief=e is not None
  deq=brief and e.data is not None and not(i.rst or i.kill) and i.brief_done and i.brief_id==e.ftq_id
  return ready,brief,bool(deq),e
 def tick(self,i):
  if i.rst:self.slots=[None]*8;self.order=[];return
  ready,_,deq,_=self.visible(i)
  if i.reserve:
   s=self.free if i.reserve_idx is None else i.reserve_idx
   assert ready and self.slots[s] is None
   self.slots[s]=Entry(i.reserve_id,i.reserve_pc);self.order.append(s)
  if i.response:
   e=self.slots[i.response_idx];assert e is not None and e.data is None and e.ftq_id==i.response_id
   if e.zombie:self.slots[i.response_idx]=None
   else:e.data=i.response_data
  if i.kill:
   kept=[];suffix=False
   for s in self.order:
    e=self.slots[s];young=((e.ftq_id%self.depth-i.head%self.depth)%self.depth)>((i.kill_id%self.depth-i.head%self.depth)%self.depth)
    killed=i.kill_all or young or (i.kill_self and i.kill_slot==0 and e.ftq_id==i.kill_id)
    if killed:
     suffix=True
     if e.data is None:e.zombie=True
     else:self.slots[s]=None
    else:assert not suffix;kept.append(s)
   self.order=kept
  if deq and i.deq_ready:self.slots[self.order.pop(0)]=None
