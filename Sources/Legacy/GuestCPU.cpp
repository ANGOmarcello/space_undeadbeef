//
//  GuestCPU.cpp
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#include "GuestCPU.h"

#include <algorithm>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>

namespace {
uint32_t rotateRight(uint32_t value, unsigned amount) {
    amount &= 31u;
    return amount == 0 ? value : (value >> amount) | (value << (32u - amount));
}

unsigned populationCount(uint32_t value) {
    unsigned count = 0;
    for (; value; value &= value - 1u) ++count;
    return count;
}
}

GuestCPU::GuestCPU() : memory(MemorySize, 0) {
    r[13] = StackTop;
}

void GuestCPU::fail(const std::string& message) {
    if (fault.empty()) fault = message;
}

void GuestCPU::memoryFault(uint32_t address, size_t size) {
    std::ostringstream message;
    message << "Guest memory access outside 32 MiB: 0x" << std::hex << address
            << " (" << std::dec << size << " bytes), PC 0x" << std::hex
            << instructionAddress_;
    fail(message.str());
}

bool GuestCPU::load(uint32_t address, const void* bytes, size_t size) {
    if (!range(address, size)) return false;
    if (size != 0) {
        if (bytes == nullptr) { fail("Null source passed to guest memory load"); return false; }
        std::memcpy(memory.data() + address, bytes, size);
    }
    return true;
}

bool GuestCPU::condition(unsigned code) const {
    switch (code) {
        case 0: return z;
        case 1: return !z;
        case 2: return c;
        case 3: return !c;
        case 4: return n;
        case 5: return !n;
        case 6: return v;
        case 7: return !v;
        case 8: return c && !z;
        case 9: return !c || z;
        case 10: return n == v;
        case 11: return n != v;
        case 12: return !z && n == v;
        case 13: return z || n != v;
        case 14: return true;
        default: return false;
    }
}

void GuestCPU::setNZ(uint32_t value) {
    n = (value & 0x80000000u) != 0;
    z = value == 0;
}

uint32_t GuestCPU::add(uint32_t a, uint32_t b, bool carryIn, bool setFlags) {
    const uint64_t wide = uint64_t(a) + b + uint32_t(carryIn);
    const uint32_t result = uint32_t(wide);
    if (setFlags) {
        setNZ(result);
        c = (wide >> 32) != 0;
        v = ((~(a ^ b) & (a ^ result)) & 0x80000000u) != 0;
    }
    return result;
}

GuestCPU::ShiftResult GuestCPU::shift(uint32_t value, unsigned type, unsigned amount,
                                    bool immediate, bool carryIn) {
    if (amount == 0) {
        if (!immediate || type == 0) return {value, carryIn};
        if (type == 3) return {(uint32_t(carryIn) << 31) | (value >> 1), (value & 1u) != 0};
        amount = 32;
    }
    switch (type) {
        case 0:
            if (amount < 32) return {value << amount, ((value >> (32 - amount)) & 1u) != 0};
            return {0, amount == 32 && (value & 1u) != 0};
        case 1:
            if (amount < 32) return {value >> amount, ((value >> (amount - 1)) & 1u) != 0};
            return {0, amount == 32 && (value >> 31) != 0};
        case 2: {
            const bool sign = (value >> 31) != 0;
            if (amount >= 32) return {sign ? 0xffffffffu : 0, sign};
            const uint32_t extension = sign ? (0xffffffffu << (32 - amount)) : 0;
            return {(value >> amount) | extension, ((value >> (amount - 1)) & 1u) != 0};
        }
        default: {
            const uint32_t result = rotateRight(value, amount);
            return {result, (result >> 31) != 0};
        }
    }
}

uint32_t GuestCPU::signExtend(uint32_t value, unsigned bits) {
    const uint32_t sign = uint32_t(1) << (bits - 1);
    return (value ^ sign) - sign;
}

uint32_t GuestCPU::armRegister(unsigned index, bool store) const {
    return index == 15 ? instructionAddress_ + (store ? 12u : 8u) : r[index];
}

uint32_t GuestCPU::thumbRegister(unsigned index) const {
    return index == 15 ? instructionAddress_ + 4u : r[index];
}

