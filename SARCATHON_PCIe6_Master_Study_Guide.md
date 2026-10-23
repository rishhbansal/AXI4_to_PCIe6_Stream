# SARCATHON 2026: AXI4-Stream to PCIe Gen 6 Bridge
## The Ultimate Technical & Interview Master Guide: From RTL to GDSII

*(A copy of this file is also located in `SARCATHON_Stage2_WIP/SARCATHON_PCIe6_Master_Study_Guide.md`)*

---

## 1. The Big Picture: What is this Project, Really?

Imagine an **autonomous AI server**:
- **Inside the processor chip**, there are accelerators: a **SmartNIC** receiving internet packets, and an **AI Tensor Engine** calculating matrix multiplications. Inside the chip, they speak a protocol called **AXI4-Stream**—it is like an internal, super-wide 512-lane private hallway.
- **Outside the chip**, across the motherboard, is the main server memory (DRAM). To send data across motherboards and cables at high speed, computers use **PCIe Gen 6**—it is like a high-speed interstate railway.

### So, what did you build?
You built the **Bridge (the International Cargo Terminal)** between the internal AXI hallway and the external PCIe railway:
1. It takes two separate 512-bit internal streams (Network and AI).
2. It arbitrates fairly between them without mixing up their data.
3. It packages their data into standard **fixed 256-Byte PCIe Gen 6 FLIT containers**.
4. It attaches a **32-bit CRC checksum** (tamper-proof seal) and **FEC parity bits** (self-healing error correction).
5. It stripes the data across 4 physical lanes and converts binary bits into **4-level PAM4 voltage symbols** using **Gray coding**.
6. Finally, you turned this code into physical copper wires and transistors (**GDSII layout**) on a real silicon node (SkyWater 130nm) with **0 manufacturing violations (DRC clean)**!

---

## 2. Deep Explanations for Your 3 Questions

### For Q1: "How does beat interleaving create an error, what is a continuous block, and is AXI4 to PCIe 6 like a bus only?"

#### A. Is AXI4 to PCIe 6 just a "bus"?
Not quite! 
- **AXI4** is an **on-chip parallel bus** (hundreds of parallel wires etched into silicon, connecting CPU cores, DMA, and memory inside a single chip).
- **PCIe 6** is a **board-level serial link** (a small number of high-speed differential copper pairs running between different chips, expansion cards, and motherboards).
- Your design is a **Protocol Bridge / Adapter**: it converts a parallel on-chip bus protocol (AXI-Stream) into an encoded, packetized serial protocol (PCIe 6 FLITs).

#### B. What is a "continuous block" vs. "beat interleaving"?
In AXI4-Stream, data travels in clock-by-clock slices called **beats**. A complete packet (like a 256-Byte Ethernet frame) takes 4 beats of 512 bits:
- **Beat 0**: First 64 bytes
- **Beat 1**: Next 64 bytes
- **Beat 2**: Next 64 bytes
- **Beat 3**: Final 64 bytes (with signal `TLAST = 1` indicating end-of-packet)

Now, imagine two active senders: **Source 0 (SmartNIC Ethernet packet)** and **Source 1 (AI neural network weights)**.

**If you used naive beat-by-beat interleaving:**
```
Cycle 1: Source 0 sends Beat 0  --> [Ethernet Header]
Cycle 2: Source 1 sends Beat 0  --> [AI Weight Matrix 0]   <-- INTERLEAVED!
Cycle 3: Source 0 sends Beat 1  --> [Ethernet IP Data]
Cycle 4: Source 1 sends Beat 1  --> [AI Weight Matrix 1]
```
The downstream Link Layer takes these 4 beats and bundles them into **one single 256-Byte PCIe FLIT**. 

**Why this is a fatal catastrophe:**
1. **Garbage Payload**: The host server receives a single FLIT that contains half an Ethernet header and half an AI weight matrix glued together!
2. **Checksum Failure**: The PCIe CRC checksum checks the entire 256-Byte FLIT. The receiver unpacks it, sees nonsense, and flags a fatal protocol violation.
3. **Software Crash**: The server's network driver gets AI numbers instead of web packets, and the AI model gets network bytes instead of floating-point weights.

**Why "Packet-Locked" Arbitration fixes this:**
Once Source 0 starts transmitting, the arbiter sets a lock register (`locked <= 1'b1`). It **refuses** to grant Source 1 until Source 0 finishes its complete packet on `TLAST = 1`. This guarantees the FLIT contains a **continuous, unbroken block** of data belonging to a single transaction.

---

### For Q2: "What is throughput and bubble cycles? How does the skid buffer work with s_ready and m_ready?"

