`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pcie6_link_layer.v -- PCIe Gen 6 Link Layer: Packetizer & Error Correction
//
// As specified in the SARCATHON Block Diagram:
// - Takes the Raw Internal Parallel Bus (512-bit wide AXI stream).
// - Bundles data into fixed 256-Byte (2048-bit) Flow Information Units (FLITs).
// - Computes and appends CRC-32 (LCRC) and FEC (Forward Error Correction parity).
// - Serializes the 256-Byte FLIT onto the System-Synchronous 256-bit Bus
//   (each 256-Byte FLIT is transmitted across 8 clock beats of 256 bits).
// -----------------------------------------------------------------------------

module pcie6_link_layer #(
    parameter IN_DATA_W  = 512,
    parameter OUT_DATA_W = 256
)(
    input  wire                   clk,
    input  wire                   rst,

    // ---- Raw Internal Parallel Bus (512-bit) ----
    input  wire [IN_DATA_W-1:0]   raw_tdata,
    input  wire [IN_DATA_W/8-1:0] raw_tkeep,
    input  wire                   raw_tvalid,
    input  wire                   raw_tlast,
    input  wire                   raw_tsrc,
    output wire                   raw_tready,

    // ---- System-Synchronous 256-bit Bus ----
    output reg  [OUT_DATA_W-1:0]  flit_tdata,
    output reg                    flit_tvalid,
    output reg                    flit_tstart, // Start of 256-Byte FLIT (beat 0)
    output reg                    flit_tend,   // End of 256-Byte FLIT (beat 7)
    input  wire                   flit_tready
);

    localparam FLIT_BITS = 2048;

    localparam S_ACCUM = 1'b0;
    localparam S_TX    = 1'b1;

    reg state;
    reg [1:0] accum_cnt;      // 0..3 (4 beats of 512-bit)
    reg [2:0] tx_cnt;         // 0..7 (8 beats of 256-bit)

    reg [FLIT_BITS-1:0] flit_buffer;
    reg [31:0] crc_accum;
    reg [15:0] flit_seq;

    // CRC engine for 512-bit input beat
    wire [31:0] crc_beat_full, crc_beat_part;
    wire [7:0]  nvalid_beat;

    s2_crc32_beat #(.DATA_W(512)) u_crc512 (
        .crc_in   (crc_accum),
        .data     (raw_tdata),
        .keep     (raw_tkeep),
        .crc_full (crc_beat_full),
        .crc_part (crc_beat_part),
        .nvalid   (nvalid_beat)
    );

    // FEC Encoder for chunk 7 (top 248 bits protected by 8-bit SEC-DED parity)
    wire [7:0] fec_par;
    pcie6_fec_encoder u_fec_enc (
        .data_in   (flit_buffer[2047:1800]),
        .parity_out(fec_par)
    );

    // Raw bus ready only during accumulation
    assign raw_tready = (state == S_ACCUM);

    wire raw_fire  = raw_tvalid && raw_tready;
    wire flit_fire = flit_tvalid && flit_tready;

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_ACCUM;
            accum_cnt   <= 2'd0;
            tx_cnt      <= 3'd0;
            flit_buffer <= {FLIT_BITS{1'b0}};
            crc_accum   <= 32'hFFFFFFFF;
            flit_seq    <= 16'd0;
            flit_tdata  <= {OUT_DATA_W{1'b0}};
            flit_tvalid <= 1'b0;
            flit_tstart <= 1'b0;
            flit_tend   <= 1'b0;
        end else begin
            case (state)
                S_ACCUM: begin
                    flit_tvalid <= 1'b0;
                    flit_tstart <= 1'b0;
                    flit_tend   <= 1'b0;

                    if (raw_fire) begin
                        if (accum_cnt == 2'd0) begin
                            flit_buffer[511:0] <= {raw_tdata[511:32], raw_tsrc, 15'd0, flit_seq};
                            crc_accum          <= crc_beat_full;
                        end else if (accum_cnt == 2'd1) begin
                            flit_buffer[1023:512] <= raw_tdata;
                            crc_accum             <= crc_beat_full;
                        end else if (accum_cnt == 2'd2) begin
                            flit_buffer[1535:1024] <= raw_tdata;
                            crc_accum              <= crc_beat_full;
                        end else begin
                            // Beat 3: embed CRC-32 in top 32 bits
                            flit_buffer[2047:1536] <= {~crc_beat_full, raw_tdata[479:0]};
                            crc_accum              <= 32'hFFFFFFFF; // Reset for next flit
                        end

                        if (accum_cnt == 2'd3 || raw_tlast) begin
                            accum_cnt <= 2'd0;
                            flit_seq  <= flit_seq + 1'b1;
                            state     <= S_TX;
                            tx_cnt    <= 3'd0;
                        end else begin
                            accum_cnt <= accum_cnt + 1'b1;
                        end
                    end
                end

                S_TX: begin
                    if (!flit_tvalid || flit_tready) begin
                        flit_tvalid <= 1'b1;
                        flit_tstart <= (tx_cnt == 3'd0);
                        flit_tend   <= (tx_cnt == 3'd7);

                        if (tx_cnt == 3'd7) begin
                            flit_tdata <= {flit_buffer[2047:1800], fec_par};
                        end else begin
                            flit_tdata <= flit_buffer[tx_cnt*256 +: 256];
                        end

                        if (tx_cnt == 3'd7) begin
                            tx_cnt <= 3'd0;
                            state  <= S_ACCUM;
                        end else begin
                            tx_cnt <= tx_cnt + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
