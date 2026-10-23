import subprocess
import sys
import os

TESTS = [
    ("CRC-32 Golden Value Check", ["rtl/s2_crc32_gen.v", "tb/tb_crc_beat.v"], "sim/tb_crc_beat.vvp"),
    ("Directed & Fault Loopback (51 cases)", ["rtl/s2_crc32_gen.v", "prototypes/s2_pkt_framer.v", "prototypes/s2_pkt_checker.v", "tb/tb_loopback.v"], "sim/tb_loopback.vvp"),
    ("Network Packet Workload (SmartNIC 64B-9000B)", [
        "rtl/s2_crc32_gen.v", "rtl/s2_axis_regslice.v", "rtl/pcie6_fec.v",
        "rtl/pcie6_crossbar_top.v", "rtl/pcie6_link_layer.v", "rtl/pcie6_protocol_to_phy.v",
        "rtl/pcie6_phy_to_protocol.v", "rtl/pcie6_flit_depacketizer.v", "rtl/axi4_pcie6_bridge_top.v",
        "tb/tb_workload_network.v"
    ], "sim/tb_workload_network.vvp"),
    ("ML Inference Accelerator Workload (Tensor Bursts)", [
        "rtl/s2_crc32_gen.v", "rtl/s2_axis_regslice.v", "rtl/pcie6_fec.v",
        "rtl/pcie6_crossbar_top.v", "rtl/pcie6_link_layer.v", "rtl/pcie6_protocol_to_phy.v",
        "rtl/pcie6_phy_to_protocol.v", "rtl/pcie6_flit_depacketizer.v", "rtl/axi4_pcie6_bridge_top.v",
        "tb/tb_workload_ml.v"
    ], "sim/tb_workload_ml.vvp"),
    ("Fault Tolerance, FEC & Reset Recovery", [
        "rtl/s2_crc32_gen.v", "rtl/s2_axis_regslice.v", "rtl/pcie6_fec.v",
        "rtl/pcie6_crossbar_top.v", "rtl/pcie6_link_layer.v", "rtl/pcie6_protocol_to_phy.v",
        "rtl/pcie6_phy_to_protocol.v", "rtl/pcie6_flit_depacketizer.v", "rtl/axi4_pcie6_bridge_top.v",
        "tb/tb_fault_tolerance.v"
    ], "sim/tb_fault_tolerance.vvp"),
    ("Full End-to-End Bridge Architecture Integration", [
        "rtl/s2_crc32_gen.v", "rtl/s2_axis_regslice.v", "rtl/pcie6_fec.v",
        "rtl/pcie6_crossbar_top.v", "rtl/pcie6_link_layer.v", "rtl/pcie6_protocol_to_phy.v",
        "rtl/pcie6_phy_to_protocol.v", "rtl/pcie6_flit_depacketizer.v", "rtl/axi4_pcie6_bridge_top.v",
        "tb/tb_bridge_complete.v"
    ], "sim/tb_bridge_complete.vvp")
]

def main():
    print("=" * 70)
    print("  SARCATHON 2026: AXI4 <-> PCIe Gen 6 Complete Regression Suite")
    print("=" * 70)

    passed = 0
    total = len(TESTS)

    for name, sources, vvp_file in TESTS:
        print(f"\n[*] Compiling: {name}...")
        compile_cmd = ["iverilog", "-g2005", "-o", vvp_file] + sources
        res = subprocess.run(compile_cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"[FAIL] Compilation error for {name}:")
            print(res.stderr)
            continue

        print(f"[*] Running: {vvp_file}...")
        sim_res = subprocess.run(["vvp", vvp_file], capture_output=True, text=True)
        output = sim_res.stdout

        if "PASSED" in output and "FAILED" not in output and "ERROR" not in output:
            print(f"[PASS] {name}")
            passed += 1
        else:
            print(f"[FAIL] {name}")
            print(output)

    print("\n" + "=" * 70)
    print(f" REGRESSION SUMMARY: {passed}/{total} Test Suites Passed ({passed/total*100:.1f}%)")
    print("=" * 70)
    if passed == total:
        print(" >>> ALL VERIFICATION REQUIREMENTS SATISFIED <<< \n")
        return 0
    else:
        print(" >>> REGRESSION HAD FAILURES <<< \n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