#### A. What are Throughput and Bubble Cycles?
- **Throughput**: The actual amount of useful data your hardware moves per second (e.g., $64\text{ Gigabytes/sec}$).
- **Bubble Cycle**: A wasted clock cycle where the hardware is powered on, but **no work is done** because the pipeline is stalled waiting for data or waiting for a handshake (`TVALID = 0` or `TREADY = 0`). A bubble cycle is dead time that reduces throughput.

#### B. Understanding `s_tready` vs. `m_tready`:
In an AXI module:
- **`s_` (Slave / Upstream)**: The input side of your module. `s_tready` is an **OUTPUT** from your module telling the sender: *"I am ready to accept your data."*
- **`m_` (Master / Downstream)**: The output side of your module. `m_tready` is an **INPUT** from the downstream receiver telling your module: *"I am ready to accept your data."*

```
   [Upstream Sender]                 [Your Skid Buffer]                  [Downstream Receiver]
          |                                  |                                     |
    s_tdata (512-bit) -----------------> [Reg A / Reg B] ------------------> m_tdata (512-bit)
    s_tvalid (Valid)  ----------------->               --------------------> m_tvalid (Valid)
    s_tready (Ready)  <----------------- [Local State] <-------------------- m_tready (Ready)
```

#### C. The Skid Buffer Problem & Solution:
Suppose downstream suddenly gets busy and drops `m_tready = 0` (**backpressure**).
- **If you only had a 1-stage register**: 
  When `m_tready` goes low, you must immediately tell the upstream sender to stop. But because of clock register delays, the upstream sender **has already sent one more beat on that clock edge**!
  With only 1 register, where do you put that extra in-flight beat? You have no room! You either drop it (data corruption) or you have to connect `s_tready` directly to `m_tready` with raw combinational logic. But connecting ready signals directly across modules creates a **long combinational timing path** that drastically slows down your maximum clock speed ($F_{\max}$).
- **How the 2-Slot Skid Buffer solves this**:
  - **Slot A (Main Register)**: Holds the current beat being sent downstream.
  - **Slot B (The Skid Slot)**: An emergency holding bay! If `m_tready` suddenly goes to 0, the extra in-flight beat "skids" safely into Slot B.
  - Your module can drive `s_tready` purely from its own local registers (`assign s_tready = !skid_valid`). 
  - This **breaks the long combinational timing chain** across the chip while guaranteeing **zero dropped data and zero wasted bubble cycles**.

---

### For Q5: "What if in Gray coding as well the noise flipped both bits? Is that possible, and what happens?"

#### A. Is it possible for noise to flip 2 bits in Gray coding?
**Yes, it is physically possible, but statistically much rarer.**
- In PAM4, there are 4 voltage levels:
  - Level 0: $-3\text{V}$ (`2'b00`)
  - Level 1: $-1\text{V}$ (`2'b01`)
  - Level 2: $+1\text{V}$ (`2'b11`)
  - Level 3: $+3\text{V}$ (`2'b10`)
- **Single-step noise ($\Delta V = 2\text{V}$)**: Noise pushing Level 0 to Level 1, or Level 1 to Level 2. Because of Gray coding, this only flips **1 bit**.
- **Double-step noise ($\Delta V = 4\text{V}$)**: A massive electrical spike pushing Level 0 ($-3\text{V}$, `00`) all the way past Level 1 into Level 2 ($+1\text{V}$, `11`). In this case, **both bits flip**!
- In real channels, small noise is thousands of times more likely than a giant 4-Volt spike.

#### B. What happens when a 2-bit flip occurs?
This is why our architecture uses **SEC-DED (Single Error Correction, Double Error Detection)** Hamming codes:
1. **Single-bit flip**: The receiver's syndrome decoder calculates the exact flipped bit index and **fixes it in real time** (`fec_corrected = 1`). The packet is saved without any retransmission.
2. **Two-bit flip**: The decoder detects that the parity relationships are broken but cannot uniquely pinpoint which two bits are wrong. Instead of guessing (which would corrupt data), it asserts **`fec_fatal = 1`**.
3. When `fec_fatal` fires, the FLIT's **CRC checksum fails**. The receiver drops the corrupt packet and PCIe initiates a clean link-layer **Replay / Retransmission** request.
4. **Result**: The system is completely protected from **silent data corruption (SDC)**.

---

## 3. The 3 Architectural Layers Summary

