"""Architectural program and expected writes, independent of pipeline scheduling."""
def program(width, groups):
    regs=[0]*32;rows=[];base=0x80000000
    for group in range(groups):
        for lane in range(width):
            pc=base+4*len(rows)
            if lane==group%width:
                # JAL +4 has a link write but the fall-through prediction is correct.
                rd=5 if group%2 else 0
                inst=0x004002ef if rd else 0x00001463 # BNE x0,x0,+8: not taken.
                value=pc+4 if rd else 0
            else:
                rd=8+(lane%4);rs=8+((lane-1)%4) if group%3 else 0
                imm=group%31+1;inst=(imm<<20)|(rs<<15)|(rd<<7)|0x13
                value=(regs[rs]+imm)&((1<<64)-1)
            if rd:regs[rd]=value
            rows.append((pc,inst,rd,bool(rd),value))
    return rows
