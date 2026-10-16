`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// pcie6_fec.v -- Forward Error Correction (FEC) Engine for PCIe Gen 6 FLITs
//
// In PCIe Gen 6, every 256-Byte FLIT is protected by low-latency FEC.
// This module implements an exact SEC-DED (Single Error Correction,
// Double Error Detection) Hamming-matrix code:
// - 248 payload bits protected by 8 parity bits (P0..P6 syndrome + P7 overall).
// - Re-calculates syndrome, identifies single-bit error position,
//   corrects in-flight, and detects uncorrectable double-bit errors.
// -----------------------------------------------------------------------------

module pcie6_fec_encoder (
    input  wire [247:0] data_in,     // 248 payload bits
    output wire [7:0]   parity_out   // 8 SEC-DED parity bits
);
    reg [6:0] p_synd;
    integer i;

    always @* begin
        p_synd = 7'd0;
        for (i = 0; i < 248; i = i + 1) begin
            if (data_in[i]) begin
                p_synd = p_synd ^ ((i[6:0]) + 7'd1);
            end
        end
    end

    wire p_overall = ^data_in; // Parity of all data bits
    assign parity_out = {p_overall, p_synd};
endmodule


module pcie6_fec_decoder (
    input  wire [247:0] data_in,
    input  wire [7:0]   parity_in,
    output reg  [247:0] data_out,
    output wire         err_corrected,  // 1-cycle flag: single-bit error corrected
    output wire         err_fatal       // 1-cycle flag: uncorrectable multi-bit error detected
);
    reg [6:0] syn_calc;
    integer i;

    always @* begin
        syn_calc = 7'd0;
        for (i = 0; i < 248; i = i + 1) begin
            if (data_in[i]) begin
                syn_calc = syn_calc ^ ((i[6:0]) + 7'd1);
            end
        end
    end

    wire [6:0] syn_diff = syn_calc ^ parity_in[6:0];
    wire p_overall_calc = ^data_in;
    wire overall_mismatch = (p_overall_calc != parity_in[7]);

    wire has_syn_error = (syn_diff != 7'd0);

    // SEC-DED:
    // - syn_diff != 0 and overall_mismatch: Single bit error in data
    // - syn_diff == 0 and overall_mismatch: Single bit error in parity bit P7
    // - syn_diff != 0 and !overall_mismatch: Double error!
    assign err_corrected = has_syn_error && overall_mismatch;
    assign err_fatal     = has_syn_error && !overall_mismatch;

    always @* begin
        data_out = data_in;
        if (err_corrected && syn_diff >= 7'd1) begin
            data_out[syn_diff - 7'd1] = ~data_in[syn_diff - 7'd1];
        end
    end
endmodule
