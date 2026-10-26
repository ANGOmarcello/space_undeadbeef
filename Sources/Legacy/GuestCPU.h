//
//  GuestCPU.h
//  SPACE UNDEADBEEF
//
//  Created by Angelo Cammalleri on 25.10.2026.
//

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <initializer_list>
#include <string>
#include <vector>

// A bounded ARMv6 user-code interpreter for the original 32-bit executable.
// It deliberately has no privileged mode, coprocessor, exception, or JIT support.
// Unsupported instructions stop with a diagnostic instead of being skipped.
class GuestCPU {
public:
    static constexpr uint32_t MemorySize = 32u * 1024u * 1024u;
    static constexpr uint32_t StackTop = 0x01f00000u;
    static constexpr uint32_t ReturnAddress = 0xfffffff0u;
    static constexpr uint64_t DefaultInstructionBudget = 2000000u;

    GuestCPU();

    // r15 always stores the next instruction address, not the pipelined PC.
    // Instructions reading PC receive their architecture-specific PC value.
    std::array<uint32_t, 16> r{};
    bool n = false;
    bool z = false;
    bool c = false;
    bool v = false;
    bool thumb = false;
    std::vector<uint8_t> memory;
    std::string fault;
    uint64_t instructionCount = 0;

    // Called at the current, aligned PC before decoding, in either instruction
    // set. Return true after handling an import/native bridge. A handled hook
    // must advance PC, normally with returnFromHook(). It counts toward budgets.
    std::function<bool(GuestCPU&, uint32_t)> hook;

    uint8_t read8(uint32_t address) {
        return range(address, 1) ? memory[address] : 0;
    }
    uint16_t read16(uint32_t address) {
        if (!range(address, 2)) return 0;
        return uint16_t(memory[address]) | uint16_t(uint16_t(memory[address + 1]) << 8);
    }
    uint32_t read32(uint32_t address) {
        return range(address, 4) ? readWord(address) : 0;
    }
    void write8(uint32_t address, uint8_t value) {
        if (range(address, 1)) memory[address] = value;
    }
    void write16(uint32_t address, uint16_t value) {
        if (!range(address, 2)) return;
        memory[address] = uint8_t(value);
        memory[address + 1] = uint8_t(value >> 8);
    }
    void write32(uint32_t address, uint32_t value) {
        if (range(address, 4)) writeWord(address, value);
    }
    bool load(uint32_t address, const void* bytes, size_t size);

    // Executes one guest instruction or bridge. Returns false on a fault or
    // the call-return sentinel. An existing fault is never silently cleared.
    bool step();

    // Calls AAPCS-style code: r0-r3 contain the first four arguments and further
    // words are placed on an 8-byte-aligned stack. The low address bit selects
    // Thumb. A top-level call clears the previous fault and retains resulting
    // registers. A call made inside a hook restores its enclosing CPU context
    // after capturing r0. Guest memory changes are retained in either case.
    uint32_t call(uint32_t address, const std::vector<uint32_t>& arguments = {},
                  uint64_t budget = DefaultInstructionBudget);

    void branchExchange(uint32_t address);
    void returnFromHook();
    void fail(const std::string& message);

private:
    struct ShiftResult { uint32_t value; bool carry; };
    unsigned callDepth_ = 0;
    uint32_t instructionAddress_ = 0;
    // Only use these after validating the whole access or register-transfer
    // span. No callback runs between span validation and its individual words.
    uint32_t readWord(uint32_t address) const {
        return uint32_t(memory[address]) | (uint32_t(memory[address + 1]) << 8) |
               (uint32_t(memory[address + 2]) << 16) | (uint32_t(memory[address + 3]) << 24);
    }
    void writeWord(uint32_t address, uint32_t value) {
        for (unsigned byte = 0; byte != 4; ++byte)
            memory[address + byte] = uint8_t(value >> (byte * 8));
    }
    // Keep valid accesses cheap even when the caller is inlined. Diagnostic
    // stream construction belongs on the out-of-bounds path only.
    bool range(uint32_t address, size_t size) {
        const size_t available = memory.size();
        if (address <= available && size <= available - address) return true;
        memoryFault(address, size);
        return false;
    }
    void memoryFault(uint32_t address, size_t size);
    bool condition(unsigned conditionCode) const;
    void setNZ(uint32_t value);
    uint32_t add(uint32_t a, uint32_t b, bool carryIn, bool setFlags);
    static ShiftResult shift(uint32_t value, unsigned type, unsigned amount,
                             bool immediate, bool carryIn);
    static uint32_t signExtend(uint32_t value, unsigned bits);
    uint32_t armRegister(unsigned index, bool store = false) const;
    uint32_t thumbRegister(unsigned index) const;
    void armInstruction(uint32_t opcode);
    void thumbInstruction(uint16_t opcode);
    void unknown(uint32_t opcode, unsigned width);
};
