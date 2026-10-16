`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// s2_axis_arbiter -- N-way round-robin AXI4-Stream arbiter, packet-locked
// (once a source is granted, it keeps the output until it drives TLAST,
// even if other sources request in between -- prevents interleaving beats
// from two different packets onto one output stream).
// Generalizes Stage 1's 2-to-1 arbiter to NUM_SRC sources.
// ---------------------------------------------------------------------------
module s2_axis_arbiter #(parameter DATA_W = 64, parameter NUM_SRC = 2) (
    input  wire                         clk,
    input  wire                         rst,

    input  wire [NUM_SRC*DATA_W-1:0]    s_tdata,
    input  wire [NUM_SRC*(DATA_W/8)-1:0] s_tkeep,
    input  wire [NUM_SRC-1:0]           s_tvalid,
    input  wire [NUM_SRC-1:0]           s_tlast,
    output wire [NUM_SRC-1:0]           s_tready,

    output reg  [DATA_W-1:0]            m_tdata,
    output reg  [DATA_W/8-1:0]          m_tkeep,
    output reg                          m_tvalid,
    output reg                          m_tlast,
    input  wire                         m_tready
);
    localparam KW = DATA_W/8;
    localparam LOGN = (NUM_SRC <= 1) ? 1 : $clog2(NUM_SRC);

    reg [LOGN-1:0] grant;      // currently selected source
    reg            locked;     // mid-packet: grant may not move

    wire [NUM_SRC-1:0] req = s_tvalid;

    // next round-robin candidate starting just after `grant`
    reg [LOGN-1:0] next_grant;
    integer gi;
    always @* begin
        next_grant = grant;
        for (gi = 1; gi <= NUM_SRC; gi = gi + 1)
            if (!locked && req[(grant + gi) % NUM_SRC] && next_grant == grant)
                next_grant = (grant + gi) % NUM_SRC;
    end

    // mux the selected source's beat onto the output combinationally
    reg [DATA_W-1:0] sel_data;
    reg [KW-1:0]     sel_keep;
    reg              sel_valid, sel_last;
    integer si;
    always @* begin
        sel_data = {DATA_W{1'b0}};
        sel_keep = {KW{1'b0}};
        sel_valid = 1'b0;
        sel_last  = 1'b0;
        for (si = 0; si < NUM_SRC; si = si + 1) begin
            if (si == grant) begin
                sel_data  = s_tdata [si*DATA_W +: DATA_W];
                sel_keep  = s_tkeep [si*KW     +: KW];
                sel_valid = s_tvalid[si];
                sel_last  = s_tlast [si];
            end
        end
    end

    wire [NUM_SRC-1:0] ready_vec_comb;
    genvar gv;
    generate
        for (gv = 0; gv < NUM_SRC; gv = gv + 1)
            assign ready_vec_comb[gv] = (gv == grant) ? m_tready : 1'b0;
    endgenerate
    assign s_tready = ready_vec_comb;

    always @(posedge clk) begin
        if (rst) begin
            grant    <= {LOGN{1'b0}};
            locked   <= 1'b0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
        end else begin
            if (sel_valid && m_tready) begin
                m_tdata  <= sel_data;
                m_tkeep  <= sel_keep;
                m_tvalid <= 1'b1;
                m_tlast  <= sel_last;
                if (sel_last) begin
                    locked <= 1'b0;
                    grant  <= next_grant;      // move on for the next packet
                end else begin
                    locked <= 1'b1;            // stay locked until TLAST
                end
            end else if (m_tready) begin
                m_tvalid <= 1'b0;
                if (!locked)
                    grant <= next_grant;       // free to rotate while idle
            end
        end
    end
endmodule
