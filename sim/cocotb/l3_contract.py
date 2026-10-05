"""Shared port codec/timing only; each test owns its independent contract model."""
import cocotb
from cocotb.handle import ArrayObject
from cocotb.triggers import Timer

def clear(d, names):
    for name in names:
        port=getattr(d,name)
        if isinstance(port,ArrayObject):
            for element in port:element.value=0
        else:port.value=0

async def settle():
    await Timer(2,unit='ns')

async def tick(d):
    d.clk.value=0
    await settle()
    d.clk.value=1
    await settle()
    d.clk.value=0
    await settle()

async def reset(d,names):
    clear(d,names);d.rst.value=1
    await tick(d);await tick(d)
    d.rst.value=0
    await settle()

def val(x):return int(x.value)

def array(port, values):
    for n,v in enumerate(values):port[n].value=v

def codec(d,typ,**fields):
    result=0
    for f,v in fields.items():
        mask=val(getattr(d,'fmt_'+typ+'_'+f.replace('.','_')))
        shift=(mask & -mask).bit_length()-1
        assert v>=0 and (v<<shift)&~mask==0,(typ,f,v,mask)
        result|=v<<shift
    return result

def field(d,typ,raw,f):
    mask=val(getattr(d,'fmt_'+typ+'_'+f.replace('.','_')))
    shift=(mask & -mask).bit_length()-1
    return (raw&mask)>>shift

def bundle(port, values):
    width=len(port)//len(values)
    port.value=sum(v<<(n*width) for n,v in enumerate(values))

def unbundle(port,count):
    width=len(port)//count;raw=val(port)
    return [(raw>>(n*width))&((1<<width)-1) for n in range(count)]