| Layer | Module Name | Primary Responsibilities | Key Signals |
|---|---|---|---|
| **Layer 1: Interconnect** | `pcie6_crossbar_top.v` | Multi-source arbitration, packet-locked fair scheduling, backpressure decoupling via 2-slot skid buffer. | `s0_axis_*`, `s1_axis_*`, `m_raw_tdata[511:0]` |
| **Layer 2: Link Layer** | `pcie6_link_layer.v`<br>`pcie6_fec.v` | Bundles 4 beats of 512 bits into 256-Byte FLITs; computes single-cycle parallel CRC-32 (`0xEDB88320`); computes SEC-DED FEC parity; serializes to 256-bit bus (8 beats). | `flit_tdata[255:0]`, `flit_tstart`, `flit_tend` |
| **Layer 3: Protocol-to-PHY** | `pcie6_protocol_to_phy.v` | 4-lane byte-interleaved striping (8 bytes/lane/cycle); Gray-coded PAM4 symbol mapping (2 bits $\rightarrow$ 1 symbol, levels $-3,-1,+1,+3$). | `phy_lane0_sym[63:0]` to `phy_lane3_sym[63:0]` |

---

## 4. Key Terminology Cheat Sheet (Know These for Interviews)

- **AXI4-Stream**: An ARM-standardized point-to-point on-chip streaming protocol using unidirectional handshake signals (`TVALID`, `TREADY`, `TDATA`, `TKEEP`, `TLAST`).
- **Beat**: One clock cycle of data transfer across an AXI bus.
- **Backpressure**: When a downstream receiver is full and forces upstream senders to halt by dropping `TREADY = 0`.
- **Bubble Cycle**: An idle, wasted clock cycle where no data is transferred, decreasing throughput.
- **FLIT (Flow Information Unit)**: A standardized, fixed-size data container introduced in PCIe Gen 6 (exactly 256 Bytes = 2048 bits).
- **Galois Field $\text{GF}(2)$**: Binary arithmetic where addition is equivalent to XOR ($\oplus$) and multiplication is equivalent to AND ($\land$). Allows parallel CRC computation in 1 cycle.
- **CRC-32 (Cyclic Redundancy Check)**: A 32-bit mathematical hash appended to packets to detect data corruption with high probability.
- **PAM4 (Pulse Amplitude Modulation 4-Level)**: An analog modulation scheme carrying 2 bits per symbol across 4 voltage levels ($-3\text{V}, -1\text{V}, +1\text{V}, +3\text{V}$).
- **Gray Coding**: A binary encoding where adjacent numbers differ by only 1 bit. In PAM4, this prevents a single analog level misread from becoming a multi-bit burst error.
- **FEC (Forward Error Correction)**: Mathematical parity encoding that allows a receiver to detect and automatically correct bit errors in-flight without retransmission.
- **SEC-DED**: Single Error Correction, Double Error Detection (Hamming matrix code).
- **GDSII (`.gds`)**: The standard industry file format containing the geometric polygon shapes representing transistor gates, contacts, and metal routing wires for chip manufacturing.
- **DRC (Design Rule Check)**: Physical verification verifying that geometric shapes respect minimum spacing and width rules of the foundry (Your result: **`COUNT: 0`**).
- **LVS (Layout Versus Schematic)**: Verification proving that the physical GDSII layout matches the gate-level electrical netlist 100%.
- **CTS (Clock Tree Synthesis)**: Building a balanced tree of buffers to distribute the clock signal to all flip-flops simultaneously with minimal skew.

---

## 5. The 7 Core Interview Questions & Model Answers

### Q1: Why use packet-locked dynamic round-robin arbitration?
- **Answer**: In AXI4-Stream, packets span multiple beats ending in `TLAST`. Naive round-robin interleaves beats from different sources on alternate cycles, which would blend Ethernet packets and AI tensors into an invalid hybrid payload. Packet locking holds the grant until `TLAST` completes, guaranteeing packet atomicity and preventing downstream FLIT CRC corruption.

### Q2: Why use a 2-slot skid buffer instead of a single register?
- **Answer**: A 1-stage register cannot absorb an in-flight beat when downstream deasserts `m_tready` without combinational feedback. A 2-slot skid buffer provides an emergency holding bay (Slot B) for in-flight beats during sudden backpressure. This cuts long combinational timing paths between upstream and downstream ready signals while maintaining 100% throughput with zero bubble cycles.

### Q3: How do you compute CRC-32 over a 512-bit bus in a single clock cycle?
- **Answer**: Serial CRC takes 512 clock cycles, creating an unacceptable bottleneck. Because CRC is linear over $\text{GF}(2)$, shifting data through an LFSR can be modeled as matrix multiplication. In hardware, this collapses the 512 shift steps into a static parallel XOR tree with logic depth $\approx \log_2(\text{terms}) \le 6$ gates, allowing all 64 bytes to be processed combinationally on the same clock edge.

