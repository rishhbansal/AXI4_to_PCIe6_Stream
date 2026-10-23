`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// s2_pkt_framer -- appends a 4-byte CRC-32/802.3 trailer to an AXI4-Stream
// packet (a run of beats ending in TLAST), width-parameterized.
//
// Trailer placement rule:
//   let n = number of valid bytes (popcount of TKEEP) on the TLAST beat,
//   N = DATA_W/8 total lanes.
//     n + 4 <= N : trailer MERGED into the same beat (no extra cycle)
//     n + 4 >  N : original last beat forwarded unchanged (TLAST deasserted),
//                  followed by one extra "spill" beat carrying only the
//                  4 trailer bytes (TLAST asserted there instead)
//
// Assumes (per AXI4-Stream convention) every TLAST beat has at least 1 valid
// byte, and that TKEEP is "low aligned" (a contiguous run of 1s from bit 0) --
// checked and flagged on keep_err, non-fatal (passes data through anyway).
// ---------------------------------------------------------------------------
module s2_pkt_framer #(parameter DATA_W = 64) (
    input  wire                   clk,
    input  wire                   rst,       // synchronous, active-high

    input  wire [DATA_W-1:0]      s_tdata,
    input  wire [DATA_W/8-1:0]    s_tkeep,
    input  wire                   s_tvalid,
    input  wire                   s_tlast,
    output wire                   s_tready,

    output reg  [DATA_W-1:0]      m_tdata,
    output reg  [DATA_W/8-1:0]    m_tkeep,
    output reg                    m_tvalid,
    output reg                    m_tlast,
    input  wire                   m_tready,

    output reg                    keep_err   // pulses 1 cycle: TKEEP wasn't low-aligned
);
    localparam N = DATA_W/8;

    reg [31:0] crc_reg;
    reg        spilling;
    reg [31:0] crc_spill;

    wire [31:0] crc_full, crc_part;
    wire [7:0]  nvalid;

    s2_crc32_beat #(.DATA_W(DATA_W)) u_crc (
        .crc_in   (crc_reg),
        .data     (s_tdata),
        .keep     (s_tkeep),
        .crc_full (crc_full),
        .crc_part (crc_part),
        .nvalid   (nvalid)
    );

    wire m_fire = m_tvalid && m_tready;
    // only pull a new input beat when we're not mid-spill and the output
    // register is free to receive (either empty, or being drained this cycle)
    assign s_tready = (!spilling) && (!m_tvalid || m_tready);

    wire [31:0] crc_final = ~crc_part;   // standard CRC-32 final XOR

    function [7:0] crc_byte;
        input [31:0] c;
        input [1:0]  idx;
        begin
            case (idx)
                2'd0: crc_byte = c[7:0];
                2'd1: crc_byte = c[15:8];
                2'd2: crc_byte = c[23:16];
                default: crc_byte = c[31:24];
            endcase
        end
    endfunction

    reg [DATA_W-1:0]   merged_data;
    reg [N-1:0]         merged_keep;
    integer j;
    always @* begin
        merged_data = s_tdata;
        merged_keep = s_tkeep;
        for (j = 0; j < N; j = j + 1) begin
            if (j >= nvalid && j < (nvalid + 8'd4)) begin
                merged_data[8*j +: 8] = crc_byte(crc_final, (j - nvalid));
                merged_keep[j] = 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            crc_reg  <= 32'hFFFFFFFF;
            spilling <= 1'b0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
            keep_err <= 1'b0;
        end else begin
            keep_err <= 1'b0;

            if (spilling) begin
                if (m_fire || !m_tvalid) begin
                    m_tdata  <= {{(DATA_W-32){1'b0}}, crc_spill};
                    m_tkeep  <= {{(N-4){1'b0}}, 4'hF};
                    m_tvalid <= 1'b1;
                    m_tlast  <= 1'b1;
                    spilling <= 1'b0;
                end
            end else if (s_tready && s_tvalid) begin
                if (!((s_tkeep & (s_tkeep + 1'b1)) == {N{1'b0}}))
                    keep_err <= 1'b1;

                if (!s_tlast) begin
                    m_tdata  <= s_tdata;
                    m_tkeep  <= s_tkeep;
                    m_tvalid <= 1'b1;
                    m_tlast  <= 1'b0;
                    crc_reg  <= crc_full;
                end else if ((nvalid + 8'd4) <= N) begin
                    m_tdata  <= merged_data;
                    m_tkeep  <= merged_keep;
                    m_tvalid <= 1'b1;
                    m_tlast  <= 1'b1;
                    crc_reg  <= 32'hFFFFFFFF;
                end else begin
                    // forward the real last data beat unchanged, flag spill
                    m_tdata   <= s_tdata;
                    m_tkeep   <= s_tkeep;
                    m_tvalid  <= 1'b1;
                    m_tlast   <= 1'b0;
                    crc_spill <= crc_final;
                    spilling  <= 1'b1;
                    crc_reg   <= 32'hFFFFFFFF;
                end
            end else if (m_fire) begin
                m_tvalid <= 1'b0;
            end
        end
    end
endmodule
