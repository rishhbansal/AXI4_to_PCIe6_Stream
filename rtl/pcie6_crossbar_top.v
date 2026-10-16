`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pcie6_crossbar_top.v -- Interconnect Layer: Central Crossbar & Dynamic Arbiter
//
// Bridges two 512-bit AXI4-Stream input interfaces:
//   Source 0: Network Packet Processing (SmartNIC continuous Ethernet packet stream)
//   Source 1: Machine Learning Inference Accelerator (neural network weights / tensor stream)
//
// Features:
// - Packet-locked dynamic round-robin arbitration (atomic packet transfers).
// - Preserves stream integrity (no interleaved beats from different sources).
// - Decoupled 2-slot skid buffer (register slice) to cut combinatorial paths.
// - Emits a unified 512-bit Raw Internal Parallel Bus with source tagging.
// -----------------------------------------------------------------------------

module pcie6_crossbar_top #(
    parameter DATA_W = 512,
    parameter KEEP_W = DATA_W / 8
)(
    input  wire                 clk,
    input  wire                 rst,

    // ---- Source 0: Network Packet Processing ----
    input  wire [DATA_W-1:0]    s0_axis_tdata,
    input  wire [KEEP_W-1:0]    s0_axis_tkeep,
    input  wire                 s0_axis_tvalid,
    input  wire                 s0_axis_tlast,
    output wire                 s0_axis_tready,

    // ---- Source 1: ML Inference Accelerator ----
    input  wire [DATA_W-1:0]    s1_axis_tdata,
    input  wire [KEEP_W-1:0]    s1_axis_tkeep,
    input  wire                 s1_axis_tvalid,
    input  wire                 s1_axis_tlast,
    output wire                 s1_axis_tready,

    // ---- Raw Internal Parallel Bus (to Link Layer) ----
    output wire [DATA_W-1:0]    m_raw_tdata,
    output wire [KEEP_W-1:0]    m_raw_tkeep,
    output wire                 m_raw_tvalid,
    output wire                 m_raw_tlast,
    output wire                 m_raw_tsrc,     // 0=Network, 1=ML
    input  wire                 m_raw_tready
);

    reg grant;   // 0 = Source 0, 1 = Source 1
    reg locked;  // 1 = locked to current source mid-packet

    wire req0 = s0_axis_tvalid;
    wire req1 = s1_axis_tvalid;

    // Next round-robin candidate
    wire next_grant = (!locked) ? ((grant == 1'b0) ? (req1 ? 1'b1 : 1'b0) :
                                                     (req0 ? 1'b0 : 1'b1)) : grant;

    // Selected source mux
    wire [DATA_W-1:0] sel_tdata  = (grant == 1'b0) ? s0_axis_tdata  : s1_axis_tdata;
    wire [KEEP_W-1:0] sel_tkeep  = (grant == 1'b0) ? s0_axis_tkeep  : s1_axis_tkeep;
    wire              sel_tvalid = (grant == 1'b0) ? s0_axis_tvalid : s1_axis_tvalid;
    wire              sel_tlast  = (grant == 1'b0) ? s0_axis_tlast  : s1_axis_tlast;
    wire              sel_tsrc   = grant;

    // Internal bus between arbiter and register slice
    reg  [DATA_W-1:0] arb_tdata;
    reg  [KEEP_W-1:0] arb_tkeep;
    reg               arb_tvalid;
    reg               arb_tlast;
    reg               arb_tsrc;
    wire              arb_tready;

    // Assign ready strictly to the granted source
    assign s0_axis_tready = (grant == 1'b0) ? arb_tready : 1'b0;
    assign s1_axis_tready = (grant == 1'b1) ? arb_tready : 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            grant      <= 1'b0;
            locked     <= 1'b0;
            arb_tdata  <= {DATA_W{1'b0}};
            arb_tkeep  <= {KEEP_W{1'b0}};
            arb_tvalid <= 1'b0;
            arb_tlast  <= 1'b0;
            arb_tsrc   <= 1'b0;
        end else begin
            if (sel_tvalid && arb_tready) begin
                arb_tdata  <= sel_tdata;
                arb_tkeep  <= sel_tkeep;
                arb_tvalid <= 1'b1;
                arb_tlast  <= sel_tlast;
                arb_tsrc   <= sel_tsrc;

                if (sel_tlast) begin
                    locked <= 1'b0;
                    grant  <= next_grant;
                end else begin
                    locked <= 1'b1;
                end
            end else if (arb_tready) begin
                arb_tvalid <= 1'b0;
                if (!locked) begin
                    grant <= next_grant;
                end
            end
        end
    end

    // Decoupled 2-slot Skid Buffer (Register Slice)
    s2_axis_regslice #(
        .DATA_W(DATA_W + 1) // DATA_W + TSRC
    ) u_regslice (
        .clk     (clk),
        .rst     (rst),
        .s_tdata ({arb_tsrc, arb_tdata}),
        .s_tkeep (arb_tkeep),
        .s_tvalid(arb_tvalid),
        .s_tlast (arb_tlast),
        .s_tready(arb_tready),
        .m_tdata ({m_raw_tsrc, m_raw_tdata}),
        .m_tkeep (m_raw_tkeep),
        .m_tvalid(m_raw_tvalid),
        .m_tlast (m_raw_tlast),
        .m_tready(m_raw_tready)
    );

endmodule