void GuestCPU::branchExchange(uint32_t address) {
    thumb = (address & 1u) != 0;
    r[15] = address & (thumb ? ~1u : ~3u);
}

void GuestCPU::returnFromHook() {
    branchExchange(r[14]);
}

void GuestCPU::unknown(uint32_t opcode, unsigned width) {
    std::ostringstream message;
    message << "Unhandled " << (width == 16 ? "Thumb" : "ARM") << " opcode 0x"
            << std::hex << std::setfill('0') << std::setw(width / 4) << opcode
            << " at 0x" << std::setw(8) << instructionAddress_;
    fail(message.str());
}

bool GuestCPU::step() {
    if (!fault.empty() || r[15] == ReturnAddress) return false;
    instructionAddress_ = r[15];
    if ((r[15] & (thumb ? 1u : 3u)) != 0) {
        fail("Misaligned guest instruction address");
        return false;
    }
    ++instructionCount;
    if (hook && hook(*this, instructionAddress_)) return fault.empty();
    // A nested call in a hook can change the diagnostic instruction address.
    instructionAddress_ = r[15];
    if (thumb) {
        const uint16_t opcode = read16(instructionAddress_);
        if (!fault.empty()) return false;
        r[15] += 2;
        thumbInstruction(opcode);
    } else {
        const uint32_t opcode = read32(instructionAddress_);
        if (!fault.empty()) return false;
        r[15] += 4;
        armInstruction(opcode);
    }
    return fault.empty();
}

uint32_t GuestCPU::call(uint32_t address, const std::vector<uint32_t>& arguments, uint64_t budget) {
    const auto savedRegisters = r;
    const std::array<bool, 5> savedFlags{n, z, c, v, thumb};
    const uint32_t savedInstructionAddress = instructionAddress_;
    const bool nested = callDepth_ != 0;
    if (!nested) fault.clear();
    if (!fault.empty()) return 0;
    ++callDepth_;
    if (r[13] == 0) r[13] = StackTop;
    const uint32_t savedSP = r[13];
    const size_t stackWords = arguments.size() > 4 ? arguments.size() - 4 : 0;
    if (stackWords > MemorySize / 4 || uint64_t(stackWords) * 4u > r[13]) {
        fail("Guest call argument stack exceeds available memory");
    } else {
        r[13] = (r[13] - uint32_t(stackWords * 4u)) & ~7u;
        for (size_t i = 0; i < arguments.size(); ++i) {
            if (i < 4) r[i] = arguments[i];
            else write32(r[13] + uint32_t((i - 4) * 4), arguments[i]);
        }
        r[14] = ReturnAddress;
        branchExchange(address);
        const uint64_t startCount = instructionCount;
        while (fault.empty() && r[15] != ReturnAddress) {
            if (instructionCount - startCount >= budget) {
                std::ostringstream message;
                message << "Guest instruction budget exhausted at 0x" << std::hex << r[15];
                fail(message.str());
                break;
            }
            if (!step()) break;
        }
    }
    const uint32_t result = r[0];
    --callDepth_;
    if (nested) {
        r = savedRegisters;
        n = savedFlags[0]; z = savedFlags[1]; c = savedFlags[2]; v = savedFlags[3]; thumb = savedFlags[4];
        instructionAddress_ = savedInstructionAddress;
    } else {
        r[13] = savedSP;
    }
    return result;
}

