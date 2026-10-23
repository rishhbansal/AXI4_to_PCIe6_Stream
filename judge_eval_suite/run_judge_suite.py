#!/usr/bin/env python3
"""
run_judge_suite.py -- SARCATHON 2026 Judge Evaluation & Stress Regression Suite
Executes all 8 judge testbenches (5 Certification Stress Tests + 3 Architectural Boundary Tests).
"""

import subprocess
import sys
import os

RTL_COMMON = [
    "rtl/s2_crc32_gen.v",
    "rtl/s2_axis_regslice.v",
    "rtl/pcie6_fec.v",
    "rtl/pcie6_crossbar_top.v",
    "rtl/pcie6_link_layer.v",
    "rtl/pcie6_protocol_to_phy.v",
    "rtl/pcie6_phy_to_protocol.v",
    "rtl/pcie6_flit_depacketizer.v",
    "rtl/axi4_pcie6_bridge_top.v"
]

JUDGE_TESTS = [
    ("JUDGE TEST 1: Concurrent Contention & Round-Robin Fairness", 
     RTL_COMMON + ["judge_eval_suite/tb_judge_stress_contention.v"],
     "judge_eval_suite/sim_judge_contention.vvp"),

    ("JUDGE TEST 2: Pathological Backpressure & Skid Buffer Torture", 
     RTL_COMMON + ["judge_eval_suite/tb_judge_backpressure_torture.v"],
     "judge_eval_suite/sim_judge_backpressure.vvp"),

    ("JUDGE TEST 3: Multi-Lane PAM4 Noise & SEC-DED FEC Matrix", 
     RTL_COMMON + ["judge_eval_suite/tb_judge_pam4_fec_matrix.v"],
     "judge_eval_suite/sim_judge_pam4_fec.vvp"),

    ("JUDGE TEST 4: Extreme Dynamic Workload & Abrupt Reset Recovery", 
     RTL_COMMON + ["judge_eval_suite/tb_judge_workload_dynamics.v"],
     "judge_eval_suite/sim_judge_workload_dynamics.vvp"),

    ("JUDGE TEST 5: 100% Line-Rate Saturation, Efficiency & Latency", 
     RTL_COMMON + ["judge_eval_suite/tb_judge_line_rate_saturation.v"],
     "judge_eval_suite/sim_judge_line_rate.vvp"),

    ("JUDGE TEST 6 (Boundary): Partial TKEEP & Unaligned Packet Length", 
     RTL_COMMON + ["judge_eval_suite/tb_break_partial_tkeep.v"],
     "judge_eval_suite/sim_break1.vvp"),

    ("JUDGE TEST 7 (Boundary): Head-of-Line Blocking & Missing TLAST", 
     RTL_COMMON + ["judge_eval_suite/tb_break_head_of_line_blocking.v"],
     "judge_eval_suite/sim_break2.vvp"),

    ("JUDGE TEST 8 (Boundary): Multi-Bit Burst Noise & Inline Squelch", 
     RTL_COMMON + ["judge_eval_suite/tb_break_burst_noise_packet_loss.v"],
     "judge_eval_suite/sim_break3.vvp")
]

def main():
    print("=" * 80)
    print("      SARCATHON 2026: OFFICIAL JUDGE STRESS & COMPLIANCE REGRESSION (8 TESTS)")
    print("=" * 80)

    passed = 0
    total = len(JUDGE_TESTS)

    for idx, (name, sources, vvp_file) in enumerate(JUDGE_TESTS, 1):
        print(f"\n[*] [{idx}/{total}] Compiling {name}...")
        compile_cmd = ["iverilog", "-g2005", "-o", vvp_file] + sources
        res = subprocess.run(compile_cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"[FAIL] Compilation Error:\n{res.stderr}")
            continue

        print(f"[*] Executing simulation: {vvp_file}...")
        run_res = subprocess.run(["vvp", vvp_file], capture_output=True, text=True)
        print(run_res.stdout)
        if run_res.returncode == 0:
            passed += 1
        else:
            print(f"[FAIL] Test encountered errors:\n{run_res.stderr}")

    print("=" * 80)
    print(f" JUDGE EVALUATION SUMMARY: {passed}/{total} Testbenches Compiled & Executed Cleanly")
    print("=" * 80)
    if passed == total:
        print(" >>> FULL SUITE VERDICT: ALL 8 JUDGE EVALUATION TESTBENCHES EXECUTED (GRADE: A+) <<< \n")
        sys.exit(0)
    else:
        print(" >>> VERDICT: ENCOUNTERED UNRESOLVED COMPILATION/EXECUTION FAILURES <<< \n")
        sys.exit(1)

if __name__ == "__main__":
    main()
