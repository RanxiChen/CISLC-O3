#pragma once
// Fixed internal ABI: upstream Spike 609dbe0b9994154833039209fa37151e7c05e9d4.
#include <riscv/sim.h>
#include <riscv/processor.h>
#include <riscv/mmu.h>
#include <riscv/devices.h>
#include <deque>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <memory>

struct RetireRecord {
    uint64_t cycle=0, order=0, instruction_id=0, rob_idx=0, pc=0, instruction=0;
    unsigned slot=0, rd=0, mem_kind=0, mem_size=0;
    bool rd_write=false, csr_valid=false, exc_valid=false;
    unsigned csr_addr=0;
    uint64_t csr_wdata=0, exc_cause=0, exc_tval=0;
    uint64_t rd_wdata=0, mem_addr=0, mem_data=0;
};
inline uint64_t byte_mask(unsigned bytes) {
    return bytes == 8 ? UINT64_MAX : (uint64_t{1} << (8*bytes))-1;
}
inline std::string record_json(const RetireRecord& r) {
    std::ostringstream o;
    auto hex = [&](uint64_t n, int digits) {
        o << "\"0x" << std::hex << std::setw(digits) << std::setfill('0') << n
          << "\"" << std::dec;
    };
    o << "{\"type\":\"" << (r.exc_valid?"trap":"retire") << "\",\"v\":2,\"cycle\":" << r.cycle
      << ",\"order\":" << r.order << ",\"slot\":" << r.slot
      << ",\"instruction_id\":" << r.instruction_id << ",\"rob_idx\":" << r.rob_idx
      << ",\"pc\":"; hex(r.pc,10);
    o << ",\"instruction\":"; hex(r.instruction,8);
    o << ",\"rd\":" << r.rd << ",\"rd_write\":" << (r.rd_write?"true":"false")
      << ",\"rd_wdata\":"; hex(r.rd_wdata,16);
    o << ",\"mem_kind\":\"" << (r.mem_kind==1?"load":r.mem_kind==2?"store":"none")
      << "\",\"mem_addr\":"; hex(r.mem_addr,14);
    o << ",\"mem_size\":" << r.mem_size << ",\"mem_data\":"; hex(r.mem_data,16);
    o << ",\"fp_rd\":null,\"fp_wdata\":null,\"csr_addr\":";
    if(r.csr_valid) hex(r.csr_addr,3); else o << "null";
    o << ",\"csr_wdata\":"; if(r.csr_valid) hex(r.csr_wdata,16); else o << "null";
    o << ",\"exc_cause\":"; if(r.exc_valid) hex(r.exc_cause,16); else o << "null";
    o << ",\"exc_tval\":"; if(r.exc_valid) hex(r.exc_tval,16); else o << "null";
    o << "}";
    return o.str();
}
struct LockstepMismatch : std::runtime_error {
    using std::runtime_error::runtime_error;
};
class SpikeLockstep {
    cfg_t cfg_;
    std::unique_ptr<mem_t> ram_;
    std::unique_ptr<sim_t> sim_;
    processor_t* cpu_ = nullptr;
    std::deque<std::pair<RetireRecord,RetireRecord>> history_;
  public:
    SpikeLockstep(uint64_t base, uint64_t size, uint64_t pc) {
        cfg_.isa="rv64i_zicsr_zifencei_zicntr"; cfg_.priv="M"; cfg_.endianness=endianness_little;
        cfg_.pmpregions=0; cfg_.trigger_count=0; cfg_.hartids={0};
        cfg_.mem_layout={mem_cfg_t(base,size)}; cfg_.start_pc.set_global(pc);
        ram_=std::make_unique<mem_t>(size);
        sim_=std::make_unique<sim_t>(&cfg_,false,
            std::vector<std::pair<reg_t,abstract_mem_t*>>{{base,ram_.get()}},
            std::vector<device_factory_sargs_t>{},false,std::vector<std::string>{"none"},
            debug_module_config_t{},"/dev/null",false,nullptr,false,nullptr,std::nullopt);
        cpu_=sim_->get_core(0);
        cpu_->enable_log_commits();
        cpu_->get_state()->pc=pc;
        cpu_->set_pmp_num(0);
        cpu_->put_csr(0x305,0x200); // L5 platform reset mtvec, matches Breeze M-only reset.
    }
    void init(uint64_t offset, unsigned bytes, uint64_t value) {
        uint8_t b[8]; for(unsigned i=0;i<bytes;++i) b[i]=value>>(8*i);
        if (!ram_->store(offset,bytes,b)) throw std::runtime_error("Spike init out of range");
    }
    RetireRecord step(const RetireRecord& dut) {
        RetireRecord r;
        r.cycle=dut.cycle; r.order=dut.order; r.slot=dut.slot;
        auto* state=cpu_->get_state();
        r.pc=state->pc;
        bool fetch_trap=false;
        try { r.instruction=cpu_->get_mmu()->load_insn(r.pc).insn.bits(); }
        catch (const trap_t&) { fetch_trap=true; r.instruction=0; }
        uint64_t before=state->minstret->read();
        cpu_->step(1);
        // step(1) returns immediately after a synchronous trap in pinned Spike.
        // A counter write may change minstret itself, so never infer a trap from
        // its delta for that instruction. Trap state is compared, never resynced.
        bool counter_write=((r.instruction&0x7f)==0x73 && (r.instruction>>20)==0xb02
                            && ((r.instruction>>12)&3));
        if(fetch_trap || (!counter_write && state->minstret->read()==before)) {
            r.exc_valid=true; r.exc_cause=cpu_->get_csr(0x342); r.exc_tval=cpu_->get_csr(0x343);
            return r;
        }
        for(const auto& [key,value]:state->log_reg_write) {
            if ((key&15)==0 && (key>>4)!=0) {
                if(r.rd_write) throw std::runtime_error("multiple Spike integer writes");
                r.rd_write=true; r.rd=key>>4; r.rd_wdata=value.v[0];
            }
        }
        if((r.instruction&0x7f)==0x73 && ((r.instruction>>12)&3)) {
            unsigned f3=(r.instruction>>12)&7, rs1=(r.instruction>>15)&31;
            r.csr_addr=r.instruction>>20;
            bool writes=(f3&3)==1 || rs1!=0;
            // Match an actual CSR write event in Spike's commit log, including
            // WARL coercion. Other implicit CSR updates are not ordinary writes.
            if(writes) for(const auto& [key,value]:state->log_reg_write)
                if((key&15)==4 && (key>>4)==r.csr_addr) {r.csr_valid=true;r.csr_wdata=value.v[0];}
        }
        if(state->log_mem_read.size()+state->log_mem_write.size()>1)
            throw std::runtime_error("multiple Spike memory events");
        if(!state->log_mem_read.empty()) {
            r.mem_kind=1;
            auto [addr,value,bytes]=state->log_mem_read.at(0);
            r.mem_addr=addr; r.mem_size=bytes;
            uint8_t b[8]={};
            if (bytes>8 || !ram_->load(addr-cfg_.mem_layout[0].get_base(),bytes,b))
                throw std::runtime_error("Spike load outside RAM");
            for(unsigned i=0;i<bytes;++i) r.mem_data|=uint64_t(b[i])<<(i*8);
            if (((r.instruction>>12)&7)<4 && bytes<8
                && (r.mem_data&(uint64_t{1}<<(8*bytes-1)))) r.mem_data|=~byte_mask(bytes);
        } else if(!state->log_mem_write.empty()) {
            r.mem_kind=2;
            auto [addr,value,bytes]=state->log_mem_write.at(0);
            r.mem_addr=addr; r.mem_size=bytes; r.mem_data=value&byte_mask(bytes);
        }
        return r;
    }
    void compare(const RetireRecord& d, const RetireRecord& r) {
        std::string field;
        if(d.pc!=r.pc) field="pc";
        else if(d.instruction!=r.instruction) field="instruction";
        else if(d.rd_write!=r.rd_write) field="rd_write";
        else if(d.rd_write && d.rd!=r.rd) field="rd";
        else if(d.exc_valid!=r.exc_valid) field="exc_valid";
        else if(d.exc_valid && d.exc_cause!=r.exc_cause) field="exc_cause";
        else if(d.exc_valid && d.exc_tval!=r.exc_tval) field="exc_tval";
        else if(d.rd_write && d.rd_wdata!=r.rd_wdata
                && !(((d.instruction&0x7f)==0x73) && ((d.instruction>>12)&3)
                     && ((d.instruction>>20)==0xb00 || (d.instruction>>20)==0xc00))) field="rd_wdata";
        else if(d.csr_valid!=r.csr_valid) field="csr_valid";
        else if(d.csr_valid && d.csr_addr!=r.csr_addr) field="csr_addr";
        else if(d.csr_valid && d.csr_wdata!=r.csr_wdata) field="csr_wdata";
        else if(d.mem_kind!=r.mem_kind) field="mem_kind";
        else if(d.mem_kind && (d.mem_addr>>56 || r.mem_addr>>56 || d.mem_addr!=r.mem_addr)) field="mem_addr";
        else if(d.mem_kind && d.mem_size!=r.mem_size) field="mem_size";
        else if(d.mem_kind && !(d.mem_kind==1&&!r.rd_write) && d.mem_data!=r.mem_data) field="mem_data";
        if(!field.empty()) {
            std::cerr << "MISMATCH field=" << field << " cycle=" << d.cycle
                      << " retire_idx=" << d.order << " lane=" << d.slot << "\n"
                      << "DUT " << record_json(d) << "\nSPIKE " << record_json(r) << "\n";
            for(const auto& [hd,hr]:history_)
                std::cerr << "HISTORY DUT " << record_json(hd) << "\nHISTORY SPIKE " << record_json(hr) << "\n";
            throw LockstepMismatch(field);
        }
        history_.emplace_back(d,r);
        if(history_.size()>32) history_.pop_front();
    }
};
