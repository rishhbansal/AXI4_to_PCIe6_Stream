# AXI4-Stream to PCIe Gen 6 Protocol Bridge (RTL to GDSII)
### SARCATHON 2026 — Stage 1 & Stage 2 Complete Hardware Submission
[![Verilog](https://img.shields.io/badge/HDL-Verilog%20%2F%20SystemVerilog-blue.svg)](rtl/)
[![PDK](https://img.shields.io/badge/PDK-SkyWater%20130nm%20(sky130)-green.svg)](flow/)
[![Flow](https://img.shields.io/badge/Physical%20Design-OpenLane%20%2F%20OpenROAD-purple.svg)](flow/)
[![PCIe](https://img.shields.io/badge/PCIe-Gen%206%20(PAM4%20%2B%20256B%20FLIT)-orange.svg)](rtl/)
[![Regression](https://img.shields.io/badge/Regression-6%2F6%20Passed%20(100%25)-brightgreen.svg)](sim/)
[![DRC](https://img.shields.io/badge/Magic%20DRC-0%20Violations%20(Clean)-success.svg)](flow/reports/)
A synthesizable, high-throughput **AXI4-Stream to PCIe Gen 6 Protocol Bridge** designed from RTL specification down to a tapeout-clean **GDSII silicon layout**. 
The hardware targets high-speed data movement between on-chip accelerators and host server memory across two primary industry workloads:
1. **SmartNIC Network Packet Processing**: Continuous streams of Ethernet frames (64-byte runts to 9,000-byte Jumbo frames).
2. **Machine Learning Inference Accelerators**: High-throughput bursts of neural network weight vectors and feature map tensors.
---
## 🏛️ System Architecture
The architecture directly implements the 3-tier pipeline specified in the SARCATHON hardware specification:

  SmartNIC Network (512-bit)               ML Accelerator (512-bit)
   [s0_axis_tdata, tkeep, tvalid]         [s1_axis_tdata, tkeep, tvalid]
                 \                                      /
                  v                                    v
 +-------------------------------------------------------------------------+
 | LAYER 1: Interconnect Layer (pcie6_crossbar_top.v)                      |
 | - Packet-locked Dynamic Arbiter (Round-Robin, prevents interleaving)   |
 | - Decoupled 2-Slot Register Slice (Skid Buffer)                         |
 +-------------------------------------------------------------------------+
                                      |
                                      v  Raw Internal Parallel Bus (512-bit)
 +-------------------------------------------------------------------------+
 | LAYER 2: Link Layer (pcie6_link_layer.v, pcie6_fec.v)                   |
 | - Bundles data into fixed 256-Byte (2048-bit) Flow Information Units   |
 | - Single-Cycle Parallel CRC-32 Engine (GF(2) Matrix XOR Tree)           |
 | - Forward Error Correction (FEC) SEC-DED Hamming Matrix Engine          |
 +-------------------------------------------------------------------------+
                                      |
                                      v  System-Synchronous 256-bit Bus (8 beats/FLIT)
 +-------------------------------------------------------------------------+
 | LAYER 3: Protocol-to-PHY (PCIe Gen 6) Layer (pcie6_protocol_to_phy.v)   |
 | - Multi-Lane Striping: 32 bytes interleaved across Lane 0 - Lane 3      |
 | - Gray-Coded PAM4 Modulation: 2 bits -> 1 Symbol (-3, -1, +1, +3)       |
 +-------------------------------------------------------------------------+
                                      |
                                      v  4-Lane Parallel Symbol Bus (32 symbols/lane/clk)
                            [To Multi-Lane SerDes PHY]

### Architectural Breakdown
#### 1. Interconnect Layer (`pcie6_crossbar_top.v`)
- **Dual 512-bit AXI4-Stream Inputs**: Handles concurrent data streams from the Network controller and the ML engine.
- **Packet-Locked Dynamic Arbitration**: Naive beat-by-beat arbitration would interleave slices of different packets, corrupting downstream FLITs. The arbiter asserts a lock on packet start and holds grant until `TLAST && TREADY` complete, preserving packet atomicity.
- **2-Slot Skid Buffer (Register Slice)**: Eliminates combinational timing loops between upstream `s_tready` and downstream `m_tready`. If downstream stalls under backpressure, in-flight data safely absorbs into the second buffer slot without dropping throughput or inserting bubble cycles.
- **Output**: 512-bit Raw Internal Parallel Bus with source routing tags.
#### 2. Link Layer (`pcie6_link_layer.v` & `pcie6_fec.v`)
- **Fixed 256-Byte FLIT Packaging**: In accordance with the PCIe Gen 6 standard, packets are packaged into uniform 2048-bit (256-Byte) Flow Information Units (FLITs) over 4 beats ($4 \times 64\text{ B} = 256\text{ B}$).
- **Single-Cycle Parallel CRC-32**: Serial CRC requires 512 clock cycles per beat. Leveraging the linearity of CRC over Galois Field $\text{GF}(2)$, we implemented a static parallel XOR tree (depth $\le 6$ gates) that ingests all 64 bytes and updates the 32-bit CRC state on the exact same clock edge.
- **Forward Error Correction (FEC)**: PAM4 modulation carries a $-9.5\text{ dB}$ SNR penalty compared to NRZ, degrading raw BER. To prevent continuous retransmissions, we implemented an interleaved **SEC-DED (Single Error Correction, Double Error Detection)** Hamming matrix code to correct bit-flips in-flight.
- **Bus Width Conversion**: Serializes the 2048-bit FLIT onto a System-Synchronous 256-bit bus across 8 clock cycles.
#### 3. Protocol-to-PHY Layer (`pcie6_protocol_to_phy.v`)
- **Multi-Lane Striping**: Distributes the 256-bit bus round-robin across 4 physical SerDes lanes (8 bytes / 64 bits per lane per clock).
- **Gray-Coded PAM4 Mapping**: Maps 2-bit dibits to 4 voltage levels:
  $$\text{2'b00} \rightarrow \text{Level 0 } (-3\text{V}) \quad \vert \quad \text{2'b01} \rightarrow \text{Level 1 } (-1\text{V})$$
  $$\text{2'b11} \rightarrow \text{Level 2 } (+1\text{V}) \quad \vert \quad \text{2'b10} \rightarrow \text{Level 3 } (+3\text{V})$$
  Adjacent levels differ by only **1 bit** (Hamming distance = 1). An analog $\pm 1$ level shift due to channel noise causes at most a 1-bit error, ensuring it remains fully within the correction budget of the SEC-DED FEC engine.
#### 4. Closed-Loop Verification Subsystem (`pcie6_phy_to_protocol.v`, `pcie6_flit_depacketizer.v`)
- Serves as the golden reference receiver: performs Gray de-mapping, 4-lane de-striping, FLIT reassembly, real-time FEC syndrome decoding, in-flight single-bit repair, CRC verification, and AXI packet reconstruction.
---
## 🧪 Verification & Application Workloads
Verification was conducted via automated, self-checking SystemVerilog testbenches with scoreboarding and channel fault injection.
====================================================================== SARCATHON 2026: AXI4 <-> PCIe Gen 6 Complete Regression Suite

[*] Compiling: CRC-32 Golden Value Check... [PASS] CRC-32 Golden Value Check (IEEE 802.3 Check: 0xCBF43926)

[*] Compiling: Directed & Fault Loopback (51 cases)... [PASS] Directed & Fault Loopback (51 cases, 45 ok, 6 bad rejected)

[*] Compiling: Network Packet Workload (SmartNIC 64B-9000B)... [PASS] Network Packet Workload (SmartNIC 64B-9000B, 11478 B, 43 FLITs)

[*] Compiling: ML Inference Accelerator Workload (Tensor Bursts)... [PASS] ML Inference Accelerator Workload (Tensor Bursts, 7168 B, 28 FLITs)

[*] Compiling: Fault Tolerance, FEC & Reset Recovery... [PASS] Fault Tolerance, FEC & Reset Recovery (In-flight repair verified)

[*] Compiling: Full End-to-End Bridge Architecture Integration... [PASS] Full End-to-End Bridge Architecture Integration

====================================================================== REGRESSION SUMMARY: 6/6 Test Suites Passed (100.0%)


### Workload Details:
1. **SmartNIC Network Workload (`tb/tb_workload_network.v`)**:
   - Sweeps frame sizes across 64B (runt/ACK), 128B, 256B, 512B, 1518B (standard MTU), and **9,000B Jumbo frames**.
   - Verified zero packet corruption across 11,478 bytes (43 FLITs).
2. **ML Inference Workload (`tb/tb_workload_ml.v`)**:
   - High-bandwidth continuous streaming of INT8/FP16 tensor weight layers (1 KB, 2 KB, 4 KB bursts).
   - Injected **25% randomized downstream backpressure** stalls; verified zero buffer overflows or dropped beats across 7,168 bytes (28 FLITs).
3. **Channel Fault Tolerance (`tb/tb_fault_tolerance.v`)**:
   - Injected single-bit errors into active PAM4 symbol lanes $\rightarrow$ FEC detected syndrome, corrected the bit in-flight (`fec_corrected == 1`), and FLIT CRC passed with 0 payload loss.
   - Injected multi-bit fatal errors $\rightarrow$ flagged uncorrectable error (`fec_fatal == 1`) and rejected packet.
   - Triggered mid-stream asynchronous reset $\rightarrow$ verified clean recovery without state machine lockup.

---

## 🔬 Physical Design & Tapeout Results (OpenLane / SkyWater 130nm)

The top-level bridge (`axi4_pcie6_bridge_top`) was physically implemented through the complete RTL-to-GDSII flow using **OpenLane / OpenROAD** targeting the **SkyWater 130nm (`sky130_fd_sc_hd`)** standard cell library.

| Design Metric | Value | Significance |
|---|---|---|
| **Technology Node** | SkyWater 130nm (`sky130A`) | Open-source manufacturable foundry PDK |
| **Die Dimensions** | $1500 \times 1500\,\mu\text{m}$ ($2.25\text{ mm}^2$) | Absolute sizing providing $6,000\,\mu\text{m}$ perimeter |
| **Physical I/O Pins** | **1,420 pins** | Dual 512-bit data + keeps + SerDes lanes |
| **Core Area** | $1470 \times 1470\,\mu\text{m}$ ($0.303\text{ mm}^2$ logic) | Clean power ring margins |
| **Total Standard Cells** | **24,708 cells** | Gate-level logic mapping |
| **Sequential Flip-Flops**| **4,344 registers (`dfxtp_2`)** | 512-bit crossbar, FLIT buffer, pipeline stages |
| **Metal Routing Layers** | 5 Layers (`met1` to `met5`) | Detailed routing via TritonRoute |
| **Clock Tree Target** | Balanced H-Tree (TritonCTS) | Clock skew $< 100\text{ ps}$ |
| **Magic DRC Signoff** | **`COUNT: 0` (Clean)** | **Zero design rule violations** |
| **Final GDSII Size** | **90.01 MB** (`axi4_pcie6_bridge_top.gds`) | Tapeout-ready mask layout |

### Silicon Layout Preview (KLayout)
Open `axi4_pcie6_bridge_top.gds` in KLayout to inspect the full die:
- **Perimeter**: 1,420 physical I/O pads.
- **Outer Ring**: `VPWR` (1.8V) and `VGND` (0V) power distribution network (PDN).
- **Center**: Standard cell rows containing the 24,708 placed and routed logic cells.

---
## 🚀 How to Reproduce
### 1. Run Complete Simulation Regression
Requires Icarus Verilog (`iverilog`) and Python 3:
```bash
python scripts/run_all_tests.py
# End-to-end full integration testbench:
iverilog -g2005 -o sim/tb_bridge_complete.vvp rtl/*.v tb/tb_bridge_complete.v
vvp sim/tb_bridge_complete.vvp
# SmartNIC network packet workload:
iverilog -g2005 -o sim/tb_workload_network.vvp rtl/*.v tb/tb_workload_network.v
vvp sim/tb_workload_network.vvp
# ML inference tensor burst workload:
iverilog -g2005 -o sim/tb_workload_ml.vvp rtl/*.v tb/tb_workload_ml.v
vvp sim/tb_workload_ml.vvp
cd ~/OpenLane
# Interactive step-by-step or automated flow:
./flow.tcl -design /path/to/flow -config_file /path/to/flow/config.json -tag sarcathon_tapeout
klayout axi4_pcie6_bridge_top.gds

This can also be done using 15nm FinFETs as well.

Developed for the SARCATHON 2026 Semicon Hackathon (Student Alumni Relations Cell, IIT Bombay).
