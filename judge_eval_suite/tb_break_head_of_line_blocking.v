`timescale 1ns/1ps

// =============================================================================
// JUDGE BREAK TEST 2: HEAD-OF-LINE BLOCKING & MISSING TLAST LOCKUP
// SARCATHON 2026 Hardware Evaluation Suite
//
// Architectural Boundary Tested:
// - Packet-locking guarantees atomicity, but introduces Head-of-Line (HoL) blocking.
// - Scenario: Source 0 starts a multi-beat packet (Beat 0 with TLAST=0), and then
//   its upstream FIFO runs dry (TVALID falls to 0 indefinitely without sending TLAST).
// - Meanwhile, Source 1 (ML Accelerator) has urgent packets queued with TVALID=1.
//
// Why this breaks / exposes a hardware boundary:
// - In pcie6_crossbar_top.v, the arbiter locks to grant=0 until sel_tlast is seen.
// - When Source 0 halts mid-packet, the arbiter refuses to switch to Source 1.
// - This results in Complete Starvation of Source 1 (s1_axis_tready permanently clamped to 0),
//   proving that the bridge lacks an arbiter timeout watchdog.
// =============================================================================

module tb_break_head_of_line_blocking;

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

    reg  [DATA_W-1:0] s1_tdata;
    reg  [KEEP_W-1:0] s1_tkeep;
    reg               s1_tvalid;
    reg               s1_tlast;
    wire              s1_tready;

    wire [63:0] phy_lane0_sym, phy_lane1_sym, phy_lane2_sym, phy_lane3_sym;
    wire        phy_sym_valid, phy_flit_start, phy_flit_end;
    reg         phy_ready = 1;

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

    integer s1_grant_cycles = 0;
    integer s1_blocked_cycles = 0;

    always @(posedge clk) begin
        if (!rst && s1_tvalid) begin
            if (s1_tready) s1_grant_cycles = s1_grant_cycles + 1;
            else           s1_blocked_cycles = s1_blocked_cycles + 1;
        end
    end

    initial begin
        $display("\n================================================================================");
        $display(" [JUDGE BREAK TEST 2] HEAD-OF-LINE BLOCKING & MISSING TLAST LOCKUP");
        $display("================================================================================");
        rst = 1;
        s0_tvalid = 0; s0_tlast = 0; s0_tdata = 0; s0_tkeep = 0;
        s1_tvalid = 0; s1_tlast = 0; s1_tdata = 0; s1_tkeep = 0;
        #20 rst = 0;
        repeat (5) @(posedge clk);

        // Step 1: Source 0 sends Beat 0 of a packet, but fails to send TLAST
        $display("[ATTACK INJECTION] Source 0 sends Beat 0 (TLAST=0), then halts mid-packet (TVALID=0)...");
        s0_tdata  = {16{32'hDEAD_0000}};
        s0_tkeep  = {KEEP_W{1'b1}};
        s0_tvalid = 1'b1;
        s0_tlast  = 1'b0; // NO TLAST!
        @(posedge clk);
        while (!s0_tready) @(posedge clk);
        #0.1;

        // Source 0 abruptly goes idle without completing its packet
        s0_tvalid = 1'b0;

        // Step 2: Source 1 immediately attempts to stream urgent ML packets
        $display("[ATTACK INJECTION] Source 1 attempts to stream packets with TVALID=1 for 50 cycles...");
        s1_tdata  = {16{32'hBEEF_0000}};
        s1_tkeep  = {KEEP_W{1'b1}};
        s1_tvalid = 1'b1;
        s1_tlast  = 1'b1;

        repeat (50) @(posedge clk);

        $display("\n--------------------------------------------------------------------------------");
        $display(" JUDGE AUDIT CONCLUSION:");
        $display("--------------------------------------------------------------------------------");
        $display(" Source 1 Attempts Active Cycles : %0d", s1_blocked_cycles + s1_grant_cycles);
        $display(" Source 1 Granted Handshakes     : %0d", s1_grant_cycles);
        $display(" Source 1 Starved Cycles         : %0d", s1_blocked_cycles);

        if (s1_grant_cycles == 0 && s1_blocked_cycles >= 50) begin
            $display(" >>> [CODE BREAK CONFIRMED] <<<");
            $display(" Architectural Limitation Identified: Dynamic Arbiter suffers Head-of-Line");
            $display(" blocking. A stalled master holds arbiter lock indefinitely; no timeout watchdog.");
        end else begin
            $display(" [SURPRISE] Arbiter preempted the stalled stream.");
        end
        $finish;
    end

endmodule
