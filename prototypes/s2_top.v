`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// s2_top -- Stage 2 subsystem: NUM_SRC AXI4-Stream sources -> packet-locked
// round-robin arbiter -> register slice (decouples backpressure) ->
// CRC-32 framer (appends trailer) -> framed AXI4-Stream output.
// Width-parameterized (default 64-bit / 8 lanes; 32/128/256/512 also
// supported by the generated CRC engine).
// ---------------------------------------------------------------------------
module s2_top #(parameter DATA_W = 64, parameter NUM_SRC = 2) (
    input  wire                          clk,
    input  wire                          rst,

    input  wire [NUM_SRC*DATA_W-1:0]     s_tdata,
    input  wire [NUM_SRC*(DATA_W/8)-1:0] s_tkeep,
    input  wire [NUM_SRC-1:0]            s_tvalid,
    input  wire [NUM_SRC-1:0]            s_tlast,
    output wire [NUM_SRC-1:0]            s_tready,

    output wire [DATA_W-1:0]             m_tdata,
    output wire [DATA_W/8-1:0]           m_tkeep,
    output wire                          m_tvalid,
    output wire                          m_tlast,
    input  wire                          m_tready,

    output wire                          keep_err
);
    wire [DATA_W-1:0]   arb_tdata;
    wire [DATA_W/8-1:0] arb_tkeep;
    wire                arb_tvalid, arb_tlast, arb_tready;

    s2_axis_arbiter #(.DATA_W(DATA_W), .NUM_SRC(NUM_SRC)) u_arb (
        .clk(clk), .rst(rst),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid),
        .s_tlast(s_tlast), .s_tready(s_tready),
        .m_tdata(arb_tdata), .m_tkeep(arb_tkeep), .m_tvalid(arb_tvalid),
        .m_tlast(arb_tlast), .m_tready(arb_tready)
    );

    wire [DATA_W-1:0]   rs_tdata;
    wire [DATA_W/8-1:0] rs_tkeep;
    wire                rs_tvalid, rs_tlast, rs_tready;

    s2_axis_regslice #(.DATA_W(DATA_W)) u_rs (
        .clk(clk), .rst(rst),
        .s_tdata(arb_tdata), .s_tkeep(arb_tkeep), .s_tvalid(arb_tvalid),
        .s_tlast(arb_tlast), .s_tready(arb_tready),
        .m_tdata(rs_tdata), .m_tkeep(rs_tkeep), .m_tvalid(rs_tvalid),
        .m_tlast(rs_tlast), .m_tready(rs_tready)
    );

    s2_pkt_framer #(.DATA_W(DATA_W)) u_framer (
        .clk(clk), .rst(rst),
        .s_tdata(rs_tdata), .s_tkeep(rs_tkeep), .s_tvalid(rs_tvalid),
        .s_tlast(rs_tlast), .s_tready(rs_tready),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid),
        .m_tlast(m_tlast), .m_tready(m_tready),
        .keep_err(keep_err)
    );
endmodule
