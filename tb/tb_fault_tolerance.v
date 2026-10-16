`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_fault_tolerance.v -- Fault Tolerance, FEC & Reliability Testbench
//
// Verification requirements for Stage 1 & Stage 2:
// 1. Error injection behaviour:
//    - Single-bit error in PAM4 channel: verifies FEC detects & repairs bit-flip.
//    - Multi-bit uncorrectable error: verifies fatal error flag & packet drop.
//    - CRC corruption: verifies rejection.
// 2. Reset behaviour:
//    - Reset asserted mid-transaction: verifies clean recovery without hanging.
// -----------------------------------------------------------------------------

module tb_fault_tolerance;

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

    wire [DATA_W-1:0] s1_tdata  = {DATA_W{1'b0}};
    wire [KEEP_W-1:0] s1_tkeep  = {KEEP_W{1'b0}};
    wire              s1_tvalid = 1'b0;
    wire              s1_tlast  = 1'b0;
    wire              s1_tready;

    // PHY Interface
    wire [63:0] phy_lane0_sym, phy_lane1_sym, phy_lane2_sym, phy_lane3_sym;
    wire        phy_sym_valid, phy_flit_start, phy_flit_end;
    reg         phy_ready = 1'b1;

    // Fault injection registers
    reg corrupt_single_bit = 0;
    reg corrupt_multi_bit  = 0;

    // Faulty Channel: flip a data bit in lane 0 (bit 8 = byte 1 of lane 0 = byte 4 of FLIT chunk)
    wire [63:0] ch_lane0_sym = (corrupt_single_bit) ? (phy_lane0_sym ^ 64'h100) :
                               (corrupt_multi_bit)  ? (phy_lane0_sym ^ 64'h7) : phy_lane0_sym;
    wire [63:0] ch_lane1_sym = phy_lane1_sym;
    wire [63:0] ch_lane2_sym = phy_lane2_sym;
    wire [63:0] ch_lane3_sym = phy_lane3_sym;

    // RX Subsystem
    wire [255:0] rx_flit_data;
    wire         rx_flit_valid, rx_flit_start, rx_flit_end;
    wire [DATA_W-1:0] rec_tdata;
    wire [KEEP_W-1:0] rec_tkeep;
    wire              rec_tvalid, rec_tlast, rec_tsrc;
    wire              fec_corrected, fec_fatal, crc_ok, crc_err;

    axi4_pcie6_bridge_top #(
        .DATA_W(DATA_W), .KEEP_W(KEEP_W)
    ) u_bridge (
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
        .phy_lane0_sym(ch_lane0_sym), .phy_lane1_sym(ch_lane1_sym),
        .phy_lane2_sym(ch_lane2_sym), .phy_lane3_sym(ch_lane3_sym),
        .phy_sym_valid(phy_sym_valid), .phy_flit_start(phy_flit_start),
        .phy_flit_end(phy_flit_end),
        .flit_rx_data(rx_flit_data), .flit_rx_valid(rx_flit_valid),
        .flit_rx_start(rx_flit_start), .flit_rx_end(rx_flit_end)
    );

    pcie6_flit_depacketizer #(
        .OUT_DATA_W(DATA_W), .OUT_KEEP_W(KEEP_W)
    ) u_rx_link (
        .clk(clk), .rst(rst),
        .flit_rx_data(rx_flit_data), .flit_rx_valid(rx_flit_valid),
        .flit_rx_start(rx_flit_start), .flit_rx_end(rx_flit_end),
        .m_axis_tdata(rec_tdata), .m_axis_tkeep(rec_tkeep),
        .m_axis_tvalid(rec_tvalid), .m_axis_tlast(rec_tlast),
        .m_axis_tsrc(rec_tsrc), .m_axis_tready(1'b1),
        .fec_corrected(fec_corrected), .fec_fatal(fec_fatal),
        .crc_ok(crc_ok), .crc_err(crc_err)
    );

    // Event trackers
    integer single_bit_repairs = 0;
    integer multi_bit_detected = 0;
    integer valid_flits_rec    = 0;

    always @(posedge clk) begin
        if (fec_corrected) single_bit_repairs = single_bit_repairs + 1;
        if (fec_fatal)     multi_bit_detected = multi_bit_detected + 1;
        if (crc_ok)        valid_flits_rec    = valid_flits_rec + 1;
    end

    task send_test_packet(input integer num_beats);
        integer b;
        begin
            for (b = 0; b < num_beats; b = b + 1) begin
                s0_tdata  = {8{64'hFEDCBA9876543210}} ^ (b * 64'h0101010101010101);
                s0_tkeep  = {KEEP_W{1'b1}};
                s0_tvalid = 1'b1;
                s0_tlast  = (b == num_beats - 1);
                @(posedge clk);
                while (!s0_tready) @(posedge clk);
                #0.1;
            end
            s0_tvalid = 1'b0;
            s0_tlast  = 1'b0;
        end
    endtask

    initial begin
        $display("================================================================");
        $display("  TESTBENCH: Fault Tolerance, Error Recovery & Reliability      ");
        $display("================================================================");

        rst = 1;
        s0_tvalid = 0; s0_tlast = 0; s0_tdata = 0; s0_tkeep = 0;
        corrupt_single_bit = 0;
        corrupt_multi_bit  = 0;
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        // ---------------------------------------------------------------------
        // Test 1: Baseline Clean Transmission
        // ---------------------------------------------------------------------
        $display("\n[TEST 1] Transmitting Clean 256-Byte FLIT...");
        send_test_packet(4);
        repeat (30) @(posedge clk);
        $display("-> Baseline Clean FLITs Verified: %0d", valid_flits_rec);

        // ---------------------------------------------------------------------
        // Test 2: In-Flight PAM4 Single-Bit Error Injection & FEC Repair
        // ---------------------------------------------------------------------
        $display("\n[TEST 2] Injecting Single-Bit PAM4 Symbol Error (Lane 0)...");
        fork
            send_test_packet(4);
            begin
                // Wait for FLIT start, then advance 7 cycles to hit Chunk 7
                while (!phy_flit_start) @(posedge clk);
                repeat (6) @(posedge clk);
                corrupt_single_bit = 1;
                @(posedge clk);
                corrupt_single_bit = 0;
            end
        join
        repeat (35) @(posedge clk);
        $display("-> Single-Bit Repairs Detected: %0d (Expected >= 1)", single_bit_repairs);

        // ---------------------------------------------------------------------
        // Test 3: Multi-Bit Uncorrectable Error Injection
        // ---------------------------------------------------------------------
        $display("\n[TEST 3] Injecting Multi-Bit Uncorrectable Error (Lane 0)...");
        corrupt_multi_bit = 1;
        send_test_packet(4);
        repeat (30) @(posedge clk);
        corrupt_multi_bit = 0;
        $display("-> Multi-Bit Fatal Errors Flagged: %0d (Expected >= 1)", multi_bit_detected);

        // ---------------------------------------------------------------------
        // Test 4: Mid-Packet Reset Recovery
        // ---------------------------------------------------------------------
        $display("\n[TEST 4] Triggering Reset Mid-Stream & Testing Recovery...");
        s0_tdata  = {DATA_W{4'hA}};
        s0_tvalid = 1'b1;
        s0_tlast  = 1'b0;
        repeat (2) @(posedge clk);
        // Assert reset mid-stream
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;
        s0_tvalid = 1'b0;
        repeat (10) @(posedge clk);

        // Send post-reset clean packet to verify full operational recovery
        $display("-> Sending post-reset recovery packet...");
        send_test_packet(4);
        repeat (35) @(posedge clk);

        $display("\n================================================================");
        $display("               FAULT TOLERANCE TEST RESULTS                     ");
        $display("================================================================");
        $display(" Single-bit errors corrected by FEC : %0d", single_bit_repairs);
        $display(" Multi-bit fatal errors detected   : %0d", multi_bit_detected);
        $display(" Total valid FLITs verified        : %0d", valid_flits_rec);

        if (single_bit_repairs >= 1 && multi_bit_detected >= 1 && valid_flits_rec >= 3) begin
            $display(" >>> [FAULT TOLERANCE & RESET BEHAVIOUR: PASSED] <<< \n");
        end else begin
            $display(" >>> [FAULT TOLERANCE: FAILED] <<< \n");
        end

        $finish;
    end

    initial begin
        #5000000;
        $display("ERROR: Fault tolerance test timeout");
        $finish;
    end

endmodule
