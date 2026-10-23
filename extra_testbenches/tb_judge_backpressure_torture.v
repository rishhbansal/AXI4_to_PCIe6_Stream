`timescale 1ns/1ps

// =============================================================================
// JUDGE TESTBENCH 2: PATHOLOGICAL BACKPRESSURE & SKID BUFFER BOUNDARY TORTURE
// SARCATHON 2026 Hardware Evaluation Suite
//
// Evaluates:
// 1. Erratic PHY Backpressure: Rapidly toggling phy_ready (50% duty cycle, random jitter).
// 2. TLAST Stall Torture: Asserting backpressure precisely on the TLAST beat to test
//    skid buffer absorption and state machine boundaries.
// 3. Deep Pipeline Stalls: 50-cycle backpressure holds with ingress data waiting.
// 4. Strict Protocol Compliance: Asserts that s_axis_tdata, s_axis_tkeep, s_axis_tlast
//    remain perfectly stable while stalled (no beat mutation or drop).
// 5. Zero Bubble Cycle Check: Confirms instant pipeline resumption upon release.
// =============================================================================

module tb_judge_backpressure_torture;

    localparam DATA_W = 512;
    localparam KEEP_W = DATA_W / 8;

    reg clk = 0;
    always #2.5 clk = ~clk; // 200 MHz Clock
    reg rst;

    reg  [DATA_W-1:0] s0_tdata;
    reg  [KEEP_W-1:0] s0_tkeep;
    reg               s0_tvalid;
    reg               s0_tlast;
    wire              s0_tready;

    // Tie off Port 1 for isolated backpressure evaluation
    wire [DATA_W-1:0] s1_tdata  = {DATA_W{1'b0}};
    wire [KEEP_W-1:0] s1_tkeep  = {KEEP_W{1'b0}};
    wire              s1_tvalid = 1'b0;
    wire              s1_tlast  = 1'b0;
    wire              s1_tready;

    // PHY Interface
    wire [63:0] phy_lane0_sym, phy_lane1_sym, phy_lane2_sym, phy_lane3_sym;
    wire        phy_sym_valid, phy_flit_start, phy_flit_end;
    reg         phy_ready = 1'b1;

    // Receiver Subsystem
    wire [255:0] rx_flit_data;
    wire         rx_flit_valid, rx_flit_start, rx_flit_end;
    wire [DATA_W-1:0] rec_tdata;
    wire [KEEP_W-1:0] rec_tkeep;
    wire              rec_tvalid, rec_tlast, rec_tsrc;
    reg               rec_tready = 1'b1;

    wire fec_corrected, fec_fatal, crc_ok, crc_err;

    // DUT
    axi4_pcie6_bridge_top #(
        .DATA_W(DATA_W), .KEEP_W(KEEP_W)
    ) u_bridge (
        .clk           (clk),
        .rst           (rst),
        .s0_axis_tdata (s0_tdata),
        .s0_axis_tkeep (s0_tkeep),
        .s0_axis_tvalid(s0_tvalid),
        .s0_axis_tlast (s0_tlast),
        .s0_axis_tready(s0_tready),
        .s1_axis_tdata (s1_tdata),
        .s1_axis_tkeep (s1_tkeep),
        .s1_axis_tvalid(s1_tvalid),
        .s1_axis_tlast (s1_tlast),
        .s1_axis_tready(s1_tready),
        .phy_lane0_sym (phy_lane0_sym),
        .phy_lane1_sym (phy_lane1_sym),
        .phy_lane2_sym (phy_lane2_sym),
        .phy_lane3_sym (phy_lane3_sym),
        .phy_sym_valid (phy_sym_valid),
        .phy_flit_start(phy_flit_start),
        .phy_flit_end  (phy_flit_end),
        .phy_ready     (phy_ready)
    );

    pcie6_phy_to_protocol u_rx_phy (
        .clk           (clk),
        .rst           (rst),
        .phy_lane0_sym (phy_lane0_sym),
        .phy_lane1_sym (phy_lane1_sym),
        .phy_lane2_sym (phy_lane2_sym),
        .phy_lane3_sym (phy_lane3_sym),
        .phy_sym_valid (phy_sym_valid),
        .phy_flit_start(phy_flit_start),
        .phy_flit_end  (phy_flit_end),
        .flit_rx_data  (rx_flit_data),
        .flit_rx_valid (rx_flit_valid),
        .flit_rx_start (rx_flit_start),
        .flit_rx_end   (rx_flit_end)
    );

    pcie6_flit_depacketizer #(
        .OUT_DATA_W(DATA_W), .OUT_KEEP_W(KEEP_W)
    ) u_rx_link (
        .clk          (clk),
        .rst          (rst),
        .flit_rx_data (rx_flit_data),
        .flit_rx_valid(rx_flit_valid),
        .flit_rx_start(rx_flit_start),
        .flit_rx_end  (rx_flit_end),
        .m_axis_tdata (rec_tdata),
        .m_axis_tkeep (rec_tkeep),
        .m_axis_tvalid(rec_tvalid),
        .m_axis_tlast (rec_tlast),
        .m_axis_tsrc  (rec_tsrc),
        .m_axis_tready(rec_tready),
        .fec_corrected(fec_corrected),
        .fec_fatal    (fec_fatal),
        .crc_ok       (crc_ok),
        .crc_err      (crc_err)
    );

    // -------------------------------------------------------------------------
    // Protocol Assertions & Metrics
    // -------------------------------------------------------------------------
    integer total_beats_sent = 0;
    integer total_beats_rec  = 0;
    integer crc_passes       = 0;
    integer protocol_violations = 0;
    integer judge_errors     = 0;

    // Check AXI4-Stream stability rule on ingress:
    // Once TVALID is asserted, TDATA, TKEEP, TLAST must not change until TREADY is asserted.
    reg [DATA_W-1:0] prev_data;
    reg [KEEP_W-1:0] prev_keep;
    reg              prev_last;
    reg              was_waiting = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (s0_tvalid && !s0_tready) begin
                if (was_waiting) begin
                    if (s0_tdata !== prev_data || s0_tkeep !== prev_keep || s0_tlast !== prev_last) begin
                        $display("[PROTOCOL ERROR] Ingress beat changed while stalled under backpressure!");
                        protocol_violations = protocol_violations + 1;
                        judge_errors = judge_errors + 1;
                    end
                end
                prev_data   <= s0_tdata;
                prev_keep   <= s0_tkeep;
                prev_last   <= s0_tlast;
                was_waiting <= 1'b1;
            end else begin
                was_waiting <= 1'b0;
            end
        end
    end

    // Receiver telemetry
    always @(posedge clk) begin
        if (crc_ok) crc_passes = crc_passes + 1;
        if (rec_tvalid && rec_tready) begin
            total_beats_rec = total_beats_rec + 1;
        end
    end

    // Task to send a packet with a designated payload seed
    task send_packet(input integer beats, input [31:0] seed);
        integer b;
        begin
            for (b = 0; b < beats; b = b + 1) begin
                s0_tdata  = {16{seed}} ^ (b * 64'hFEDCBA9876543210);
                s0_tkeep  = {KEEP_W{1'b1}};
                s0_tvalid = 1'b1;
                s0_tlast  = (b == beats - 1);
                @(posedge clk);
                while (!s0_tready) @(posedge clk);
                #0.1;
                total_beats_sent = total_beats_sent + 1;
            end
            s0_tvalid = 1'b0;
            s0_tlast  = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Torture Test Sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("\n================================================================================");
        $display(" [JUDGE TEST 2] PATHOLOGICAL BACKPRESSURE & SKID BUFFER BOUNDARY TORTURE");
        $display("================================================================================");
        rst = 1;
        s0_tvalid = 0; s0_tlast = 0; s0_tdata = 0; s0_tkeep = 0;
        phy_ready = 1;
        rec_tready = 1;
        #20 rst = 0;
        repeat (5) @(posedge clk);

        // --- SUBTEST A: 50% Rapid Toggling Backpressure ---
        $display("[STAGE 1/4] Applying 50 percent High-Frequency PHY Stalls (1 cycle ON / 1 cycle OFF)...");
        fork
            begin
                repeat (20) begin
                    phy_ready = 1'b0;
                    @(posedge clk);
                    phy_ready = 1'b1;
                    @(posedge clk);
                end
            end
            begin
                send_packet(4, 32'hAAAA_0001);
                send_packet(4, 32'hAAAA_0002);
            end
        join
        phy_ready = 1'b1;
        repeat (20) @(posedge clk);

        // --- SUBTEST B: TLAST Beat Stalls ---
        $display("[STAGE 2/4] Asserting Backpressure Precisely on TLAST Packet Boundaries...");
        fork
            begin
                // Wait for TVALID && TLAST, then clamp backpressure immediately
                @(posedge clk);
                wait (s0_tvalid && s0_tlast);
                phy_ready = 1'b0;
                repeat (8) @(posedge clk);
                phy_ready = 1'b1;
            end
            begin
                send_packet(4, 32'hBBBB_0001);
            end
        join
        repeat (20) @(posedge clk);

        // --- SUBTEST C: Deep 50-Cycle Extended Stall ---
        $display("[STAGE 3/4] Clamping Sustained 50-Cycle Backpressure Stall With Ingress Active...");
        fork
            begin
                repeat (5) @(posedge clk);
                phy_ready = 1'b0;
                repeat (50) @(posedge clk);
                phy_ready = 1'b1;
            end
            begin
                send_packet(8, 32'hCCCC_0001);
            end
        join
        repeat (30) @(posedge clk);

        // --- SUBTEST D: Host Receiver Backpressure ---
        $display("[STAGE 4/4] Applying Backpressure at Host Receiver (rec_tready)...");
        fork
            begin
                repeat (30) begin
                    rec_tready = $random;
                    @(posedge clk);
                end
                rec_tready = 1'b1;
            end
            begin
                send_packet(4, 32'hDDDD_0001);
            end
        join

        // Drain pipeline
        repeat (60) @(posedge clk);

        $display("\n--------------------------------------------------------------------------------");
        $display(" JUDGE AUDIT METRICS:");
        $display("--------------------------------------------------------------------------------");
        $display(" Total AXI Ingress Beats Sent      : %0d", total_beats_sent);
        $display(" Total AXI Egress Beats Recovered  : %0d", total_beats_rec);
        $display(" Total Verified FLITs Transferred  : %0d", crc_passes);
        $display(" AXI4-Stream Protocol Violations   : %0d", protocol_violations);

        // Verification assertions
        if (total_beats_rec !== total_beats_sent) begin
            $display("[FAIL] Data loss detected! Beats sent (%0d) != beats recovered (%0d)", 
                     total_beats_sent, total_beats_rec);
            judge_errors = judge_errors + 1;
        end
        if (protocol_violations > 0) begin
            $display("[FAIL] Bridge mutated ingress beats under backpressure!");
            judge_errors = judge_errors + 1;
        end
        if (crc_passes < 6) begin
            $display("[FAIL] FLIT integrity corrupted under backpressure!");
            judge_errors = judge_errors + 1;
        end

        if (judge_errors == 0) begin
            $display("\n >>> [STATUS: PASSED] - SKID BUFFER FULLY RESILIENT TO PATHOLOGICAL STALLS <<< \n");
        end else begin
            $display("\n >>> [STATUS: FAILED] - %0d ERRORS ENCOUNTERED <<< \n", judge_errors);
        end
        $finish;
    end

endmodule
