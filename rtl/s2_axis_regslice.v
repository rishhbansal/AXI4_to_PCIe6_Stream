`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// s2_axis_regslice -- generic 2-slot AXI4-Stream skid buffer / register
// slice. Breaks a long combinational TREADY path by fully registering both
// data and the handshake, at the cost of one cycle of latency. Generalizes
// Stage 1's axi_skid_buffer to arbitrary DATA_W and adds TLAST.
// ---------------------------------------------------------------------------
module s2_axis_regslice #(parameter DATA_W = 64) (
    input  wire                 clk,
    input  wire                 rst,

    input  wire [DATA_W-1:0]    s_tdata,
    input  wire [DATA_W/8-1:0]  s_tkeep,
    input  wire                 s_tvalid,
    input  wire                 s_tlast,
    output wire                 s_tready,

    output reg  [DATA_W-1:0]    m_tdata,
    output reg  [DATA_W/8-1:0]  m_tkeep,
    output reg                  m_tvalid,
    output reg                  m_tlast,
    input  wire                 m_tready
);
    localparam KW = DATA_W/8;

    reg                skid_valid;
    reg [DATA_W-1:0]   skid_data;
    reg [KW-1:0]       skid_keep;
    reg                skid_last;

    // we can always accept a new beat unless both the output register and
    // the skid slot are occupied
    assign s_tready = !skid_valid;

    always @(posedge clk) begin
        if (rst) begin
            m_tvalid   <= 1'b0;
            m_tlast    <= 1'b0;
            skid_valid <= 1'b0;
        end else begin
            if (m_tready || !m_tvalid) begin
                if (skid_valid) begin
                    m_tdata    <= skid_data;
                    m_tkeep    <= skid_keep;
                    m_tlast    <= skid_last;
                    m_tvalid   <= 1'b1;
                    skid_valid <= 1'b0;
                end else begin
                    m_tdata  <= s_tdata;
                    m_tkeep  <= s_tkeep;
                    m_tlast  <= s_tlast;
                    m_tvalid <= s_tvalid;
                end
            end else if (s_tvalid && s_tready) begin
                // output stalled but a new beat arrived: park it in the skid slot
                skid_data  <= s_tdata;
                skid_keep  <= s_tkeep;
                skid_last  <= s_tlast;
                skid_valid <= 1'b1;
            end
        end
    end
endmodule
