//
//  GuestCPUTests.cpp
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//
// Standalone CPU regression checks, independent of the Apple application host.
// Build example (place the result in a task-owned temporary directory):
// clang++ -std=c++17 -Wall -Wextra -Werror Sources/Legacy/GuestCPU.cpp \
//     Tests/GuestCPUTests.cpp -o /private/tmp/<task-directory>/GuestCPUTests

#include "../Sources/Legacy/GuestCPU.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {
unsigned checks = 0;
void require(bool success, const std::string& message) {
    ++checks;
    if (!success) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

void equal(uint32_t actual, uint32_t expected, const std::string& message) {
    require(actual == expected, message + " (actual " + std::to_string(actual) +
            ", expected " + std::to_string(expected) + ")");
}

void healthy(const GuestCPU& cpu, const std::string& message) {
    require(cpu.fault.empty(), message + ": " + cpu.fault);
}

void thumb(GuestCPU& cpu, uint32_t address, std::initializer_list<uint16_t> words) {
    for (uint16_t word : words) { cpu.write16(address, word); address += 2; }
}

void arm(GuestCPU& cpu, uint32_t address, std::initializer_list<uint32_t> words) {
    for (uint32_t word : words) { cpu.write32(address, word); address += 4; }
}

void oneThumb(GuestCPU& cpu, uint16_t opcode) {
    cpu.fault.clear(); cpu.thumb = true; cpu.r[15] = 0x100;
    cpu.write16(0x100, opcode);
    require(cpu.step(), "Thumb step executes " + std::to_string(opcode) + ": " + cpu.fault);
}

void oneARM(GuestCPU& cpu, uint32_t opcode) {
    cpu.fault.clear(); cpu.thumb = false; cpu.r[15] = 0x100;
    cpu.write32(0x100, opcode);
    require(cpu.step(), "ARM step executes " + std::to_string(opcode) + ": " + cpu.fault);
}

void memoryTests() {
    GuestCPU cpu;
    equal(uint32_t(cpu.memory.size()), GuestCPU::MemorySize, "fixed initial memory size");
    cpu.write32(0x201, 0x89abcdefu);
    equal(cpu.read8(0x201), 0xef, "little endian byte");
    equal(cpu.read16(0x202), 0xabcd, "little endian unaligned halfword");
    equal(cpu.read32(0x201), 0x89abcdefu, "unaligned read API");
    cpu.write16(GuestCPU::MemorySize - 2, 0x1234);
    equal(cpu.read16(GuestCPU::MemorySize - 2), 0x1234, "last valid halfword");
    const uint8_t guard = cpu.memory.back();
    cpu.write32(GuestCPU::MemorySize - 1, 0xffffffffu);
    require(!cpu.fault.empty(), "out-of-bounds write faults");
    equal(cpu.memory.back(), guard, "out-of-bounds write is atomic");
    cpu.fault.clear();
    equal(cpu.read32(0xfffffffdu), 0, "wrapping memory access returns zero");
    require(!cpu.fault.empty(), "wrapping address faults");
    cpu.fault.clear();
    require(!cpu.load(0x100, nullptr, 1), "null source fails safely");
}

void boundedMemoryTests() {
    GuestCPU cpu;
    cpu.memory.assign(3, 0x5a);
    equal(cpu.read32(0), 0, "word access rejects a memory span smaller than one word");
    require(!cpu.fault.empty(), "small memory word read faults without size underflow");
    cpu.fault.clear();
    const auto original = cpu.memory;
    cpu.write32(0, 0xffffffffu);
    require(!cpu.fault.empty() && cpu.memory == original, "small memory word write remains atomic");
    cpu.fault.clear();
    cpu.write16(2, 0xffff);
    require(!cpu.fault.empty() && cpu.memory == original, "last-byte halfword write remains atomic");
    cpu.fault.clear();
    cpu.write16(1, 0x1234);
    equal(cpu.read16(1), 0x1234, "unaligned halfword can end at exact memory boundary");
    cpu.write8(2, 0xab);
    equal(cpu.read8(2), 0xab, "last-byte access remains valid");
    healthy(cpu, "valid accesses after preceding faults");
    cpu.memory.clear();
    require(cpu.load(0, nullptr, 0), "empty load into empty memory remains valid");
    equal(cpu.read8(0), 0, "empty memory byte read returns zero");
    require(!cpu.fault.empty(), "empty memory byte read faults");
}

void registerTransferBoundaryTests() {
    GuestCPU cpu;
    cpu.memory.resize(0x1000);
    cpu.r[13] = 0x1000; cpu.r[0] = 0x12345678; cpu.r[1] = 0x89abcdef;
    oneThumb(cpu, 0xb403); // PUSH {r0,r1}
    equal(cpu.r[13], 0xff8, "PUSH whole span can end at exact memory boundary");
    equal(cpu.read32(0xffc), 0x89abcdef, "PUSH writes last valid word");
    cpu.r[0] = cpu.r[1] = 0;
    oneThumb(cpu, 0xbc03); // POP {r0,r1}
    equal(cpu.r[0], 0x12345678, "boundary POP restores first register");
    equal(cpu.r[1], 0x89abcdef, "boundary POP restores last register");
    equal(cpu.r[13], 0x1000, "boundary POP balances stack");

    auto reject = [&](uint32_t opcode, bool isThumb, const char *message) {
        cpu.fault.clear(); cpu.thumb = isThumb; cpu.r[15] = 0x100;
        if (isThumb) cpu.write16(0x100, uint16_t(opcode)); else cpu.write32(0x100, opcode);
        const auto memory = cpu.memory;
        const auto registers = cpu.r;
        require(!cpu.step() && !cpu.fault.empty(), message);
        require(cpu.memory == memory, "invalid whole register-transfer span changes no memory");
        for (unsigned reg = 0; reg < 15; ++reg)
            equal(cpu.r[reg], registers[reg], "invalid whole span changes no data or base register");
    };
    cpu.r[2] = 0xffc;
    reject(0xc203, true, "Thumb STM rejects partially accessible whole span");
    reject(0xca03, true, "Thumb LDM rejects partially accessible whole span");
    cpu.r[13] = 0xffc;
    reject(0xbc03, true, "Thumb POP rejects partially accessible whole span");
    reject(0xe8bd0003, false, "ARM LDM rejects partially accessible whole span");
    cpu.r[3] = 0xffc;
    reject(0xe1c300f0, false, "ARM STRD rejects partially accessible doubleword");
    reject(0xe1c300d0, false, "ARM LDRD rejects partially accessible doubleword");

    cpu.r[13] = 0xff8;
    oneARM(cpu, 0xe8bd0003); // LDMIA sp!,{r0,r1}
    equal(cpu.r[0], 0x12345678, "boundary ARM LDM restores first word");
    equal(cpu.r[1], 0x89abcdef, "boundary ARM LDM restores last word");
    equal(cpu.r[13], 0x1000, "boundary ARM LDM writeback reaches memory end");
    healthy(cpu, "bounded register transfers preserve original behavior");
}

void thumbArithmeticTests() {
    GuestCPU cpu;
    cpu.v = true; cpu.c = true;
    oneThumb(cpu, 0x2000); // MOVS r0,#0
    equal(cpu.r[0], 0, "MOV immediate");
    require(cpu.z && !cpu.n && cpu.c && cpu.v, "MOVS preserves C/V");
    cpu.r[0] = 0x7fffffffu;
    oneThumb(cpu, 0x3001); // ADDS r0,#1
    equal(cpu.r[0], 0x80000000u, "signed add wraps");
    require(cpu.n && cpu.v && !cpu.c && !cpu.z, "signed add flags");
    cpu.r[0] = 0xffffffffu;
    oneThumb(cpu, 0x3001);
    require(cpu.z && cpu.c && !cpu.v, "unsigned add flags");
    oneThumb(cpu, 0x3801); // SUBS r0,#1
    equal(cpu.r[0], 0xffffffffu, "subtract wraps");
    require(cpu.n && !cpu.c && !cpu.v, "borrow is inverse carry");
    cpu.r[0] = 0x80000000u;
    oneThumb(cpu, 0x3801);
    equal(cpu.r[0], 0x7fffffffu, "signed subtraction wraps");
    require(!cpu.n && cpu.v && cpu.c, "subtraction overflow");
    cpu.r[0] = 0; cpu.r[1] = 0xffffffffu; cpu.c = true;
    oneThumb(cpu, 0x4148); // ADCS r0,r1
    equal(cpu.r[0], 0, "ADC includes carry");
    require(cpu.z && cpu.c && !cpu.v, "ADC flags");
    cpu.r[0] = 5; cpu.r[1] = 3; cpu.c = false;
    oneThumb(cpu, 0x4188); // SBCS r0,r1
    equal(cpu.r[0], 1, "SBC includes borrow");
    require(cpu.c && !cpu.v, "SBC flags");
    cpu.r[0] = 0x80000000u; cpu.r[1] = 1;
    oneThumb(cpu, 0x4248); // RSBS r0,r1,#0
    equal(cpu.r[0], 0xffffffffu, "NEG source");
    require(cpu.n && !cpu.c && !cpu.v, "NEG flags");
    cpu.r[0] = 7; cpu.r[1] = 7;
    oneThumb(cpu, 0x4288); // CMP r0,r1
    equal(cpu.r[0], 7, "CMP does not overwrite operand");
    require(cpu.z && cpu.c, "CMP equality");
    cpu.r[0] = 3; cpu.r[1] = 0xfffffffeu; cpu.c = true; cpu.v = true;
    oneThumb(cpu, 0x4348); // MULS r0,r1
    equal(cpu.r[0], 0xfffffffau, "MUL low 32 bits");
    require(cpu.n && !cpu.z && cpu.c && cpu.v, "MULS preserves C/V");
    cpu.r[0] = 8; cpu.r[1] = 6;
    oneThumb(cpu, 0x1842); // ADDS r2,r0,r1
    equal(cpu.r[2], 14, "three-register ADD");
    oneThumb(cpu, 0x1ed3); // SUBS r3,r2,#3
    equal(cpu.r[3], 11, "three-operand immediate SUB");
}

void thumbShiftTests() {
    GuestCPU cpu;
    cpu.r[1] = 0x80000001u; cpu.c = true;
    oneThumb(cpu, 0x0008); // LSLS r0,r1,#0
    equal(cpu.r[0], 0x80000001u, "LSL zero"); require(cpu.c, "LSL zero preserves carry");
    oneThumb(cpu, 0x0808); // LSRS r0,r1,#32
    equal(cpu.r[0], 0, "LSR immediate zero encodes 32"); require(cpu.c, "LSR 32 carry");
    oneThumb(cpu, 0x1008); // ASRS r0,r1,#32
    equal(cpu.r[0], 0xffffffffu, "ASR 32 sign fills"); require(cpu.c, "ASR 32 carry");
    cpu.r[0] = 1; cpu.r[1] = 32;
    oneThumb(cpu, 0x4088); // LSLS r0,r1
    equal(cpu.r[0], 0, "register LSL 32"); require(cpu.c, "register LSL32 carry bit0");
    cpu.r[0] = 0xffffffffu; cpu.r[1] = 33;
    oneThumb(cpu, 0x4088);
    require(cpu.z && !cpu.c, "register LSL beyond32");
    cpu.r[0] = 0x80000001u; cpu.r[1] = 32;
    oneThumb(cpu, 0x40c8); // LSRS r0,r1
    equal(cpu.r[0], 0, "register LSR32"); require(cpu.c, "register LSR32 carry bit31");
    cpu.r[0] = 0x80000001u; cpu.r[1] = 255;
    oneThumb(cpu, 0x4108); // ASRS r0,r1
    equal(cpu.r[0], 0xffffffffu, "register ASR255");
    cpu.r[0] = 0x12345678; cpu.r[1] = 32;
    oneThumb(cpu, 0x41c8); // RORS r0,r1
    equal(cpu.r[0], 0x12345678, "ROR32 preserves value"); require(!cpu.c, "ROR32 carry from bit31");
    cpu.r[0] = 0x80000001u; cpu.r[1] = 0; cpu.c = false;
    oneThumb(cpu, 0x41c8);
    require(!cpu.c && cpu.n, "register ROR0 preserves carry");
    cpu.r[1] = 0x101; cpu.r[0] = 1;
    oneThumb(cpu, 0x4088);
    equal(cpu.r[0], 2, "register shift uses bottom byte");
}

void thumbMemoryTests() {
    GuestCPU cpu;
    cpu.r[1] = 0x400; cpu.r[2] = 2; cpu.r[0] = 0x80ff;
    oneThumb(cpu, 0x5288); // STRH r0,[r1,r2]
    equal(cpu.read16(0x402), 0x80ff, "register STRH");
    oneThumb(cpu, 0x5e88); // LDRSH r0,[r1,r2]
    equal(cpu.r[0], 0xffff80ffu, "register LDRSH sign extends");
    oneThumb(cpu, 0x5688); // LDRSB r0,[r1,r2]
    equal(cpu.r[0], 0xffffffffu, "register LDRSB sign extends");
    cpu.r[0] = 0x12345678;
    oneThumb(cpu, 0x60c8); // STR r0,[r1,#12]
    equal(cpu.read32(0x40c), 0x12345678, "word immediate store scales offset");
    cpu.r[0] = 0;
    oneThumb(cpu, 0x68c8); // LDR r0,[r1,#12]
    equal(cpu.r[0], 0x12345678, "word immediate load");
    cpu.write32(0x108, 0xabcd1234);
    oneThumb(cpu, 0x4801); // LDR r0,[pc,#4]
    equal(cpu.r[0], 0xabcd1234, "literal PC uses aligned PC+4");
    cpu.r[13] = 0x800; cpu.write32(0x808, 77);
    oneThumb(cpu, 0x9802); // LDR r0,[sp,#8]
    equal(cpu.r[0], 77, "SP-relative load");
    oneThumb(cpu, 0xa003); // ADR r0,#12
    equal(cpu.r[0], 0x110, "ADR PC-relative");
    oneThumb(cpu, 0xa801); // ADD r0,sp,#4
    equal(cpu.r[0], 0x804, "SP-relative address");
    oneThumb(cpu, 0xb083); // SUB sp,#12
    equal(cpu.r[13], 0x7f4, "SP adjustment");
    cpu.r[0] = 11; cpu.r[1] = 22; cpu.r[2] = 0x500;
    oneThumb(cpu, 0xc203); // STM r2!,{r0,r1}
    equal(cpu.read32(0x500), 11, "Thumb STM first word");
    equal(cpu.read32(0x504), 22, "Thumb STM second word");
    equal(cpu.r[2], 0x508, "Thumb STM writeback");
    cpu.r[2] = 0x500; cpu.r[0] = 0; cpu.r[1] = 0;
    oneThumb(cpu, 0xca03); // LDM r2!,{r0,r1}
    equal(cpu.r[0], 11, "Thumb LDM first word");
    equal(cpu.r[1], 22, "Thumb LDM second word");
    equal(cpu.r[2], 0x508, "Thumb LDM writeback");
    cpu.r[0] = 0x500;
    oneThumb(cpu, 0xc803); // LDM r0!,{r0,r1}: loaded base wins
    equal(cpu.r[0], 11, "Thumb LDM base in list suppresses writeback");
}

void thumbExtensionTests() {
    GuestCPU cpu;
    cpu.r[1] = 0x123480fe;
    oneThumb(cpu, 0xb208); // SXTH r0,r1
    equal(cpu.r[0], 0xffff80feu, "SXTH");
    oneThumb(cpu, 0xb248); // SXTB
    equal(cpu.r[0], 0xfffffffeu, "SXTB");
    oneThumb(cpu, 0xb288); // UXTH
    equal(cpu.r[0], 0x80fe, "UXTH");
    oneThumb(cpu, 0xb2c8); // UXTB
    equal(cpu.r[0], 0xfe, "UXTB");
    oneThumb(cpu, 0xba08); // REV
    equal(cpu.r[0], 0xfe803412, "REV");
    oneThumb(cpu, 0xba48); // REV16
    equal(cpu.r[0], 0x3412fe80, "REV16");
    oneThumb(cpu, 0xbac8); // REVSH
    equal(cpu.r[0], 0xfffffe80u, "REVSH");
}

void thumbControlFlowTests() {
    GuestCPU cpu;
    // Sum 1+2+3+4+5 with a backward conditional branch.
    thumb(cpu, 0x100, {0x2000, 0x2105, 0x1840, 0x3901, 0xd1fc, 0x4770});
    equal(cpu.call(0x101), 15, "Thumb backward conditional branch loop");
    healthy(cpu, "Thumb loop returns");
    cpu.r[4] = 0x12345678;
    thumb(cpu, 0x100, {0xb510, 0x4604, 0x3005, 0xbd10});
    equal(cpu.call(0x101, {7}), 12, "Thumb PUSH/POP returns through PC");
    equal(cpu.r[4], 0x12345678, "callee-saved register restored by guest");
    equal(cpu.r[13], GuestCPU::StackTop, "stack balanced after call");
    thumb(cpu, 0x100, {0xb500, 0xf000, 0xf80d, 0x3002, 0xbd00});
    thumb(cpu, 0x120, {0x3003, 0x4770});
    equal(cpu.call(0x101, {7}), 12, "Thumb paired BL and link return");
    healthy(cpu, "Thumb BL returns");
    // Backward paired BL sign-extends the high half of its offset.
    thumb(cpu, 0x140, {0xb500, 0xf7ff, 0xffed, 0xbd00});
    equal(cpu.call(0x141, {7}), 10, "Thumb negative BL offset");
    healthy(cpu, "Thumb negative BL returns");
    thumb(cpu, 0x100, {0xb500, 0x4798, 0x3001, 0xbd00}); // BLX r3
    arm(cpu, 0x200, {0xe2800004, 0xe12fff1e}); // ADD r0,#4; BX lr
    equal(cpu.call(0x101, {5, 0, 0, 0x200}), 10, "Thumb BLX register ARM interworking");
    healthy(cpu, "register interworking returns");
    thumb(cpu, 0x100, {0xb500, 0xf000, 0xe87e, 0x3001, 0xbd00});
    equal(cpu.call(0x101, {5}), 10, "Thumb paired BLX aligns target to word");
    healthy(cpu, "paired BLX returns");
    cpu.r[0] = 42; cpu.r[8] = 0;
    oneThumb(cpu, 0x4680); // MOV r8,r0
    equal(cpu.r[8], 42, "high-register MOV");
    cpu.r[0] = 0x220;
    oneThumb(cpu, 0x4687); // MOV pc,r0
    equal(cpu.r[15], 0x220, "high-register MOV PC");
    require(cpu.thumb, "MOV PC preserves Thumb state");
}

void armArithmeticTests() {
    GuestCPU cpu;
    cpu.r[0] = 0x7fffffffu;
    oneARM(cpu, 0xe2900001); // ADDS r0,r0,#1
    equal(cpu.r[0], 0x80000000u, "ARM signed ADD wrap");
    require(cpu.v && cpu.n && !cpu.c, "ARM ADD flags");
    cpu.r[0] = 0; cpu.r[1] = 0; cpu.c = false;
    oneARM(cpu, 0xe0d00001); // SBCS r0,r0,r1
    equal(cpu.r[0], 0xffffffffu, "ARM SBC borrow");
    require(!cpu.c && cpu.n && !cpu.v, "ARM SBC flags");
    cpu.r[0] = 8; cpu.r[1] = 3;
    oneARM(cpu, 0xe0710000); // RSBS r0,r1,r0
    equal(cpu.r[0], 5, "ARM reverse subtraction");
    cpu.c = false; cpu.v = true;
    oneARM(cpu, 0xe3b00102); // MOVS r0,#0x80000000 (imm2 ROR2)
    equal(cpu.r[0], 0x80000000u, "rotated immediate");
    require(cpu.c && cpu.v && cpu.n, "rotated immediate carry, preserved V");
    cpu.r[1] = 2; cpu.c = true;
    oneARM(cpu, 0xe1b00061); // MOVS r0,r1,RRX
    equal(cpu.r[0], 0x80000001u, "RRX includes old carry");
    require(!cpu.c, "RRX carry from bit0");
    cpu.r[1] = 0x12345678; cpu.r[2] = 32;
    oneARM(cpu, 0xe1b00271); // MOVS r0,r1,ROR r2
    equal(cpu.r[0], 0x12345678, "ARM register ROR32");
    cpu.r[1] = 1; cpu.r[2] = 32;
    oneARM(cpu, 0xe1b00211); // MOVS r0,r1,LSL r2
    equal(cpu.r[0], 0, "ARM register LSL32"); require(cpu.c, "ARM LSL32 carry");
    oneARM(cpu, 0xe1a0000f); // MOV r0,pc
    equal(cpu.r[0], 0x108, "ARM PC reads current+8");
    cpu.r[1] = 0;
    oneARM(cpu, 0xe1a0011f); // MOV r0,pc,LSL r1
    equal(cpu.r[0], 0x10c, "ARM register-shifted PC observes extra stage");
    cpu.r[0] = 9; cpu.z = false;
    oneARM(cpu, 0x02800001); // ADDEQ r0,r0,#1
    equal(cpu.r[0], 9, "failed condition skips arithmetic");
    cpu.z = true;
    oneARM(cpu, 0x02800001);
    equal(cpu.r[0], 10, "passed condition executes arithmetic");
    cpu.r[1] = 0;
    oneARM(cpu, 0xe16f0f11); // CLZ r0,r1
    equal(cpu.r[0], 32, "CLZ zero");
    cpu.r[1] = 0x00100000;
    oneARM(cpu, 0xe16f0f11);
    equal(cpu.r[0], 11, "CLZ nonzero");
}

void armMultiplyTests() {
    GuestCPU cpu;
    cpu.r[1] = 0xffffffffu; cpu.r[2] = 3;
    oneARM(cpu, 0xe0100291); // MULS r0,r1,r2
    equal(cpu.r[0], 0xfffffffdu, "ARM MUL wraps"); require(cpu.n, "ARM MULS sign");
    cpu.r[3] = 5;
    oneARM(cpu, 0xe0203291); // MLA r0,r1,r2,r3
    equal(cpu.r[0], 2, "ARM multiply accumulate wraps");
    cpu.r[2] = 0xffffffffu; cpu.r[3] = 0xffffffffu;
    oneARM(cpu, 0xe0910392); // UMULLS r0,r1,r2,r3
    equal(cpu.r[0], 1, "UMULL low"); equal(cpu.r[1], 0xfffffffeu, "UMULL high");
    require(cpu.n && !cpu.z, "UMULLS 64-bit flags");
    cpu.r[2] = 0x80000000u; cpu.r[3] = 0xffffffffu;
    oneARM(cpu, 0xe0d10392); // SMULLS r0,r1,r2,r3
    equal(cpu.r[0], 0x80000000u, "SMULL low"); equal(cpu.r[1], 0, "SMULL signed high");
    require(!cpu.n && !cpu.z, "SMULLS sign from bit63");
    cpu.r[0] = 0xffffffffu; cpu.r[1] = 0xffffffffu; cpu.r[2] = 1; cpu.r[3] = 1;
    oneARM(cpu, 0xe0b10392); // UMLALS r0,r1,r2,r3
    equal(cpu.r[0], 0, "UMLAL low wraps"); equal(cpu.r[1], 0, "UMLAL high wraps");
    require(cpu.z && !cpu.n, "UMLALS full64 zero");
}

void armMemoryTests() {
    GuestCPU cpu;
    cpu.r[1] = 0x400; cpu.r[0] = 0x11223344;
    oneARM(cpu, 0xe5210004); // STR r0,[r1,#-4]!
    equal(cpu.r[1], 0x3fc, "ARM predecrement writeback");
    equal(cpu.read32(0x3fc), 0x11223344, "ARM predecrement store");
    oneARM(cpu, 0xe4912004); // LDR r2,[r1],#4
    equal(cpu.r[2], 0x11223344, "ARM postincrement load"); equal(cpu.r[1], 0x400, "ARM postincrement writeback");
    cpu.r[2] = 3; cpu.write32(0x418, 91);
    oneARM(cpu, 0xe7910182); // LDR r0,[r1,r2,LSL#3]
    equal(cpu.r[0], 91, "ARM scaled register address");
    oneARM(cpu, 0xe581f000); // STR pc,[r1]
    equal(cpu.read32(0x400), 0x10c, "ARM stored PC is current+12");
    cpu.r[0] = 0xff80;
    oneARM(cpu, 0xe1c100b2); // STRH r0,[r1,#2]
    oneARM(cpu, 0xe1d120f2); // LDRSH r2,[r1,#2]
    equal(cpu.r[2], 0xffffff80u, "ARM signed halfword load");
    oneARM(cpu, 0xe1d120d2); // LDRSB r2,[r1,#2]
    equal(cpu.r[2], 0xffffff80u, "ARM signed byte load");
    cpu.r[0] = 10; cpu.r[1] = 20; cpu.r[2] = 30; cpu.r[13] = 0x800;
    oneARM(cpu, 0xe92d0007); // STMDB sp!,{r0,r1,r2}
    equal(cpu.r[13], 0x7f4, "ARM STMDB SP");
    equal(cpu.read32(0x7f4), 10, "ARM block lowest reg lowest address");
    equal(cpu.read32(0x7fc), 30, "ARM block highest reg highest address");
    cpu.r[0] = 0; cpu.r[1] = 0; cpu.r[2] = 0;
    oneARM(cpu, 0xe8bd0007); // LDMIA sp!,{r0,r1,r2}
    equal(cpu.r[0], 10, "ARM LDM first"); equal(cpu.r[2], 30, "ARM LDM last");
    equal(cpu.r[13], 0x800, "ARM LDM balances SP");
    cpu.r[3] = 0x500; cpu.r[0] = 0xabc; cpu.r[1] = 0xdef;
    oneARM(cpu, 0xe1c300f0); // STRD r0,r1,[r3]
    equal(cpu.read32(0x500), 0xabc, "STRD low word"); equal(cpu.read32(0x504), 0xdef, "STRD high word");
    cpu.r[0] = 0; cpu.r[1] = 0;
    oneARM(cpu, 0xe1c300d0); // LDRD r0,r1,[r3]
    equal(cpu.r[0], 0xabc, "LDRD low word"); equal(cpu.r[1], 0xdef, "LDRD high word");
}

void armControlFlowTests() {
    GuestCPU cpu;
    arm(cpu, 0x100, {0xe92d4000, 0xeb000005, 0xe2800002, 0xe8bd8000});
    arm(cpu, 0x120, {0xe2800003, 0xe12fff1e});
    equal(cpu.call(0x100, {7}), 12, "ARM BL, BX, and LDM PC");
    healthy(cpu, "ARM call returns");
    arm(cpu, 0x100, {0xe92d4000, 0xfa00003d, 0xe2800002, 0xe8bd8000});
    thumb(cpu, 0x200, {0x3003, 0x4770});
    equal(cpu.call(0x100, {7}), 12, "ARM BLX immediate enters Thumb");
    healthy(cpu, "ARM to Thumb interworking returns");
    cpu.r[0] = 0x201;
    oneARM(cpu, 0xe12fff10); // BX r0
    require(cpu.thumb, "ARM BX selects Thumb from bit0"); equal(cpu.r[15], 0x200, "ARM BX clears state bit");
    cpu.r[1] = 0x400; cpu.write32(0x400, 0x201);
    oneARM(cpu, 0xe591f000); // LDR pc,[r1]
    require(cpu.thumb, "ARMv5 LDR PC interworks"); equal(cpu.r[15], 0x200, "LDR PC target");
    cpu.n = true; cpu.z = false; cpu.c = true; cpu.v = false;
    oneARM(cpu, 0xe10f0000); // MRS r0,CPSR
    equal(cpu.r[0], 0xa0000010, "MRS user CPSR flags");
    cpu.r[1] = 0x50000000;
    oneARM(cpu, 0xe128f001); // MSR CPSR_f,r1
    require(!cpu.n && cpu.z && !cpu.c && cpu.v, "MSR flag-only write");
}

void originalSwitchHelperTests() {
    GuestCPU cpu;
    // Exact ARM instructions from the hash-guarded psh executable, including
    // its Darwin Thumb inline-table ABI. These execute rather than being hooked.
    arm(cpu, 0xee64, {0xe55ec001, 0xe150000c, 0x37de0000,
                     0x27de000c, 0xe08ec080, 0xe12fff1c});
    thumb(cpu, 0x100, {0xb500, 0xf00e, 0xeeb0}); // PUSH lr; BLX switchu8
    // lr = 0x107: count byte at lr-1, three byte-sized halfword offsets.
    cpu.write8(0x106, 2);
    cpu.write8(0x107, 3); cpu.write8(0x108, 5); cpu.write8(0x109, 7);
    thumb(cpu, 0x10c, {0x200a, 0xbd00});
    thumb(cpu, 0x110, {0x2014, 0xbd00});
    thumb(cpu, 0x114, {0x201e, 0xbd00});
    equal(cpu.call(0x101, {0}), 10, "original switchu8 first case");
    healthy(cpu, "switchu8 first case returns to host");
    equal(cpu.call(0x101, {1}), 20, "original switchu8 last case");
    healthy(cpu, "switchu8 last case returns to host");
    equal(cpu.call(0x101, {2}), 30, "original switchu8 equal-count default");
    equal(cpu.call(0x101, {0xffffffffu}), 30, "original switchu8 unsigned large-index default");
    healthy(cpu, "switchu8 defaults return to host");

    arm(cpu, 0xee7c, {0xe51ec001, 0xe150000c, 0xe08e0100, 0x35900003,
                     0xe08ec10c, 0x259c0003, 0xe08ec000, 0xe12fff1c});
    thumb(cpu, 0xfe, {0xb500, 0xf00e, 0xeebc}); // PUSH lr; BLX switch32
    // lr = 0x105: count is at lr-1; table words start at lr+3. Entries
    // are byte offsets added directly to the odd Thumb return address.
    cpu.write32(0x104, 2);
    cpu.write32(0x108, 0x10); cpu.write32(0x10c, 0x14); cpu.write32(0x110, 0x18);
    thumb(cpu, 0x114, {0x200b, 0xbd00});
    thumb(cpu, 0x118, {0x2016, 0xbd00});
    thumb(cpu, 0x11c, {0x2021, 0xbd00});
    equal(cpu.call(0xff, {0}), 11, "original switch32 first case");
    healthy(cpu, "switch32 first case returns to host");
    equal(cpu.call(0xff, {1}), 22, "original switch32 last case");
    equal(cpu.call(0xff, {2}), 33, "original switch32 equal-count default");
    equal(cpu.call(0xff, {0xffffffffu}), 33, "original switch32 unsigned large-index default");
    healthy(cpu, "switch32 defaults return to host");
}

void callAndFaultTests() {
    GuestCPU cpu;
    thumb(cpu, 0x100, {0x9800, 0x9901, 0x1840, 0x4770}); // sum fifth+sixth args
    equal(cpu.call(0x101, {1, 2, 3, 4, 20, 30}), 50, "stack call arguments");
    equal(cpu.r[13], GuestCPU::StackTop, "call restores argument stack");
    uint32_t entrySP = 0;
    cpu.hook = [&](GuestCPU& guest, uint32_t address) {
        if (address != 0x400) return false;
        entrySP = guest.r[13];
        guest.r[0] += 10;
        guest.returnFromHook();
        return true;
    };
    equal(cpu.call(0x400, {5, 0, 0, 0, 8}), 15, "hook import returns result");
    require((entrySP & 7u) == 0, "call stack aligned8 with odd extra argument count");
    cpu.hook = [&](GuestCPU& guest, uint32_t address) {
        if (address != 0x400) return false;
        const uint32_t enclosingPC = guest.r[15];
        const uint32_t enclosingLR = guest.r[14];
        const uint32_t enclosingR4 = guest.r[4];
        const bool enclosingCarry = guest.c;
        guest.r[0] = guest.call(0x501, {7});
        equal(guest.r[15], enclosingPC, "nested call restores PC");
        equal(guest.r[14], enclosingLR, "nested call restores LR");
        equal(guest.r[4], enclosingR4, "nested call restores register context");
        require(guest.c == enclosingCarry, "nested call restores flags");
        guest.returnFromHook();
        return true;
    };
    thumb(cpu, 0x500, {0x3003, 0x2400, 0x4770});
    cpu.r[4] = 91; cpu.c = true;
    equal(cpu.call(0x400), 10, "nested hook callback returns captured r0");
    healthy(cpu, "nested hook succeeds");
    cpu.hook = {};
    thumb(cpu, 0x100, {0xe7fe}); // B .
    const uint64_t countBefore = cpu.instructionCount;
    cpu.call(0x101, {}, 25);
    require(cpu.fault.find("budget") != std::string::npos, "infinite loop faults at budget");
    equal(uint32_t(cpu.instructionCount - countBefore), 25, "budget retires exact instruction count");
    thumb(cpu, 0x100, {0xde00});
    cpu.call(0x101);
    require(cpu.fault.find("Unhandled Thumb opcode") != std::string::npos, "reserved Thumb opcode explicit fault");
    arm(cpu, 0x100, {0xef000000});
    cpu.call(0x100);
    require(cpu.fault.find("Unhandled ARM opcode") != std::string::npos, "ARM supervisor call explicit fault");
    cpu.call(0x100, {}, 0);
    require(cpu.fault.find("budget") != std::string::npos, "zero budget does not execute");
    thumb(cpu, 0x100, {0x4770});
    cpu.call(0x101);
    healthy(cpu, "new top-level call clears preceding fault");
    cpu.call(GuestCPU::MemorySize);
    require(cpu.fault.find("outside") != std::string::npos, "instruction fetch out of bounds faults");
}
}

int main() {
    memoryTests();
    boundedMemoryTests();
    registerTransferBoundaryTests();
    thumbArithmeticTests();
    thumbShiftTests();
    thumbMemoryTests();
    thumbExtensionTests();
    thumbControlFlowTests();
    armArithmeticTests();
    armMultiplyTests();
    armMemoryTests();
    armControlFlowTests();
    originalSwitchHelperTests();
    callAndFaultTests();
    std::cout << "Passed " << checks << " GuestCPU regression checks.\n";
    std::cout << "These checks cover selected user-code semantics, not ARM conformance.\n";
}
