`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// s2_pkt_checker -- inverse of s2_pkt_framer. Strips the 4-byte CRC-32
// trailer that s2_pkt_framer appended, re-emits the original payload with
// the original TLAST restored on the true final beat, and reports whether
// the CRC matched.
//
// Why a beat of look-ahead is needed: when the framer SPILLS (trailer sent
// as its own extra beat), the checker only learns that the previous beat
// was really the last payload beat once it sees the following beat's
// TLAST=1 with exactly 4 valid bytes. So every non-final beat is held one
// cycle before being forwarded ("H"); and when a merge-case final beat
// arrives while H is still pending, flushing H (ordinary) AND the
// stripped final beat (tlast) both happen, which needs 2 output cycles.
// That case is handled with a tiny 2-slot output skid queue.
//
// Known limitation: s_tready is only asserted while BOTH skid slots are
// empty, so a merge-final beat costs one bubble cycle on the input side.
// Acceptable for Stage 2 functional verification; a fully-pipelined
// version is listed as a future improvement.
// ---------------------------------------------------------------------------
module s2_pkt_checker #(parameter DATA_W = 64) (
    input  wire                   clk,
    input  wire                   rst,

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

    output reg                    crc_ok,    // pulses 1 cycle per good packet
    output reg                    crc_err    // pulses 1 cycle per bad packet
);
    localparam N = DATA_W/8;

    reg [31:0] crc_reg;
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
    // magic residue: running the untouched message+trailer through the same
    // (non-inverted) CRC engine always lands on this fixed constant when the
    // trailer matches -- avoids needing to separately recompute/compare.
    localparam [31:0] CRC_MAGIC = 32'hDEBB20E3;

    // ---- held beat H (not yet known to be final) ----
    reg                  h_valid;
    reg [DATA_W-1:0]     h_data;
    reg [N-1:0]          h_keep;

    // ---- 2-slot output skid queue ----
    reg                  a_valid, b_valid;
    reg [DATA_W-1:0]     a_data,  b_data;
    reg [N-1:0]          a_keep,  b_keep;
    reg                  a_last,  b_last;

    assign s_tready = !a_valid && !b_valid;

    integer k;
    reg [DATA_W-1:0] stripped_data;
    reg [N-1:0]      stripped_keep;
    always @* begin
        stripped_data = s_tdata;
        stripped_keep = s_tkeep;
        for (k = 0; k < N; k = k + 1)
            if (k >= (nvalid - 8'd4))
                stripped_keep[k] = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            crc_reg <= 32'hFFFFFFFF;
            h_valid <= 1'b0;
            a_valid <= 1'b0; b_valid <= 1'b0;
            crc_ok <= 1'b0; crc_err <= 1'b0;
            m_tvalid <= 1'b0; m_tlast <= 1'b0;
        end else begin
            crc_ok  <= 1'b0;
            crc_err <= 1'b0;

            // drain skid queue into the output register
            if (!m_tvalid || m_tready) begin
                if (a_valid) begin
                    m_tdata  <= a_data;  m_tkeep <= a_keep; m_tlast <= a_last;
                    m_tvalid <= 1'b1;
                    a_valid  <= b_valid; a_data <= b_data; a_keep <= b_keep; a_last <= b_last;
                    b_valid  <= 1'b0;
                end else begin
                    m_tvalid <= 1'b0;
                end
            end

            if (s_tready && s_tvalid) begin
                // NOTE: always use crc_part, not crc_full. crc_full silently
                // assumes all N lanes are valid data; that's true for a
                // normal interior beat of the ORIGINAL AXI4-Stream, but not
                // here -- in the framer's "spill" case, the forwarded beat
                // keeps TLAST=0 even though it only has nvalid<N real bytes
                // (its trailer was pushed into the next beat instead). Using
                // crc_full there silently feeds extra zero bytes into the
                // CRC and corrupts it. crc_part reduces to crc_full anyway
                // whenever keep genuinely is all-ones, so this is correct
                // for ordinary full beats too.
                crc_reg <= s_tlast ? 32'hFFFFFFFF : crc_part;

                if (!s_tlast) begin
                    if (h_valid) begin
                        a_valid <= 1'b1; a_data <= h_data; a_keep <= h_keep; a_last <= 1'b0;
                    end
                    h_valid <= 1'b1; h_data <= s_tdata; h_keep <= s_tkeep;
                end else begin
                    // final beat of the framed stream
                    if (h_valid && nvalid == 8'd4) begin
                        // Case B: pure trailer spill beat; H was the real final beat
                        a_valid <= 1'b1; a_data <= h_data; a_keep <= h_keep; a_last <= 1'b1;
                        h_valid <= 1'b0;
                    end else begin
                        // Case A: trailer merged into this beat
                        if (h_valid) begin
                            a_valid <= 1'b1; a_data <= h_data; a_keep <= h_keep; a_last <= 1'b0;
                            b_valid <= 1'b1; b_data <= stripped_data; b_keep <= stripped_keep; b_last <= 1'b1;
                        end else begin
                            a_valid <= 1'b1; a_data <= stripped_data; a_keep <= stripped_keep; a_last <= 1'b1;
                        end
                        h_valid <= 1'b0;
                    end
                    // crc_full assumes ALL N lanes are valid data; the final
                    // beat is usually only partially populated (keep != all
                    // ones), so the correct residue to check is crc_part,
                    // which already accounts for exactly `nvalid` real bytes.
                    if (crc_part == CRC_MAGIC) crc_ok <= 1'b1; else crc_err <= 1'b1;
                end
            end
        end
    end
endmodule
