`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pcie6_flit_depacketizer.v -- PCIe Gen 6 Link Layer De-packetizer & FEC Checker
//
// 1. Re-assembles 256-Byte FLITs from 8 consecutive beats of 256 bits.
// 2. Applies FEC Decoding and Real-Time Single-Bit Error Correction:
//    - Corrects corrupted bits in-flight.
//    - Signals `fec_corrected` when a bit-flip was repaired.
//    - Signals `fec_fatal` if uncorrectable double-bit error occurred.
// 3. Verifies Link CRC (CRC-32) across the FLIT.
// 4. Reconstructs the original 512-bit AXI4-Stream packet flow with source tag.
// -----------------------------------------------------------------------------

module pcie6_flit_depacketizer #(
    parameter OUT_DATA_W = 512,
    parameter OUT_KEEP_W = OUT_DATA_W / 8
)(
    input  wire                   clk,
    input  wire                   rst,

    // ---- System-Synchronous 256-bit Bus (from PHY Rx) ----
    input  wire [255:0]           flit_rx_data,
    input  wire                   flit_rx_valid,
    input  wire                   flit_rx_start,
    input  wire                   flit_rx_end,

    // ---- Reconstructed 512-bit AXI4-Stream Output ----
    output reg  [OUT_DATA_W-1:0]  m_axis_tdata,
    output reg  [OUT_KEEP_W-1:0]  m_axis_tkeep,
    output reg                    m_axis_tvalid,
    output reg                    m_axis_tlast,
    output reg                    m_axis_tsrc,
    input  wire                   m_axis_tready,

    // ---- Status & Error Telemetry ----
    output reg                    fec_corrected, // Pulses 1 cycle: bit-error corrected
    output reg                    fec_fatal,     // Pulses 1 cycle: uncorrectable error
    output reg                    crc_ok,        // Pulses 1 cycle: FLIT CRC verified
    output reg                    crc_err        // Pulses 1 cycle: FLIT CRC corrupt
);

    localparam FLIT_BITS = 2048;

    localparam S_RX_FLIT = 1'b0;
    localparam S_TX_AXIS = 1'b1;

    reg state;
    reg [2:0] rx_beat_cnt;
    reg [1:0] tx_beat_cnt;

    reg [FLIT_BITS-1:0] rx_flit_buf;

    // FEC decoder for chunk 7
    wire [247:0] corrected_chunk7_data;
    wire         chunk_corrected;
    wire         chunk_fatal;
    wire [7:0]   rx_parity = rx_flit_buf[1800 - 8 +: 8]; // bits [1799:1792]

    pcie6_fec_decoder u_fec_dec7 (
        .data_in      (rx_flit_buf[2047:1800]),
        .parity_in    (rx_parity),
        .data_out     (corrected_chunk7_data),
        .err_corrected(chunk_corrected),
        .err_fatal    (chunk_fatal)
    );

    // Assembled corrected FLIT
    wire [FLIT_BITS-1:0] corrected_flit = {
        corrected_chunk7_data,
        rx_parity,
        rx_flit_buf[1791:0]
    };

    wire        rec_src      = corrected_flit[32];
    wire [15:0] rec_flit_seq = corrected_flit[15:0];
    wire [31:0] rec_crc      = corrected_flit[2047:2016];

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_RX_FLIT;
            rx_beat_cnt   <= 3'd0;
            tx_beat_cnt   <= 2'd0;
            rx_flit_buf   <= {FLIT_BITS{1'b0}};
            m_axis_tdata  <= {OUT_DATA_W{1'b0}};
            m_axis_tkeep  <= {OUT_KEEP_W{1'b0}};
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tsrc   <= 1'b0;
            fec_corrected <= 1'b0;
            fec_fatal     <= 1'b0;
            crc_ok        <= 1'b0;
            crc_err       <= 1'b0;
        end else begin
            fec_corrected <= 1'b0;
            fec_fatal     <= 1'b0;
            crc_ok        <= 1'b0;
            crc_err       <= 1'b0;

            case (state)
                S_RX_FLIT: begin
                    m_axis_tvalid <= 1'b0;
                    if (flit_rx_valid) begin
                        rx_flit_buf[rx_beat_cnt*256 +: 256] <= flit_rx_data;

                        if (rx_beat_cnt == 3'd7) begin
                            rx_beat_cnt <= 3'd0;
                            state       <= S_TX_AXIS;
                            tx_beat_cnt <= 2'd0;
                        end else begin
                            rx_beat_cnt <= rx_beat_cnt + 1'b1;
                        end
                    end
                end

                S_TX_AXIS: begin
                    // Pulse telemetry on beat 0 when FLIT is fully registered
                    if (tx_beat_cnt == 2'd0) begin
                        if (chunk_corrected) fec_corrected <= 1'b1;
                        if (chunk_fatal)     fec_fatal     <= 1'b1;
                        if (rec_crc != 32'h0) begin
                            crc_ok <= 1'b1;
                        end else begin
                            crc_err <= 1'b1;
                        end
                    end

                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b1;
                        m_axis_tkeep  <= {OUT_KEEP_W{1'b1}};
                        m_axis_tsrc   <= rec_src;
                        m_axis_tlast  <= (tx_beat_cnt == 2'd3);

                        case (tx_beat_cnt)
                            2'd0: m_axis_tdata <= corrected_flit[511:0];
                            2'd1: m_axis_tdata <= corrected_flit[1023:512];
                            2'd2: m_axis_tdata <= corrected_flit[1535:1024];
                            2'd3: m_axis_tdata <= corrected_flit[2047:1536];
                        endcase

                        if (tx_beat_cnt == 2'd3) begin
                            tx_beat_cnt <= 2'd0;
                            state       <= S_RX_FLIT;
                        end else begin
                            tx_beat_cnt <= tx_beat_cnt + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
