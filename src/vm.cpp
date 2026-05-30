#include "vm.h"
#include <array>
#include <cassert>
#include <cstdint>
#include <stdlib.h>
#include <string_view>

inline auto push(vm &v, cell_t x) -> void { v.ds(v.sp()++) = x; }

inline auto pop(vm &v) -> cell_t { return v.ds(--v.sp()); }

inline auto top(vm &v) -> cell_t & { return v.ds(v.sp() - 1); }

inline auto rpush(vm &v, cell_t x) -> void { v.rs(v.rp()++) = x; }

inline auto rpop(vm &v) -> cell_t { return v.rs(--v.rp()); }

auto fetch_cell(vm &v) -> cell_t {
  auto x = *reinterpret_cast<cell_t *>(&v.mem[v.ip()]);
  v.ip() += CELL_SIZE;
  return x;
}

auto read_cell(vm &v, ucell_t a) -> cell_t {
  return *reinterpret_cast<cell_t *>(&v.mem[a]);
}

auto write_cell(vm &v, ucell_t a, cell_t x) -> void {
  *reinterpret_cast<cell_t *>(&v.mem[a]) = x;
}

inline auto h_nop(vm &) -> void {}

inline auto h_lit(vm &v) -> void { push(v, fetch_cell(v)); }

inline auto h_load(vm &v) -> void {
  top(v) = read_cell(v, static_cast<ucell_t>(top(v)));
}

inline auto h_store(vm &v) -> void {
  auto a = pop(v);
  write_cell(v, static_cast<ucell_t>(a), pop(v));
}

inline auto h_loadb(vm &v) -> void {
  top(v) = v.mem[static_cast<ucell_t>(top(v))];
}

inline auto h_storeb(vm &v) -> void {
  auto a = pop(v);
  v.mem[static_cast<ucell_t>(a)] = static_cast<uint8_t>(pop(v));
}

inline auto h_drop(vm &v) -> void { pop(v); }

inline auto h_dup(vm &v) -> void { push(v, top(v)); }

inline auto h_swap(vm &v) -> void {
  auto a = pop(v);
  auto b = pop(v);
  push(v, a);
  push(v, b);
}

inline auto h_over(vm &v) -> void { push(v, v.ds(v.sp() - 2)); }

inline auto h_tor(vm &v) -> void { rpush(v, pop(v)); }

inline auto h_fromr(vm &v) -> void { push(v, rpop(v)); }

inline auto h_rfetch(vm &v) -> void { push(v, v.rs(v.rp() - 1)); }

inline auto h_rpick(vm &v) -> void {
  auto n = static_cast<ucell_t>(fetch_cell(v));
  push(v, v.rs(v.rp() - 1 - n));
}

inline auto h_add(vm &v) -> void {
  auto b = pop(v);
  top(v) += b;
}

inline auto h_sub(vm &v) -> void {
  auto b = pop(v);
  top(v) -= b;
}

inline auto h_mul(vm &v) -> void {
  auto b = pop(v);
  top(v) = static_cast<cell_t>(top(v) * b);
}

inline auto h_div(vm &v) -> void {
  auto b = pop(v);
  top(v) = static_cast<cell_t>(top(v) / b);
}

inline auto h_mod(vm &v) -> void {
  auto b = pop(v);
  top(v) = static_cast<cell_t>(top(v) % b);
}

inline auto h_and(vm &v) -> void {
  auto b = pop(v);
  top(v) &= b;
}

inline auto h_or(vm &v) -> void {
  auto b = pop(v);
  top(v) |= b;
}

inline auto h_xor(vm &v) -> void {
  auto b = pop(v);
  top(v) ^= b;
}

inline auto h_eq(vm &v) -> void {
  auto b = pop(v);
  top(v) = (top(v) == b) ? -1 : 0;
}

inline auto h_lt(vm &v) -> void {
  auto b = pop(v);
  top(v) = (top(v) < b) ? -1 : 0;
}

inline auto h_branch(vm &v) -> void {
  v.ip() = static_cast<ucell_t>(fetch_cell(v));
}

