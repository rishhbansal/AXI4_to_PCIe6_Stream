`timescale 1ns/1ps

// =============================================================================
// JUDGE BREAK TEST 1: PARTIAL BYTE-KEEP (UNALIGNED PACKET LENGTH)
// SARCATHON 2026 Hardware Evaluation Suite
//
// Architectural Boundary Tested:
// - AXI4-Stream specification allows packets of ANY byte length (e.g. 100 Bytes).
// - Beat 0: 64 Bytes (TKEEP = 64'hFFFF_FFFF_FFFF_FFFF)
// - Beat 1: 36 Bytes (TKEEP = 64'h0000_0000_0FFF_FFFF) with TLAST = 1.
//
// Why this breaks / exposes a hardware boundary:
// - PCIe Gen 6 FLITs are fixed 256-Byte containers. When an unaligned packet ends
//   mid-beat, an advanced enterprise controller must pack subsequent packets into
//   the remainder or generate dynamic FLIT alignment tokens.
// - Our bridge zero-pads the beat into the FLIT buffer, but the depacketizer
//   reconstructs beats with full TKEEP (all 1s). The bit-level scoreboard will
//   detect that the 28 invalid padding bytes were forwarded to the host, revealing
//   the lack of a dynamic byte-packing packing engine.
// =============================================================================

module tb_break_partial_tkeep;

    localparam DATA_W = 512;
    localparam KEEP_W = DATA_W / 8;

    reg clk = 0;
    always #2.5 clk = ~clk; // 200 MHz
    reg rst;

    reg  [DATA_W-1:0] s0_tdata;
    reg  [KEEP_W-1:0] s0_tkeep;
    reg               s0_tvalid;
    reg               s0_tlast;
    wire              s0_tready;

    wire [DATA_W-1:0] s1_tdata = 0;
    wire [KEEP_W-1:0] s1_tkeep = 0;
    wire              s1_tvalid = 0;
    wire              s1_tlast = 0;
    wire              s1_tready;

    wire [63:0] phy_lane0_sym, phy_lane1_sym, phy_lane2_sym, phy_lane3_sym;
    wire        phy_sym_valid, phy_flit_start, phy_flit_end;
    reg         phy_ready = 1;

    wire [255:0] rx_flit_data;
    wire         rx_flit_valid, rx_flit_start, rx_flit_end;
    wire [DATA_W-1:0] rec_tdata;
    wire [KEEP_W-1:0] rec_tkeep;
    wire              rec_tvalid, rec_tlast, rec_tsrc;
    reg               rec_tready = 1;

    wire fec_corrected, fec_fatal, crc_ok, crc_err;

    axi4_pcie6_bridge_top #(.DATA_W(DATA_W), .KEEP_W(KEEP_W)) u_bridge (
        .clk(clk), .rst(rst),
        .s0_axis_tdata(s0_tdata), .s0_axis_tkeep(s0_tkeep), .s0_axis_tvalid(s0_tvalid),
        .s0_axis_tlast(s0_tlast), .s0_axis_tready(s0_tready),
        .s1_axis_tdata(s1_tdata), .s1_axis_tkeep(s1_tkeep), .s1_axis_tvalid(s1_tvalid),
        .s1_axis_tlast(s1_tlast), .s1_axis_tready(s1_tready),
        .phy_lane0_sym(phy_lane0_sym), .phy_lane1_sym(phy_lane1_sym),
        .phy_lane2_sym(phy_lane2_sym), .phy_lane3_sym(phy_lane3_sym),
        .phy_sym_valid(phy_sym_valid), .phy_flit_start(phy_flit_start),
        .phy_flit_end(phy_flit_end), .phy_ready(phy_ready)
    );

    pcie6_phy_to_protocol u_rx_phy (
        .clk(clk), .rst(rst),
        .phy_lane0_sym(phy_lane0_sym), .phy_lane1_sym(phy_lane1_sym),
        .phy_lane2_sym(phy_lane2_sym), .phy_lane3_sym(phy_lane3_sym),
        .phy_sym_valid(phy_sym_valid), .phy_flit_start(phy_flit_start),
        .phy_flit_end(phy_flit_end),
        .flit_rx_data(rx_flit_data), .flit_rx_valid(rx_flit_valid),
        .flit_rx_start(rx_flit_start), .flit_rx_end(rx_flit_end)
    );

    pcie6_flit_depacketizer #(.OUT_DATA_W(DATA_W), .OUT_KEEP_W(KEEP_W)) u_rx_link (
        .clk(clk), .rst(rst),
        .flit_rx_data(rx_flit_data), .flit_rx_valid(rx_flit_valid),
        .flit_rx_start(rx_flit_start), .flit_rx_end(rx_flit_end),
        .m_axis_tdata(rec_tdata), .m_axis_tkeep(rec_tkeep),
        .m_axis_tvalid(rec_tvalid), .m_axis_tlast(rec_tlast),
        .m_axis_tsrc(rec_tsrc), .m_axis_tready(rec_tready),
        .fec_corrected(fec_corrected), .fec_fatal(fec_fatal),
        .crc_ok(crc_ok), .crc_err(crc_err)
    );

    integer beat_index = 0;
    integer keep_mismatch_detected = 0;

    always @(posedge clk) begin
        if (rec_tvalid && rec_tready) begin
            if (rec_tlast) begin
                // Check if the receiver properly preserved the partial 36-byte keep mask
                if (rec_tkeep !== 64'h0000_0000_0FFF_FFFF) begin
                    $display("[JUDGE FINDING] Boundary Exposed: rec_tkeep = 0x%016h (Expected partial: 0x000000000FFFFFFF)", rec_tkeep);
                    keep_mismatch_detected = keep_mismatch_detected + 1;
                end
            end
        end
    end

    initial begin
        $display("\n================================================================================");
        $display(" [JUDGE BREAK TEST 1] UNALIGNED PACKET LENGTH & PARTIAL TKEEP BOUNDARY");
        $display("================================================================================");
        rst = 1;
        s0_tvalid = 0; s0_tlast = 0; s0_tdata = 0; s0_tkeep = 0;
        #20 rst = 0;
        repeat (5) @(posedge clk);

        $display("[ATTACK INJECTION] Injecting 100-Byte Packet (Beat 0 = 64B, Beat 1 = 36B with partial TKEEP)...");

        // Beat 0: 64 Bytes (Full)
        s0_tdata  = {16{32'hA1A1_A1A1}};
        s0_tkeep  = {KEEP_W{1'b1}};
        s0_tvalid = 1'b1;
        s0_tlast  = 1'b0;
        @(posedge clk);
        while (!s0_tready) @(posedge clk);
        #0.1;

        // Beat 1: Only 28 bits of keep = 28 bytes + 8 bytes = 36 bytes valid
        s0_tdata  = {16{32'hB2B2_B2B2}};
        s0_tkeep  = 64'h0000_0000_0FFF_FFFF; // Partial keep!
        s0_tvalid = 1'b1;
        s0_tlast  = 1'b1;
        @(posedge clk);
        while (!s0_tready) @(posedge clk);
        #0.1;

        s0_tvalid = 1'b0;
        s0_tlast  = 1'b0;

        repeat (50) @(posedge clk);

        $display("\n--------------------------------------------------------------------------------");
        $display(" JUDGE AUDIT CONCLUSION:");
        $display("--------------------------------------------------------------------------------");
        if (keep_mismatch_detected > 0) begin
            $display(" >>> [CODE BREAK CONFIRMED] <<<");
            $display(" Architectural Limitation Identified: Link Layer does not preserve partial byte");
            $display(" masks across the 256B FLIT boundary; dead padding bytes are forwarded to host.");
        end else begin
            $display(" [SURPRISE] TKEEP was preserved cleanly.");
        end
        $finish;
    end

endmodule