void GuestCPU::thumbInstruction(uint16_t op) {
    const unsigned rd = op & 7u;
    const unsigned rs = (op >> 3) & 7u;
    if ((op & 0xe000u) == 0) {
        if ((op & 0x1800u) != 0x1800u) {
            const auto result = shift(r[rs], (op >> 11) & 3u, (op >> 6) & 31u, true, c);
            r[rd] = result.value; setNZ(result.value); c = result.carry;
        } else {
            const uint32_t operand = (op & 0x0400u) ? ((op >> 6) & 7u) : r[(op >> 6) & 7u];
            r[rd] = (op & 0x0200u) ? add(r[rs], ~operand, true, true) : add(r[rs], operand, false, true);
        }
        return;
    }
    if ((op & 0xe000u) == 0x2000u) {
        const unsigned dest = (op >> 8) & 7u;
        const uint32_t immediate = op & 255u;
        switch ((op >> 11) & 3u) {
            case 0: r[dest] = immediate; setNZ(immediate); break;
            case 1: add(r[dest], ~immediate, true, true); break;
            case 2: r[dest] = add(r[dest], immediate, false, true); break;
            case 3: r[dest] = add(r[dest], ~immediate, true, true); break;
        }
        return;
    }
    if ((op & 0xfc00u) == 0x4000u) {
        const unsigned operation = (op >> 6) & 15u;
        uint32_t result = r[rd];
        switch (operation) {
            case 0: result &= r[rs]; break;
            case 1: result ^= r[rs]; break;
            case 2: case 3: case 4: case 7: {
                const unsigned type = operation == 7 ? 3u : operation - 2u;
                const auto shifted = shift(result, type, r[rs] & 255u, false, c);
                result = shifted.value; c = shifted.carry; break;
            }
            case 5: r[rd] = add(result, r[rs], c, true); return;
            case 6: r[rd] = add(result, ~r[rs], c, true); return;
            case 8: setNZ(result & r[rs]); return;
            case 9: r[rd] = add(0, ~r[rs], true, true); return;
            case 10: add(result, ~r[rs], true, true); return;
            case 11: add(result, r[rs], false, true); return;
            case 12: result |= r[rs]; break;
            case 13: result *= r[rs]; break;
            case 14: result &= ~r[rs]; break;
            case 15: result = ~r[rs]; break;
        }
        r[rd] = result; setNZ(result); return;
    }
    if ((op & 0xfc00u) == 0x4400u) {
        const unsigned dest = rd | ((op >> 4) & 8u);
        const unsigned source = (op >> 3) & 15u;
        const uint32_t operand = thumbRegister(source);
        switch ((op >> 8) & 3u) {
            case 0: {
                const uint32_t result = thumbRegister(dest) + operand;
                if (dest == 15) r[15] = result & ~1u; else r[dest] = result;
                return;
            }
            case 1: add(thumbRegister(dest), ~operand, true, true); return;
            case 2: if (dest == 15) r[15] = operand & ~1u; else r[dest] = operand; return;
            case 3:
                if ((op & 7u) != 0) { unknown(op, 16); return; }
                if ((op & 0x0080u) != 0) r[14] = r[15] | 1u;
                branchExchange(operand); return;
        }
    }
    if ((op & 0xf800u) == 0x4800u) {
        r[(op >> 8) & 7u] = read32(((instructionAddress_ + 4u) & ~3u) + ((op & 255u) << 2));
        return;
    }
    if ((op & 0xf000u) == 0x5000u) {
        const uint32_t address = r[rs] + r[(op >> 6) & 7u];
        switch ((op >> 9) & 7u) {
            case 0: write32(address, r[rd]); break;
            case 1: write16(address, uint16_t(r[rd])); break;
            case 2: write8(address, uint8_t(r[rd])); break;
            case 3: r[rd] = signExtend(read8(address), 8); break;
            case 4: r[rd] = read32(address); break;
            case 5: r[rd] = read16(address); break;
            case 6: r[rd] = read8(address); break;
            case 7: r[rd] = signExtend(read16(address), 16); break;
        }
        return;
    }
    if ((op & 0xe000u) == 0x6000u) {
        const bool byte = (op & 0x1000u) != 0;
        const uint32_t offset = ((op >> 6) & 31u) << (byte ? 0 : 2);
        const uint32_t address = r[rs] + offset;
        if ((op & 0x0800u) != 0) r[rd] = byte ? read8(address) : read32(address);
        else if (byte) write8(address, uint8_t(r[rd]));
        else write32(address, r[rd]);
        return;
    }
    if ((op & 0xf000u) == 0x8000u) {
        const uint32_t address = r[rs] + (((op >> 6) & 31u) << 1);
        if ((op & 0x0800u) != 0) r[rd] = read16(address);
        else write16(address, uint16_t(r[rd]));
        return;
    }
    if ((op & 0xf000u) == 0x9000u) {
        const uint32_t address = r[13] + ((op & 255u) << 2);
        const unsigned reg = (op >> 8) & 7u;
        if ((op & 0x0800u) != 0) r[reg] = read32(address); else write32(address, r[reg]);
        return;
    }
    if ((op & 0xf000u) == 0xa000u) {
        r[(op >> 8) & 7u] = ((op & 0x0800u) ? r[13] : ((instructionAddress_ + 4u) & ~3u)) + ((op & 255u) << 2);
        return;
    }
    if ((op & 0xff00u) == 0xb000u) {
        const uint32_t offset = (op & 127u) << 2;
        r[13] = (op & 0x0080u) ? r[13] - offset : r[13] + offset;
        return;
    }
    if ((op & 0xff00u) == 0xb200u) {
        switch ((op >> 6) & 3u) {
            case 0: r[rd] = signExtend(r[rs] & 65535u, 16); break;
            case 1: r[rd] = signExtend(r[rs] & 255u, 8); break;
            case 2: r[rd] = r[rs] & 65535u; break;
            case 3: r[rd] = r[rs] & 255u; break;
        }
        return;
    }
    if ((op & 0xf600u) == 0xb400u) {
        const bool pop = (op & 0x0800u) != 0;
        const uint32_t list = (op & 255u) | ((op & 0x0100u) ? (pop ? 0x8000u : 0x4000u) : 0u);
        if (list == 0) { fail("Empty Thumb PUSH/POP register list"); return; }
        const uint32_t bytes = populationCount(list) * 4u;
        uint32_t address = pop ? r[13] : r[13] - bytes;
        if (!range(address, bytes)) return;
        for (unsigned reg = 0; reg != 16; ++reg) if ((list & (1u << reg)) != 0) {
            if (pop) {
                const uint32_t value = readWord(address);
                if (reg == 15) branchExchange(value); else r[reg] = value;
            } else writeWord(address, r[reg]);
            address += 4;
        }
        r[13] = pop ? r[13] + bytes : r[13] - bytes;
        return;
    }
    if ((op & 0xff00u) == 0xba00u) {
        const uint32_t value = r[rs];
        switch ((op >> 6) & 3u) {
            case 0: r[rd] = ((value & 0xffu) << 24) | ((value & 0xff00u) << 8) |
                           ((value >> 8) & 0xff00u) | (value >> 24); return;
            case 1: r[rd] = ((value & 0x00ff00ffu) << 8) | ((value & 0xff00ff00u) >> 8); return;
            case 3: r[rd] = signExtend(((value & 0xffu) << 8) | ((value >> 8) & 0xffu), 16); return;
            default: unknown(op, 16); return;
        }
    }
    if ((op & 0xf000u) == 0xc000u) {
        const unsigned base = (op >> 8) & 7u;
        const uint32_t list = op & 255u;
        const bool loadRegisters = (op & 0x0800u) != 0;
        if (list == 0) { fail("Empty Thumb LDM/STM register list"); return; }
        const uint32_t bytes = populationCount(list) * 4u;
        uint32_t address = r[base];
        if (!range(address, bytes)) return;
        for (unsigned reg = 0; reg != 8; ++reg) if ((list & (1u << reg)) != 0) {
            if (loadRegisters) r[reg] = readWord(address); else writeWord(address, r[reg]);
            address += 4;
        }
        // When the base is loaded, its loaded value wins over writeback.
        if (!loadRegisters || (list & (1u << base)) == 0) r[base] = address;
        return;
    }
    if ((op & 0xf000u) == 0xd000u) {
        const unsigned cond = (op >> 8) & 15u;
        if (cond >= 14) { unknown(op, 16); return; }
        if (condition(cond)) r[15] = instructionAddress_ + 4u + signExtend((op & 255u) << 1, 9);
        return;
    }
    if ((op & 0xf800u) == 0xe000u) {
        r[15] = instructionAddress_ + 4u + signExtend((op & 2047u) << 1, 12);
        return;
    }
    if ((op & 0xf800u) == 0xf000u) {
        r[14] = instructionAddress_ + 4u + signExtend((op & 2047u) << 12, 23);
        return;
    }
    if ((op & 0xf800u) == 0xf800u || (op & 0xf800u) == 0xe800u) {
        const uint32_t target = r[14] + ((op & 2047u) << 1);
        r[14] = r[15] | 1u;
        if ((op & 0xf800u) == 0xe800u) {
            if ((op & 1u) != 0) { unknown(op, 16); return; }
            thumb = false; r[15] = target & ~3u;
        } else r[15] = target & ~1u;
        return;
    }
    unknown(op, 16);
}

