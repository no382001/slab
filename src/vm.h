#pragma once

#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <string_view>

using cell_t = int16_t;
using ucell_t = std::make_unsigned_t<cell_t>;

constexpr size_t CELL_SIZE = sizeof(cell_t);
constexpr size_t MEMORY_SIZE = 0xFFFF;
constexpr size_t STACK_SIZE = 256;

using addr_t = std::conditional_t<
    (MEMORY_SIZE <= 0xFF), uint8_t,
    std::conditional_t<
        (MEMORY_SIZE <= 0xFFFF), uint16_t,
        std::conditional_t<(MEMORY_SIZE <= 0xFFFFFFFF), uint32_t, uint64_t>>>;

constexpr addr_t DS_START = MEMORY_SIZE - (STACK_SIZE * CELL_SIZE * 2);
constexpr addr_t RS_START = DS_START + (STACK_SIZE * CELL_SIZE);
constexpr addr_t SP_ADDR = DS_START - CELL_SIZE * 3;
constexpr addr_t RP_ADDR = DS_START - CELL_SIZE * 2;
constexpr addr_t IP_ADDR = DS_START - CELL_SIZE * 1;

enum trap : uint8_t {
  TRAP_EMIT = 0,   // ( char -- )
  TRAP_KEY = 1,    // ( -- char )
  TRAP_BYE = 2,    // ( -- ) exit
  TRAP_ASSERT = 3, // ( -- ) exit(1)
  TRAP_COUNT
};

// Type tags for codegen
enum class vtype : uint8_t { VOID, INT, BYTE, BOOL };

constexpr std::string_view vtype_str(vtype t) {
  switch (t) {
  case vtype::VOID:
    return "void";
  case vtype::INT:
    return "int";
  case vtype::BYTE:
    return "byte";
  case vtype::BOOL:
    return "bool";
  }
  return "?";
}

// Compile-time type signature: sig<ReturnType, ParamTypes...>
template <vtype Ret, vtype... Params> struct sig {
  static constexpr vtype ret = Ret;
  static constexpr std::array<vtype, sizeof...(Params)> params{Params...};
};

struct trap_info {
  uint8_t code;
  std::string_view name;
  vtype ret;
  std::array<vtype, 4> params;
  uint8_t arity;
};

template <vtype Ret, vtype... Params>
constexpr trap_info make_trap(uint8_t code, std::string_view name) {
  return {code, name, Ret, {Params...}, sizeof...(Params)};
}

inline constexpr std::array<trap_info, TRAP_COUNT> traps = {{
    make_trap<vtype::VOID, vtype::INT>(TRAP_EMIT, "emit"),
    make_trap<vtype::INT>(TRAP_KEY, "key"),
    make_trap<vtype::VOID>(TRAP_BYE, "bye"),
    make_trap<vtype::VOID>(TRAP_ASSERT, "assert-fail"),
}};

enum op : uint8_t {
  // core
  NOP,
  LIT,
  // memory
  LOAD,
  STORE,
  LOADB,
  STOREB,
  // stack
  DROP,
  DUP,
  SWAP,
  OVER,
  // rack
  TOR,
  FROMR,
  RFETCH,
  RPICK,
  // alu
  ADD,
  SUB,
  MUL,
  DIV,
  MOD,
  AND,
  OR,
  XOR,
  EQ,
  LT,
  // control
  BRANCH,
  ZBRANCH,
  CALL,
  RET,
  EXECUTE,
  // system
  TRAP,
  OP_COUNT
};

struct vm;
struct op_info {
  op code;
  std::string_view name;
  uint8_t in;
  uint8_t out;
  uint8_t rin;
  uint8_t rout;
};

extern const std::array<op_info, OP_COUNT> dispatch;

struct vm {
  std::array<uint8_t, MEMORY_SIZE> mem{};
  bool running{true};
  bool debug{false};
  FILE *trace_out{stderr};
  void (*trap_ext)(vm &, uint8_t) = nullptr;

  auto ip() -> ucell_t & { return *reinterpret_cast<ucell_t *>(&mem[IP_ADDR]); }
  auto sp() -> ucell_t & { return *reinterpret_cast<ucell_t *>(&mem[SP_ADDR]); }
  auto rp() -> ucell_t & { return *reinterpret_cast<ucell_t *>(&mem[RP_ADDR]); }
  auto ds(ucell_t i) -> cell_t & {
    return *reinterpret_cast<cell_t *>(&mem[DS_START + i * CELL_SIZE]);
  }
  auto rs(ucell_t i) -> cell_t & {
    return *reinterpret_cast<cell_t *>(&mem[RS_START + i * CELL_SIZE]);
  }
};

auto fetch_cell(vm &v) -> cell_t;
auto read_cell(vm &v, ucell_t a) -> cell_t;
auto write_cell(vm &v, ucell_t a, cell_t x) -> void;

auto run(vm &v) -> void;
auto init(vm &v) -> void;