inline auto h_zbranch(vm &v) -> void {
  auto a = fetch_cell(v);
  if (pop(v) == 0)
    v.ip() = static_cast<ucell_t>(a);
}

inline auto h_call(vm &v) -> void {
  auto a = fetch_cell(v);
  rpush(v, static_cast<cell_t>(v.ip()));
  v.ip() = static_cast<ucell_t>(a);
}

inline auto h_ret(vm &v) -> void { v.ip() = static_cast<ucell_t>(rpop(v)); }

inline auto h_execute(vm &v) -> void {
  rpush(v, static_cast<cell_t>(v.ip()));
  v.ip() = static_cast<ucell_t>(pop(v));
}

inline auto h_trap(vm &v) -> void {
  auto n = static_cast<uint8_t>(pop(v));
  switch (n) {
  case TRAP_EMIT:
    std::putchar(static_cast<char>(pop(v)));
    break;
  case TRAP_KEY:
    push(v, std::getchar());
    break;
  case TRAP_BYE:
    v.running = false;
    break;
  case TRAP_ASSERT:
    exit(1);
    break;
  default:
    if (v.trap_ext)
      v.trap_ext(v, n);
    else
      assert(false && "unknown trap");
    break;
  }
}

constexpr std::array<op_info, OP_COUNT> dispatch = {{
    {NOP, "nop", 0, 0, 0, 0},
    {LIT, "lit", 0, 1, 0, 0},
    {LOAD, "@", 1, 1, 0, 0},
    {STORE, "!", 2, 0, 0, 0},
    {LOADB, "c@", 1, 1, 0, 0},
    {STOREB, "c!", 2, 0, 0, 0},
    {DROP, "drop", 1, 0, 0, 0},
    {DUP, "dup", 1, 2, 0, 0},
    {SWAP, "swap", 2, 2, 0, 0},
    {OVER, "over", 2, 3, 0, 0},
    {TOR, ">r", 1, 0, 0, 1},
    {FROMR, "r>", 0, 1, 1, 0},
    {RFETCH, "r@", 0, 1, 1, 1},
    {RPICK, "rpick", 0, 1, 1, 1},
    {ADD, "+", 2, 1, 0, 0},
    {SUB, "-", 2, 1, 0, 0},
    {MUL, "*", 2, 1, 0, 0},
    {DIV, "/", 2, 1, 0, 0},
    {MOD, "mod", 2, 1, 0, 0},
    {AND, "and", 2, 1, 0, 0},
    {OR, "or", 2, 1, 0, 0},
    {XOR, "xor", 2, 1, 0, 0},
    {EQ, "=", 2, 1, 0, 0},
    {LT, "<", 2, 1, 0, 0},
    {BRANCH, "branch", 0, 0, 0, 0},
    {ZBRANCH, "zbranch", 1, 0, 0, 0},
    {CALL, "call", 0, 0, 0, 1},
    {RET, "ret", 0, 0, 1, 0},
    {EXECUTE, "execute", 1, 0, 0, 1},
    {TRAP, "trap", 1, 0, 0, 0},
}};

static_assert(dispatch[STORE].code == STORE, "dispatch table out of order");
static_assert(dispatch[RPICK].code == RPICK, "dispatch table out of order");

