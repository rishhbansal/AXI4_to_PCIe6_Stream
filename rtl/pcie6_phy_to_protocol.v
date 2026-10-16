`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pcie6_phy_to_protocol.v -- PHY-to-Protocol Receiver (PCIe Gen 6)
//
// Complementary receiver to pcie6_protocol_to_phy:
// 1. Gray De-mapping & PAM4 to Dibit Conversion:
//    - Inverse of Gray code: recovers original 2 bits per symbol.
// 2. Multi-lane De-striping (Lane 0 - Lane 3):
//    - Re-assembles the 4 parallel 64-bit lane streams into the
//      System-Synchronous 256-bit Bus.
// -----------------------------------------------------------------------------

module pcie6_phy_to_protocol (
    input  wire         clk,
    input  wire         rst,

    // ---- 4-Lane Parallel Symbol Bus (from Analog PHY / SerDes) ----
    input  wire [63:0]  phy_lane0_sym,
    input  wire [63:0]  phy_lane1_sym,
    input  wire [63:0]  phy_lane2_sym,
    input  wire [63:0]  phy_lane3_sym,
    input  wire         phy_sym_valid,
    input  wire         phy_flit_start,
    input  wire         phy_flit_end,

    // ---- System-Synchronous 256-bit Bus (to Link Layer Rx) ----
    output reg  [255:0] flit_rx_data,
    output reg          flit_rx_valid,
    output reg          flit_rx_start,
    output reg          flit_rx_end
);

    // 1. Gray De-mapping function (PAM4 Symbol -> 2 bits):
    function [1:0] gray_pam4_to_bin;
        input [1:0] gray;
        begin
            case (gray)
                2'b00: gray_pam4_to_bin = 2'b00;
                2'b01: gray_pam4_to_bin = 2'b01;
                2'b10: gray_pam4_to_bin = 2'b11;
                2'b11: gray_pam4_to_bin = 2'b10;
            endcase
        end
    endfunction

    reg [63:0] lane0_bits;
    reg [63:0] lane1_bits;
    reg [63:0] lane2_bits;
    reg [63:0] lane3_bits;

    integer s;
    always @* begin
        for (s = 0; s < 32; s = s + 1) begin
            lane0_bits[s*2 +: 2] = gray_pam4_to_bin(phy_lane0_sym[s*2 +: 2]);
            lane1_bits[s*2 +: 2] = gray_pam4_to_bin(phy_lane1_sym[s*2 +: 2]);
            lane2_bits[s*2 +: 2] = gray_pam4_to_bin(phy_lane2_sym[s*2 +: 2]);
            lane3_bits[s*2 +: 2] = gray_pam4_to_bin(phy_lane3_sym[s*2 +: 2]);
        end
    end

    // 2. Multi-lane De-striping:
    // Recombine 4 lanes into 32 bytes (256 bits)
    reg [255:0] destriped_bus;
    integer b;
    always @* begin
        destriped_bus = 256'd0;
        for (b = 0; b < 8; b = b + 1) begin
            destriped_bus[(4*b + 0)*8 +: 8] = lane0_bits[b*8 +: 8];
            destriped_bus[(4*b + 1)*8 +: 8] = lane1_bits[b*8 +: 8];
            destriped_bus[(4*b + 2)*8 +: 8] = lane2_bits[b*8 +: 8];
            destriped_bus[(4*b + 3)*8 +: 8] = lane3_bits[b*8 +: 8];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            flit_rx_data  <= 256'd0;
            flit_rx_valid <= 1'b0;
            flit_rx_start <= 1'b0;
            flit_rx_end   <= 1'b0;
        end else begin
            flit_rx_valid <= phy_sym_valid;
            flit_rx_start <= phy_flit_start;
            flit_rx_end   <= phy_flit_end;
            flit_rx_data  <= destriped_bus;
        end
    end

endmodule