void GuestCPU::armInstruction(uint32_t op) {
    const unsigned cond = op >> 28;
    if (cond == 15) {
        // BLX immediate is the ARMv5 unconditional branch encoding.
        if ((op & 0xfe000000u) == 0xfa000000u) {
            r[14] = instructionAddress_ + 4u;
            const uint32_t offset = signExtend((op & 0x00ffffffu) << 2, 26) | ((op >> 23) & 2u);
            thumb = true;
            r[15] = instructionAddress_ + 8u + offset;
        } else unknown(op, 32);
        return;
    }
    if (!condition(cond)) return;
    const unsigned rn = (op >> 16) & 15u;
    const unsigned rd = (op >> 12) & 15u;
    const unsigned rm = op & 15u;
    if ((op & 0x0ffffff0u) == 0x012fff10u || (op & 0x0ffffff0u) == 0x012fff30u) {
        const uint32_t target = armRegister(rm);
        if ((op & 0x20u) != 0) r[14] = instructionAddress_ + 4u;
        branchExchange(target); return;
    }
    if ((op & 0x0fff0ff0u) == 0x016f0f10u) {
        const uint32_t value = armRegister(rm);
        unsigned count = 0;
        for (uint32_t bit = 0x80000000u; bit != 0 && (value & bit) == 0; bit >>= 1) ++count;
        if (rd == 15) { unknown(op, 32); return; }
        r[rd] = count; return;
    }
    // MRS CPSR exposes the condition flags and user/Thumb state. SPSR is absent.
    if ((op & 0x0fbf0fffu) == 0x010f0000u) {
        if ((op & (1u << 22)) != 0 || rd == 15) { unknown(op, 32); return; }
        r[rd] = (uint32_t(n) << 31) | (uint32_t(z) << 30) | (uint32_t(c) << 29) |
                (uint32_t(v) << 28) | 0x10u | (thumb ? 0x20u : 0u);
        return;
    }
    // User-mode MSR may modify NZCV only. Reject control/state changes.
    if ((op & 0x0fb0fff0u) == 0x0120f000u || (op & 0x0fb0f000u) == 0x0320f000u) {
        if ((op & (1u << 22)) != 0 || (op & 0x00070000u) != 0) { unknown(op, 32); return; }
        if ((op & (1u << 19)) != 0) {
            const uint32_t value = (op & (1u << 25)) ? rotateRight(op & 255u, ((op >> 8) & 15u) * 2u) : armRegister(rm);
            n = (value >> 31) != 0; z = ((value >> 30) & 1u) != 0;
            c = ((value >> 29) & 1u) != 0; v = ((value >> 28) & 1u) != 0;
        }
        return;
    }
    if ((op & 0x0f8000f0u) == 0x00800090u) {
        const unsigned low = rd;
        const unsigned high = rn;
        const unsigned rs = (op >> 8) & 15u;
        if (low == 15 || high == 15 || rs == 15 || rm == 15 || low == high) { unknown(op, 32); return; }
        uint64_t product;
        if ((op & (1u << 22)) != 0) {
            const auto signed32 = [](uint32_t value) -> int64_t {
                return (value & 0x80000000u) ? int64_t(value) - 0x100000000ll : int64_t(value);
            };
            product = uint64_t(signed32(r[rm]) * signed32(r[rs]));
        } else product = uint64_t(r[rm]) * r[rs];
        if ((op & (1u << 21)) != 0) product += (uint64_t(r[high]) << 32) | r[low];
        r[low] = uint32_t(product); r[high] = uint32_t(product >> 32);
        if ((op & (1u << 20)) != 0) { n = (product >> 63) != 0; z = product == 0; }
        return;
    }
    if ((op & 0x0fc000f0u) == 0x00000090u) {
        const unsigned dest = rn;
        const unsigned accumulator = rd;
        const unsigned rs = (op >> 8) & 15u;
        if (dest == 15 || rs == 15 || rm == 15) { unknown(op, 32); return; }
        uint32_t result = r[rm] * r[rs];
        if ((op & (1u << 21)) != 0) result += armRegister(accumulator);
        r[dest] = result;
        if ((op & (1u << 20)) != 0) setNZ(result);
        return;
    }
    if ((op & 0x0fb00ff0u) == 0x01000090u) {
        if (rn == 15 || rd == 15 || rm == 15) { unknown(op, 32); return; }
        const uint32_t address = r[rn];
        const bool byte = (op & (1u << 22)) != 0;
        const uint32_t previous = byte ? read8(address) : read32(address);
        if (!fault.empty()) return;
        if (byte) write8(address, uint8_t(r[rm])); else write32(address, r[rm]);
        r[rd] = previous; return;
    }
    // Halfword/signed loads and ARMv5 doubleword transfers.
    if ((op & 0x0e000090u) == 0x00000090u && (op & 0x60u) != 0) {
        const bool pre = (op & (1u << 24)) != 0;
        const bool up = (op & (1u << 23)) != 0;
        const bool immediate = (op & (1u << 22)) != 0;
        const bool writeback = (op & (1u << 21)) != 0 || !pre;
        const bool loadRegister = (op & (1u << 20)) != 0;
        const unsigned operation = (op >> 5) & 3u;
        if (rd == 15 || (writeback && rn == 15)) { unknown(op, 32); return; }
        const uint32_t base = armRegister(rn);
        const uint32_t offset = immediate ? (((op >> 4) & 0xf0u) | (op & 15u)) : armRegister(rm);
        const uint32_t adjusted = up ? base + offset : base - offset;
        const uint32_t address = pre ? adjusted : base;
        if (!loadRegister && operation != 1) {
            if ((rd & 1u) != 0 || rd >= 14 || !range(address, 8)) { unknown(op, 32); return; }
            if (operation == 2) { r[rd] = readWord(address); r[rd + 1] = readWord(address + 4); }
            else { writeWord(address, r[rd]); writeWord(address + 4, r[rd + 1]); }
        } else if (loadRegister) {
            if (operation == 1) r[rd] = read16(address);
            else if (operation == 2) r[rd] = signExtend(read8(address), 8);
            else r[rd] = signExtend(read16(address), 16);
        } else write16(address, uint16_t(r[rd]));
        if (writeback && fault.empty()) r[rn] = adjusted;
        return;
    }
    if ((op & 0x0e000000u) == 0x0a000000u) {
        if ((op & (1u << 24)) != 0) r[14] = instructionAddress_ + 4u;
        r[15] = instructionAddress_ + 8u + signExtend((op & 0x00ffffffu) << 2, 26);
        return;
    }
    if ((op & 0x0e000000u) == 0x08000000u) {
        const bool pre = (op & (1u << 24)) != 0;
        const bool up = (op & (1u << 23)) != 0;
        const bool writeback = (op & (1u << 21)) != 0;
        const bool loadRegisters = (op & (1u << 20)) != 0;
        const uint32_t list = op & 65535u;
        if (rn == 15 || list == 0 || (op & (1u << 22)) != 0) { unknown(op, 32); return; }
        const uint32_t bytes = populationCount(list) * 4u;
        const uint32_t base = r[rn];
        uint32_t address = up ? base + (pre ? 4u : 0u) : base - bytes + (pre ? 0u : 4u);
        if (!range(address, bytes)) return;
        for (unsigned reg = 0; reg != 16; ++reg) if ((list & (1u << reg)) != 0) {
            if (loadRegisters) {
                const uint32_t value = readWord(address);
                if (reg == 15) branchExchange(value); else r[reg] = value;
            } else writeWord(address, armRegister(reg, true));
            address += 4;
        }
        if (writeback && (!loadRegisters || (list & (1u << rn)) == 0)) r[rn] = up ? base + bytes : base - bytes;
        return;
    }
    if ((op & 0x0c000000u) == 0x04000000u) {
        const bool pre = (op & (1u << 24)) != 0;
        const bool up = (op & (1u << 23)) != 0;
        const bool byte = (op & (1u << 22)) != 0;
        const bool writeback = (op & (1u << 21)) != 0 || !pre;
        const bool loadRegister = (op & (1u << 20)) != 0;
        if ((writeback && rn == 15) || (byte && rd == 15) || ((op & (1u << 25)) && (op & 16u))) {
            unknown(op, 32); return;
        }
        const uint32_t base = armRegister(rn);
        const uint32_t offset = (op & (1u << 25)) ?
            shift(armRegister(rm), (op >> 5) & 3u, (op >> 7) & 31u, true, c).value : (op & 4095u);
        const uint32_t adjusted = up ? base + offset : base - offset;
        const uint32_t address = pre ? adjusted : base;
        if (loadRegister) {
            const uint32_t value = byte ? read8(address) : read32(address);
            if (rd == 15) branchExchange(value); else r[rd] = value;
        } else if (byte) write8(address, uint8_t(armRegister(rd, true)));
        else write32(address, armRegister(rd, true));
        if (writeback && fault.empty()) r[rn] = adjusted;
        return;
    }
    if ((op & 0x0c000000u) == 0) {
        const unsigned operation = (op >> 21) & 15u;
        const bool setFlags = (op & (1u << 20)) != 0;
        if ((operation >= 8 && operation <= 11 && !setFlags) ||
            (!(op & (1u << 25)) && (op & 16u) && (op & 128u))) {
            unknown(op, 32); return;
        }
        uint32_t first = armRegister(rn);
        ShiftResult operand;
        if ((op & (1u << 25)) != 0) {
            const unsigned rotation = ((op >> 8) & 15u) * 2u;
            operand.value = rotateRight(op & 255u, rotation);
            operand.carry = rotation == 0 ? c : (operand.value >> 31) != 0;
        } else {
            const bool registerShift = (op & 16u) != 0;
            const unsigned amount = registerShift ? armRegister((op >> 8) & 15u) & 255u : ((op >> 7) & 31u);
            const uint32_t value = armRegister(rm, registerShift && rm == 15);
            // Register-controlled shifts observe the extra pipeline stage for Rn too.
            if (registerShift && rn == 15) first += 4u;
            operand = shift(value, (op >> 5) & 3u, amount, !registerShift, c);
        }
        uint32_t result = 0;
        bool logical = false;
        bool writeResult = true;
        switch (operation) {
            case 0: result = first & operand.value; logical = true; break;
            case 1: result = first ^ operand.value; logical = true; break;
            case 2: result = add(first, ~operand.value, true, setFlags); break;
            case 3: result = add(operand.value, ~first, true, setFlags); break;
            case 4: result = add(first, operand.value, false, setFlags); break;
            case 5: result = add(first, operand.value, c, setFlags); break;
            case 6: result = add(first, ~operand.value, c, setFlags); break;
            case 7: result = add(operand.value, ~first, c, setFlags); break;
            case 8: result = first & operand.value; logical = true; writeResult = false; break;
            case 9: result = first ^ operand.value; logical = true; writeResult = false; break;
            case 10: add(first, ~operand.value, true, true); writeResult = false; break;
            case 11: add(first, operand.value, false, true); writeResult = false; break;
            case 12: result = first | operand.value; logical = true; break;
            case 13: result = operand.value; logical = true; break;
            case 14: result = first & ~operand.value; logical = true; break;
            case 15: result = ~operand.value; logical = true; break;
        }
        if (logical && setFlags) { setNZ(result); c = operand.carry; }
        if (writeResult) {
            if (rd == 15) {
                if (setFlags) { fail("ARM exception-return instruction requires unavailable SPSR"); return; }
                r[15] = result & ~3u;
            } else r[rd] = result;
        }
        return;
    }
    unknown(op, 32);
}
