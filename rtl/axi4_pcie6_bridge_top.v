`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// axi4_pcie6_bridge_top.v -- Master SARCATHON Top-Level Design
//
// Complete Synthesizable RTL Architecture:
// 1. Interconnect Layer:
//    - Dual 512-bit AXI4-Stream Inputs:
//        Source 0: Network Packet Processing (SmartNIC Ethernet Stream)
//        Source 1: ML Inference Accelerators (FPGA/ASIC Weight/Tensor Stream)
//    - Central Crossbar & Dynamic Packet-Locked Round-Robin Arbiter
//    - Decoupled Skid Buffers
//    - Emits: 512-bit Raw Internal Parallel Bus
//
// 2. Link Layer:
//    - Bundles data into fixed 256-Byte Flow Information Units (FLITs)
//    - Link CRC-32 (LCRC) calculation & insertion
//    - Forward Error Correction (FEC) SEC-DED syndrome generation
//    - Emits: System-Synchronous 256-bit Bus (8 beats per 256-Byte FLIT)
//
// 3. Protocol-to-PHY (PCIe Gen 6) Layer:
//    - Multi-lane striping (Lane 0 - Lane 3)
//    - Gray Coding & PAM4 Mapping (2 bits -> 1 Symbol)
//    - Emits: 4-lane parallel PAM4 symbol bus to Multi-Lane SerDes PHY
// -----------------------------------------------------------------------------

module axi4_pcie6_bridge_top #(
    parameter DATA_W = 512,
    parameter KEEP_W = DATA_W / 8
)(
    input  wire                 clk,
    input  wire                 rst,

    // =========================================================================
    // Source 0: Network Packet Processing (512-bit AXI4-Stream)
    // =========================================================================
    input  wire [DATA_W-1:0]    s0_axis_tdata,
    input  wire [KEEP_W-1:0]    s0_axis_tkeep,
    input  wire                 s0_axis_tvalid,
    input  wire                 s0_axis_tlast,
    output wire                 s0_axis_tready,

    // =========================================================================
    // Source 1: ML Inference Accelerator (512-bit AXI4-Stream)
    // =========================================================================
    input  wire [DATA_W-1:0]    s1_axis_tdata,
    input  wire [KEEP_W-1:0]    s1_axis_tkeep,
    input  wire                 s1_axis_tvalid,
    input  wire                 s1_axis_tlast,
    output wire                 s1_axis_tready,

    // =========================================================================
    // Protocol-to-PHY: 4-Lane Parallel PAM4 Symbol Bus (To Multi-Lane SerDes)
    // =========================================================================
    output wire [63:0]          phy_lane0_sym,  // Lane 0: 32 PAM4 symbols (2 bits each)
    output wire [63:0]          phy_lane1_sym,  // Lane 1: 32 PAM4 symbols (2 bits each)
    output wire [63:0]          phy_lane2_sym,  // Lane 2: 32 PAM4 symbols (2 bits each)
    output wire [63:0]          phy_lane3_sym,  // Lane 3: 32 PAM4 symbols (2 bits each)
    output wire                 phy_sym_valid,
    output wire                 phy_flit_start,
    output wire                 phy_flit_end,
    input  wire                 phy_ready
);

    // -------------------------------------------------------------------------
    // Internal Bus 1: Raw Internal Parallel Bus (512-bit)
    // -------------------------------------------------------------------------
    wire [DATA_W-1:0] raw_tdata;
    wire [KEEP_W-1:0] raw_tkeep;
    wire              raw_tvalid;
    wire              raw_tlast;
    wire              raw_tsrc;
    wire              raw_tready;

    // -------------------------------------------------------------------------
    // Layer 1: Interconnect Layer (Central Crossbar & Dynamic Arbiter)
    // -------------------------------------------------------------------------
    pcie6_crossbar_top #(
        .DATA_W(DATA_W),
        .KEEP_W(KEEP_W)
    ) u_crossbar (
        .clk           (clk),
        .rst           (rst),
        .s0_axis_tdata (s0_axis_tdata),
        .s0_axis_tkeep (s0_axis_tkeep),
        .s0_axis_tvalid(s0_axis_tvalid),
        .s0_axis_tlast (s0_axis_tlast),
        .s0_axis_tready(s0_axis_tready),
        .s1_axis_tdata (s1_axis_tdata),
        .s1_axis_tkeep (s1_axis_tkeep),
        .s1_axis_tvalid(s1_axis_tvalid),
        .s1_axis_tlast (s1_axis_tlast),
        .s1_axis_tready(s1_axis_tready),
        .m_raw_tdata   (raw_tdata),
        .m_raw_tkeep   (raw_tkeep),
        .m_raw_tvalid  (raw_tvalid),
        .m_raw_tlast   (raw_tlast),
        .m_raw_tsrc    (raw_tsrc),
        .m_raw_tready  (raw_tready)
    );

    // -------------------------------------------------------------------------
    // Internal Bus 2: System-Synchronous 256-bit Bus
    // -------------------------------------------------------------------------
    wire [255:0] flit_tdata;
    wire         flit_tvalid;
    wire         flit_tstart;
    wire         flit_tend;
    wire         flit_tready;

    // -------------------------------------------------------------------------
    // Layer 2: Link Layer (256-Byte FLIT Packetizer, CRC-32 & FEC)
    // -------------------------------------------------------------------------
    pcie6_link_layer #(
        .IN_DATA_W (512),
        .OUT_DATA_W(256)
    ) u_link_layer (
        .clk        (clk),
        .rst        (rst),
        .raw_tdata  (raw_tdata),
        .raw_tkeep  (raw_tkeep),
        .raw_tvalid (raw_tvalid),
        .raw_tlast  (raw_tlast),
        .raw_tsrc   (raw_tsrc),
        .raw_tready (raw_tready),
        .flit_tdata (flit_tdata),
        .flit_tvalid(flit_tvalid),
        .flit_tstart(flit_tstart),
        .flit_tend  (flit_tend),
        .flit_tready(flit_tready)
    );

    // -------------------------------------------------------------------------
    // Layer 3: Protocol-to-PHY Layer (Striping, Gray Coding & PAM4 Mapping)
    // -------------------------------------------------------------------------
    pcie6_protocol_to_phy u_protocol_to_phy (
        .clk           (clk),
        .rst           (rst),
        .flit_tdata    (flit_tdata),
        .flit_tvalid   (flit_tvalid),
        .flit_tstart   (flit_tstart),
        .flit_tend     (flit_tend),
        .flit_tready   (flit_tready),
        .phy_lane0_sym (phy_lane0_sym),
        .phy_lane1_sym (phy_lane1_sym),
        .phy_lane2_sym (phy_lane2_sym),
        .phy_lane3_sym (phy_lane3_sym),
        .phy_sym_valid (phy_sym_valid),
        .phy_flit_start(phy_flit_start),
        .phy_flit_end  (phy_flit_end),
        .phy_ready     (phy_ready)
    );

endmodule
