`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pcie6_protocol_to_phy.v -- Protocol-to-PHY (PCIe Gen 6) Layer
//
// Performs:
// 1. Multi-lane striping (Lane 0 - Lane 3) across 4 SerDes lanes:
//    - Incoming 256-bit bus (32 bytes) is byte-interleaved across 4 lanes
//      (8 bytes = 64 bits per lane per cycle).
// 2. Gray Coding & PAM4 Mapping (2 bits -> 1 Symbol):
//    - Converts each 2-bit dibit into a Gray-coded PAM4 symbol:
//        Binary 2'b00 -> Gray 2'b00 (Symbol level 0: -3)
//        Binary 2'b01 -> Gray 2'b01 (Symbol level 1: -1)
//        Binary 2'b11 -> Gray 2'b10 (Symbol level 2: +1)
//        Binary 2'b10 -> Gray 2'b11 (Symbol level 3: +3)
//    - Each 64-bit lane yields 32 PAM4 symbols (64 bits symbol bus).
// 3. Emits 4-lane parallel symbol bus to analog PHY / Multi-Lane SerDes.
// -----------------------------------------------------------------------------

module pcie6_protocol_to_phy (
    input  wire         clk,
    input  wire         rst,

    // ---- System-Synchronous 256-bit Bus (from Link Layer) ----
    input  wire [255:0] flit_tdata,
    input  wire         flit_tvalid,
    input  wire         flit_tstart,
    input  wire         flit_tend,
    output wire         flit_tready,

    // ---- 4-Lane Parallel Symbol Bus (to Analog PHY / Multi-Lane SerDes) ----
    output reg  [63:0]  phy_lane0_sym,  // 32 PAM4 symbols (2-bit each) for Lane 0
    output reg  [63:0]  phy_lane1_sym,  // 32 PAM4 symbols (2-bit each) for Lane 1
    output reg  [63:0]  phy_lane2_sym,  // 32 PAM4 symbols (2-bit each) for Lane 2
    output reg  [63:0]  phy_lane3_sym,  // 32 PAM4 symbols (2-bit each) for Lane 3
    output reg          phy_sym_valid,
    output reg          phy_flit_start,
    output reg          phy_flit_end,
    input  wire         phy_ready
);

    // Flow control: ready when PHY is ready
    assign flit_tready = phy_ready;

    // 1. Multi-lane Striping:
    // 32 bytes striped round-robin across Lane 0..3:
    // Byte 0 -> L0, Byte 1 -> L1, Byte 2 -> L2, Byte 3 -> L3,
    // Byte 4 -> L0, Byte 5 -> L1, Byte 6 -> L2, Byte 7 -> L3, ...
    reg [63:0] lane0_raw_bits;
    reg [63:0] lane1_raw_bits;
    reg [63:0] lane2_raw_bits;
    reg [63:0] lane3_raw_bits;

    integer b;
    always @* begin
        lane0_raw_bits = 64'd0;
        lane1_raw_bits = 64'd0;
        lane2_raw_bits = 64'd0;
        lane3_raw_bits = 64'd0;
        for (b = 0; b < 8; b = b + 1) begin
            lane0_raw_bits[b*8 +: 8] = flit_tdata[(4*b + 0)*8 +: 8];
            lane1_raw_bits[b*8 +: 8] = flit_tdata[(4*b + 1)*8 +: 8];
            lane2_raw_bits[b*8 +: 8] = flit_tdata[(4*b + 2)*8 +: 8];
            lane3_raw_bits[b*8 +: 8] = flit_tdata[(4*b + 3)*8 +: 8];
        end
    end

    // 2. Gray Coding & PAM4 Mapping function (2 bits -> 1 PAM4 symbol):
    // Standard Gray mapping: G[1] = B[1], G[0] = B[1] ^ B[0]
    function [1:0] bin_to_gray_pam4;
        input [1:0] dibit;
        begin
            case (dibit)
                2'b00: bin_to_gray_pam4 = 2'b00; // Level 0 (-3)
                2'b01: bin_to_gray_pam4 = 2'b01; // Level 1 (-1)
                2'b11: bin_to_gray_pam4 = 2'b10; // Level 2 (+1)
                2'b10: bin_to_gray_pam4 = 2'b11; // Level 3 (+3)
            endcase
        end
    endfunction

    // Map each lane's 64 bits (32 dibits) into 32 PAM4 symbols
    reg [63:0] l0_sym_comb;
    reg [63:0] l1_sym_comb;
    reg [63:0] l2_sym_comb;
    reg [63:0] l3_sym_comb;

    integer s;
    always @* begin
        for (s = 0; s < 32; s = s + 1) begin
            l0_sym_comb[s*2 +: 2] = bin_to_gray_pam4(lane0_raw_bits[s*2 +: 2]);
            l1_sym_comb[s*2 +: 2] = bin_to_gray_pam4(lane1_raw_bits[s*2 +: 2]);
            l2_sym_comb[s*2 +: 2] = bin_to_gray_pam4(lane2_raw_bits[s*2 +: 2]);
            l3_sym_comb[s*2 +: 2] = bin_to_gray_pam4(lane3_raw_bits[s*2 +: 2]);
        end
    end

    // Output registers for high-speed PHY interface
    always @(posedge clk) begin
        if (rst) begin
            phy_lane0_sym  <= 64'd0;
            phy_lane1_sym  <= 64'd0;
            phy_lane2_sym  <= 64'd0;
            phy_lane3_sym  <= 64'd0;
            phy_sym_valid  <= 1'b0;
            phy_flit_start <= 1'b0;
            phy_flit_end   <= 1'b0;
        end else if (phy_ready) begin
            phy_sym_valid  <= flit_tvalid;
            phy_flit_start <= flit_tstart;
            phy_flit_end   <= flit_tend;
            if (flit_tvalid) begin
                phy_lane0_sym <= l0_sym_comb;
                phy_lane1_sym <= l1_sym_comb;
                phy_lane2_sym <= l2_sym_comb;
                phy_lane3_sym <= l3_sym_comb;
            end
        end
    end

endmodule
