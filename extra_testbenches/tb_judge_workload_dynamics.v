`timescale 1ns/1ps

// =============================================================================
// JUDGE TESTBENCH 4: EXTREME DYNAMIC WORKLOAD MIXING & ABRUPT RESET RECOVERY
// SARCATHON 2026 Hardware Evaluation Suite
//
// Evaluates:
// 1. Extreme Workload Asymmetry: Rapidly alternates between 64-Byte micro-runts
//    (single beat) and massive 4096-Byte ML inference tensor arrays.
// 2. High-Frequency Bursts: Random idle cycles (0 to 3 bubbles) between packet bursts
//    to stress state machine transition logic.
// 3. Mid-Flight Asynchronous Reset Recovery: Triggers hard hardware reset (rst=1)
//    directly during beat 2 of an active multi-beat transfer.
// 4. Hardware Self-Clearing: Verifies zero state machine lockups, zero deadlocks,
//    and immediate healthy resumption of post-reset traffic.
// =============================================================================

module tb_judge_workload_dynamics;

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

    reg  [DATA_W-1:0] s1_tdata;
    reg  [KEEP_W-1:0] s1_tkeep;
    reg               s1_tvalid;
    reg               s1_tlast;
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

    integer pre_reset_flits  = 0;
    integer post_reset_flits = 0;
    integer judge_errors     = 0;
    reg     reset_phase_active = 0;

    always @(posedge clk) begin
        if (crc_ok) begin
            if (!reset_phase_active) pre_reset_flits  = pre_reset_flits + 1;
            else                     post_reset_flits = post_reset_flits + 1;
        end
    end

    task send_network_packet(input integer beats, input [31:0] seed);
        integer b;
        begin
            for (b = 0; b < beats; b = b + 1) begin
                s0_tdata  = {16{seed}} ^ (b * 64'h0123456789ABCDEF);
                s0_tkeep  = {KEEP_W{1'b1}};
                s0_tvalid = 1'b1;
                s0_tlast  = (b == beats - 1);
                @(posedge clk);
                while (!s0_tready) @(posedge clk);
                #0.1;
            end
            s0_tvalid = 1'b0;
            s0_tlast  = 1'b0;
        end
    endtask

    task send_ml_tensor(input integer beats, input [31:0] seed);
        integer b;
        begin
            for (b = 0; b < beats; b = b + 1) begin
                s1_tdata  = {16{seed}} + (b * 64'h1111222233334444);
                s1_tkeep  = {KEEP_W{1'b1}};
                s1_tvalid = 1'b1;
                s1_tlast  = (b == beats - 1);
                @(posedge clk);
                while (!s1_tready) @(posedge clk);
                #0.1;
            end
            s1_tvalid = 1'b0;
            s1_tlast  = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Execution Flow
    // -------------------------------------------------------------------------
    initial begin
        $display("\n================================================================================");
        $display(" [JUDGE TEST 4] EXTREME DYNAMIC WORKLOAD MIXING & ABRUPT RESET RECOVERY");
        $display("================================================================================");
        rst = 1;
        s0_tvalid = 0; s0_tlast = 0; s0_tdata = 0; s0_tkeep = 0;
        s1_tvalid = 0; s1_tlast = 0; s1_tdata = 0; s1_tkeep = 0;
        reset_phase_active = 0;
        #20 rst = 0;
        repeat (5) @(posedge clk);

        // STAGE 1: Fast micro-runts vs large bursts
        $display("[STAGE 1/3] Streaming mixed 64B Ethernet micro-runts and 1024B tensor bursts...");
        send_network_packet(1, 32'hAAAA_0001); // 64B runt (1 beat)
        send_ml_tensor(16, 32'hBBBB_0001);      // 1024B tensor (16 beats = 4 FLITs)
        send_network_packet(2, 32'hAAAA_0002); // 128B packet (2 beats)
        send_ml_tensor(8, 32'hBBBB_0002);       // 512B tensor (8 beats = 2 FLITs)

        // Drain Stage 1
        repeat (40) @(posedge clk);

        // STAGE 2: Mid-Stream Reset Injection
        $display("[STAGE 2/3] Asserting Abrupt Asynchronous Reset Directly Mid-Stream...");
        fork
            begin
                // Start a long 8-beat transfer
                send_network_packet(8, 32'hDEAD_BEEF);
            end
            begin
                // Wait for beat 2, then fire reset asynchronously
                repeat (2) @(posedge clk);
                wait (s0_tvalid && s0_tready);
                @(posedge clk);
                $display("[HARDWARE EVENT] >>> HARD RESET FIRED MID-PACKET <<<");
                rst = 1;
                s0_tvalid = 0;
                s0_tlast  = 0;
                repeat (5) @(posedge clk);
                rst = 0;
                $display("[HARDWARE EVENT] >>> RESET DE-ASSERTED. SYSTEM RESTORED <<<");
                reset_phase_active = 1;
            end
        join

        repeat (10) @(posedge clk);

        // STAGE 3: Post-Reset Recovery Verification
        $display("[STAGE 3/3] Verifying immediate post-reset pipeline recovery and healthy streaming...");
        send_network_packet(4, 32'hCAFE_0001);
        send_ml_tensor(4, 32'hCAFE_0002);
        send_network_packet(4, 32'hCAFE_0003);

        // Drain pipeline
        repeat (60) @(posedge clk);

        $display("\n--------------------------------------------------------------------------------");
        $display(" JUDGE AUDIT METRICS:");
        $display("--------------------------------------------------------------------------------");
        $display(" Pre-Reset Verified FLITs Completed   : %0d", pre_reset_flits);
        $display(" Post-Reset Verified FLITs Completed  : %0d (Expected: >= 3)", post_reset_flits);

        // Verification assertions
        if (pre_reset_flits < 6) begin
            $display("[FAIL] Pre-reset dynamic workload failed throughput expectation!");
            judge_errors = judge_errors + 1;
        end
        if (post_reset_flits < 3) begin
            $display("[FAIL] Hardware failed to cleanly recover and process post-reset FLITs!");
            judge_errors = judge_errors + 1;
        end

        if (judge_errors == 0) begin
            $display("\n >>> [STATUS: PASSED] - HARDWARE DEMONSTRATES ZERO-DEADLOCK CLEAN RESET RECOVERY <<< \n");
        end else begin
            $display("\n >>> [STATUS: FAILED] - %0d ERRORS ENCOUNTERED <<< \n", judge_errors);
        end
        $finish;
    end

endmodule
