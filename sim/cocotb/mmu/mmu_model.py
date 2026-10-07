"""Independent architectural Sv39 walker; no RTL timing or replacement model."""
MASK64=(1<<64)-1
A=64;D=128
class Fault(Exception):
    def __init__(self,kind): self.kind=kind

def translate(mem,va,root,priv=1,cmd='load',sum_=False,mxr=False,adue=False,read_fault=set()):
    va &= MASK64
    if (va>>39)!=( ((1<<25)-1) if (va>>38)&1 else 0): raise Fault('pf')
    base=root<<12;g=False
    for level in (2,1,0):
        addr=base+((va>>(12+level*9))&511)*8
        if addr in read_fault: raise Fault('af')
        p=mem.get(addr,0)
        if not p&1 or (p&4 and not p&2) or p>>54: raise Fault('pf')
        g |= bool(p&32)
        if p&10:
            ppn=p>>10
            if ppn&((1<<(level*9))-1): raise Fault('pf')
            allowed=bool(p&8) if cmd=='fetch' else bool(p&4) if cmd=='store' else bool(p&2 or (mxr and p&8))
            if not allowed or (priv==0 and not p&16) or (priv==1 and p&16 and (cmd=='fetch' or not sum_)): raise Fault('pf')
            if not adue and (not p&A or (cmd=='store' and not p&D)): raise Fault('pf')
            offbits=12+level*9
            return ((ppn<<12)&~((1<<offbits)-1))|(va&((1<<offbits)-1)),g
        if level==0: raise Fault('pf')
        base=(p>>10)<<12
    raise Fault('pf')