auto run(vm &v) -> void {
  static const void *dtable[OP_COUNT] = {
      &&do_nop,     &&do_lit,    &&do_load, &&do_store,   &&do_loadb,  &&do_storeb,
      &&do_drop,    &&do_dup,    &&do_swap, &&do_over,    &&do_tor,    &&do_fromr,
      &&do_rfetch,  &&do_rpick,  &&do_add,  &&do_sub,     &&do_mul,    &&do_div,
      &&do_mod,     &&do_and,    &&do_or,   &&do_xor,     &&do_eq,     &&do_lt,
      &&do_branch,  &&do_zbranch,&&do_call, &&do_ret,     &&do_execute,&&do_trap,
  };
  static_assert(OP_COUNT == 30, "update dtable");

  // fetch next opcode, run checks, return target label
  auto next = [&]() -> const void * {
    if (v.ip() >= MEMORY_SIZE) [[unlikely]] {
      std::fprintf(stderr, "error: ip out of bounds (ip=%u, max=%zu)\n", v.ip(),
                   MEMORY_SIZE - 1);
      exit(1);
    }
    auto prev_ip = v.ip();
    auto opcode = static_cast<uint8_t>(fetch_cell(v));
    if (opcode >= OP_COUNT) [[unlikely]] {
      std::fprintf(stderr, "error: invalid opcode %d at ip=%u\n", opcode,
                   prev_ip);
      exit(1);
    }
    const auto &info = dispatch[opcode];
    if (v.debug) [[unlikely]] {
      std::fprintf(v.trace_out, "%04x\t%s", prev_ip, info.name.data());
      switch (opcode) {
      case LIT:
      case TRAP:
      case RPICK:
        std::fprintf(v.trace_out, "\t%d", read_cell(v, v.ip()));
        break;
      case BRANCH:
      case ZBRANCH:
      case CALL:
        std::fprintf(v.trace_out, "\t->%04x",
                     static_cast<ucell_t>(read_cell(v, v.ip())));
        break;
      default:
        break;
      }
      std::fprintf(v.trace_out, "\t[");
      for (ucell_t i = 0; i < v.sp(); ++i) {
        std::fprintf(v.trace_out, "%d", v.ds(i));
        if (i < v.sp() - 1)
          std::fprintf(v.trace_out, " ");
      }
      std::fprintf(v.trace_out, "]\n");
    }
    if (v.sp() < info.in) [[unlikely]] {
      std::fprintf(stderr,
                   "error: stack underflow at ip=%u (%s needs %d, sp=%u)\n",
                   prev_ip, info.name.data(), info.in, v.sp());
      exit(1);
    }
    if (v.rp() < info.rin) [[unlikely]] {
      std::fprintf(
          stderr,
          "error: return stack underflow at ip=%u (%s needs %d, rp=%u)\n",
          prev_ip, info.name.data(), info.rin, v.rp());
      exit(1);
    }
    return dtable[opcode];
  };

  goto *(next());

do_nop:
  h_nop(v);
  goto *(next());
do_lit:
  h_lit(v);
  goto *(next());
do_load:
  h_load(v);
  goto *(next());
do_store:
  h_store(v);
  goto *(next());
do_loadb:
  h_loadb(v);
  goto *(next());
do_storeb:
  h_storeb(v);
  goto *(next());
do_drop:
  h_drop(v);
  goto *(next());
do_dup:
  h_dup(v);
  goto *(next());
do_swap:
  h_swap(v);
  goto *(next());
do_over:
  h_over(v);
  goto *(next());
do_tor:
  h_tor(v);
  goto *(next());
do_fromr:
  h_fromr(v);
  goto *(next());
do_rfetch:
  h_rfetch(v);
  goto *(next());
do_rpick:
  h_rpick(v);
  goto *(next());
do_add:
  h_add(v);
  goto *(next());
do_sub:
  h_sub(v);
  goto *(next());
do_mul:
  h_mul(v);
  goto *(next());
do_div:
  h_div(v);
  goto *(next());
do_mod:
  h_mod(v);
  goto *(next());
do_and:
  h_and(v);
  goto *(next());
do_or:
  h_or(v);
  goto *(next());
do_xor:
  h_xor(v);
  goto *(next());
do_eq:
  h_eq(v);
  goto *(next());
do_lt:
  h_lt(v);
  goto *(next());
do_branch:
  h_branch(v);
  goto *(next());
do_zbranch:
  h_zbranch(v);
  goto *(next());
do_call:
  h_call(v);
  goto *(next());
do_ret:
  h_ret(v);
  goto *(next());
do_execute:
  h_execute(v);
  goto *(next());
do_trap:
  h_trap(v);
  if (!v.running)
    return;
  goto *(next());
}

auto init(vm &v) -> void {
  v.ip() = 0;
  v.sp() = 0;
  v.rp() = 0;
  v.running = true;
}