### Q4: Why did PCIe Gen 6 transition to fixed 256-Byte FLITs and mandatory FEC?
- **Answer**: PCIe Gen 6 uses PAM4 modulation, which reduces the voltage eye height by $\approx \frac{1}{3}$, causing the raw Bit Error Rate to increase from $10^{-12}$ to $10^{-6}$. Retransmission alone would saturate the link with replays. Mandatory FEC corrects errors in real time, and fixed 256-Byte FLITs provide the required constant-length mathematical block size for low-latency parity calculation.

### Q5: Why is Gray coding essential before PAM4 symbol mapping?
- **Answer**: In PAM4, analog noise most commonly causes a voltage level to be misread as its adjacent neighbor ($\pm 1$ level). Gray coding ensures adjacent levels differ by exactly 1 bit. An adjacent symbol misread results in only a 1-bit error instead of a 2-bit error, keeping the corruption within the repair capability of our SEC-DED FEC engine.

### Q6: How were the Network and ML workloads verified?
- **Answer**: Using dedicated SystemVerilog testbenches:
  - *Network Workload*: Swept frame sizes across the full Ethernet spectrum from 64-byte runts, 128B, 512B, 1,518B standard MTU, to 9,000-byte Jumbo frames (11,478 bytes total across 43 FLITs).
  - *ML Workload*: Streamed continuous, dense tensor weight bursts (1 KB, 2 KB, 4 KB) under 25% randomized host memory backpressure stalls (28 FLITs, 7,168 bytes).
  - A golden scoreboard verified zero dropped bytes, zero duplicate bytes, and zero CRC errors.

### Q7: How did you diagnose and resolve the floorplanning I/O pin error?
- **Answer**: With dual 512-bit AXI interfaces, byte enables, and SerDes buses, the bridge has 1,420 I/O pins. OpenROAD's `ioplacer` failed with `[PPL-0024]` because the initial $930 \times 930\,\mu\text{m}$ die perimeter only provided 1,148 legal pin slots. I resolved this by switching to absolute floorplanning (`FP_SIZING: absolute`), setting die dimensions to $1500 \times 1500\,\mu\text{m}$ ($6,000\,\mu\text{m}$ perimeter), which provided over 2,200 legal pin slots. Physical design completed with 0 DRC violations on SkyWater 130nm.

---

## 6. Target Migration: Porting from SkyWater 130nm to 15nm FinFET

| Metric | SkyWater 130nm (`sky130`) | FreePDK15 / Nangate 15nm (`nangate15`) | Why the Difference? |
|---|---|---|---|
| **Transistor Type** | Planar Bulk CMOS | 3D FinFET | FinFET gates wrap around 3 sides of the channel for ultra-low leakage. |
| **Clock Frequency** | $100\text{ MHz}$ ($10.0\text{ ns}$) | **$\ge 667\text{ MHz} - 1\text{ GHz}$ ($1.0\text{ ns}$)** | 15nm gate delays are $\sim 15\text{ ps}$ (over $10\times$ faster than 130nm). |
| **Logic Cell Area** | $303,494\,\mu\text{m}^2$ ($0.30\text{ mm}^2$) | **$\approx 8,500\,\mu\text{m}^2$** | Standard cell pitch shrinks by $>35\times$. |
| **Die Dimensions** | $1500 \times 1500\,\mu\text{m}$ | **$250 \times 250\,\mu\text{m}$** | Massive silicon area savings. |
| **Operating Voltage**| $1.8\text{ V}$ | **$0.75\text{ V} - 0.8\text{ V}$** | Lower supply voltage reduces dynamic power ($P \propto C V^2 f$). |
| **RTL Code Changes**| **0 Lines** | **0 Lines** | Synthesizable RTL is completely technology-independent. |

---

## 7. LinkedIn Strategy: Should You Post It? (YES!)

### Why this is a goldmine for your profile:
1. **RTL-to-GDSII is Rare**: 95% of students only write basic Verilog and stop at simulation. Showing a **real GDSII layout** with **zero DRC errors** places you in the top 5% of candidate profiles.
2. **Industry Protocols**: Interviewers at Qualcomm, NVIDIA, Intel, and Apple look specifically for **AXI4** and **PCIe Gen 6** experience.
3. **Hardware + Physical Signoff**: You demonstrate competence across both digital logic architecture and physical EDA tool flows.

### Exact Checklist for Your Post:
- [ ] **Attach Image 1**: The full-die KLayout screenshot showing the green power ring and 1,420 I/O pads around the border.
- [ ] **Attach Image 2**: A zoomed-in screenshot from KLayout showing the standard cell rows and metal routing wires.
- [ ] **Copy & Paste the LinkedIn Post template** provided in the master guide.
- [ ] **Tag Relevant Entities**: Tag `#SARCATHON2026`, your university/IIT Indore, and use hashtags `#ASIC #VLSI #PhysicalDesign #PCIe #Semiconductor`.
