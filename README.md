# SARCATHON 2026 — Stage 2 (work in progress)
## AXI4-Stream to PCIe Packet Bridge — CRC/Framing Core

This is **not the full Stage 2 submission** — it's the verified foundation
built so far: a real, width-parameterized CRC-32 engine, a packet framer and
checker that use it, and a generalized N-source arbiter + register slice +
top-level integration. Still to come: PHY-layer modeling (lane striping,
PAM4), network/ML workload testbenches, OpenLane/Vivado physical
implementation, and FPGA bring-up. See "What's left" below.

### Project structure
```
stage2/
├── rtl/
│   ├── s2_crc32_gen.v      Generated parallel CRC-32/802.3 engine (32/64/128/256/512-bit)
│   ├── s2_pkt_framer.v     Appends 4-byte CRC trailer to an AXI4-Stream packet
│   ├── s2_pkt_checker.v    Strips trailer, verifies CRC, reconstructs payload
│   ├── s2_axis_arbiter.v   N-way packet-locked round-robin arbiter
│   ├── s2_axis_regslice.v  Generic 2-slot skid buffer / register slice
│   └── s2_top.v            Sources -> arbiter -> regslice -> framer
├── tb/
│   ├── tb_crc_beat.v       Unit test: CRC-32 check value ("123456789" = 0xCBF43926)
│   └── tb_loopback.v       Framer->checker loopback: 51 directed cases + fault injection
├── scripts/
│   └── gen_crc.py          Generates rtl/s2_crc32_gen.v, self-tests against zlib.crc32
├── sim/                    Compiled .vvp simulation binaries
└── README.md               This file
```

### How to reproduce

Requires Icarus Verilog (`iverilog`, `vvp`).

```bash
cd stage2

# regenerate + self-test the CRC engine (optional, already generated)
python3 scripts/gen_crc.py

# unit test: CRC-32 engine against the standard check value
iverilog -g2012 -o sim/tb_crc_beat.vvp rtl/s2_crc32_gen.v tb/tb_crc_beat.v
vvp sim/tb_crc_beat.vvp

# loopback test: framer -> checker, random lengths 1-257 bytes,
# random backpressure, plus fault-injection cases
iverilog -g2012 -o sim/tb_loopback.vvp rtl/s2_crc32_gen.v rtl/s2_pkt_framer.v rtl/s2_pkt_checker.v tb/tb_loopback.v
vvp sim/tb_loopback.vvp
```

Expected: `ALL TESTS PASSED` from both, ending with
`packets_ok=45 packets_bad=6` from the loopback run (the 6 "bad" ones are
the deliberately corrupted packets used to prove the CRC check actually
catches errors).

### What changed vs. Stage 1

| | Stage 1 | Stage 2 (this folder) |
|---|---|---|
| CRC | CRC-8, serial | Real CRC-32/802.3 (same poly as PCIe LCRC), parallel XOR-network update — needed to keep up with a wide bus |
| Data width | fixed 32-bit | parameterized: 32 / 64 / 128 / 256 / 512-bit |
| Sources | 2 (hardcoded) | N (parameterized) |
| Skid buffer | 32-bit only | generalized to any width, carries TLAST |
| Verification | 10 directed checks | 51 directed cases (exhaustive lengths 1-40 bytes + boundary cases + fault injection) with randomized backpressure every run |

### Bugs found and fixed during Stage 2 verification

1. **Race condition** (same class as Stage 1 bug #3): testbench stimulus was
   being driven on the exact clock edge the DUT also samples on, an
   undefined-order race in the simulator. Fixed by driving all stimulus one
   time-step after the sampling edge.
2. **`crc_full` vs `crc_part`**: the checker's final CRC check used
   `crc_full`, which silently assumes all bus lanes hold valid data. That's
   true for an ordinary interior beat, but not for the framer's "spill"
   case, where a beat is marked not-last even though it's only partially
   filled (its trailer got pushed into the next beat). Using `crc_full`
   there fed phantom zero bytes into the CRC and corrupted the result.
   Fixed by always using `crc_part`, which correctly accounts for exactly
   the valid bytes in a beat (and is numerically identical to `crc_full`
   whenever a beat genuinely is fully populated).
3. **Stale pulse read in the testbench itself**: `crc_ok`/`crc_err` are
   one-cycle pulses; the test was waiting for the pulse, then burning
   several more cycles before checking it, by which point it had already
   cleared. Fixed by latching the flag the instant it fires.

### Synthesis estimates (Yosys, informational — no timing closure run)

`s2_top` at `DATA_W=64`, `NUM_SRC=2` (arbiter + regslice + framer only;
the checker is receive-side and not part of this top level):

- Generic cell count: 3246 cells, 364 flip-flops, 1361 XOR cells (the XOR
  count is expected — that's the parallel CRC's XOR tree)
- Mapped to Xilinx 7-series (`synth_xilinx -family xc7`): **~1509 LUTs,
  364 FFs**

These are area estimates only — no Vivado/OpenLane place-and-route or
timing analysis has been run yet.

### Known limitations / what's left

- No clock-domain-crossing between the AXI4-Stream side and the PCIe side
  (single clock throughout) — a real design needs a CDC FIFO here.
- `TKEEP` gaps (non-contiguous valid bytes) are detected (`keep_err`) but
  not handled — AXI4-Stream technically permits this, framer does not.
- No PHY-layer modeling (lane striping, PAM4, Gray coding) — explicitly
  out of scope for Stage 1, still not attempted here.
- No network-packet or ML-inference workload-shaped testbenches yet.
- No OpenLane/Vivado physical implementation or FPGA bring-up yet.
- The checker's throughput: when a packet's trailer merges into the final
  beat, the checker needs a 2-slot output skid queue and briefly stalls new
  input while draining it — a known, documented tradeoff, not a bug.
