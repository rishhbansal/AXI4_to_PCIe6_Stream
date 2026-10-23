`timescale 1ns/1ps

// =============================================================================
// JUDGE BREAK TEST 3: UNRECOVERABLE MULTI-BIT NOISE & TELEMETRY SQUELCH BOUNDARY
// SARCATHON 2026 Hardware Evaluation Suite
//
// Architectural Boundary Tested:
// - Physical PAM4 channel noise introduces 3-bit burst flips in a FLIT.
// - SEC-DED FEC successfully catches this as an uncorrectable fatal error (fec_fatal=1).
//
// Why this breaks / exposes a hardware boundary:
// - In mission-critical enterprise PCIe silicon, when fec_fatal or crc_err triggers,
//   the receiver link layer must SQUELCH (kill) the downstream AXI4-Stream transfer
//   or assert an AXI error strobe (TUSER error flag) so corrupt data never enters memory.
// - This test proves that while our bridge correctly flags fec_fatal on its telemetry bus,
//   it still pushes the corrupted payload out of m_axis_tdata, leaving packet squelching
//   as an external system-level responsibility.
// =============================================================================

module tb_break_burst_noise_packet_loss;

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

    // Severe Multi-Bit Noise Mask
    reg [63:0] corrupt_lane0_mask = 0;
    wire [63:0] noisy_lane0_sym = phy_lane0_sym ^ corrupt_lane0_mask;

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
        .phy_lane0_sym(noisy_lane0_sym), .phy_lane1_sym(phy_lane1_sym),
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

    integer packets_sent = 0;
    integer packets_received = 0;
    integer fatal_errors_seen = 0;

    always @(posedge clk) begin
        if (fec_fatal) fatal_errors_seen = fatal_errors_seen + 1;
        if (rec_tvalid && rec_tready && rec_tlast) begin
            packets_received = packets_received + 1;
        end
    end

    task send_packet(input integer dummy);
        integer b;
        begin
            for (b = 0; b < 4; b = b + 1) begin
                s0_tdata  = {16{32'hFEED_0000}} | b;
                s0_tkeep  = {KEEP_W{1'b1}};
                s0_tvalid = 1'b1;
                s0_tlast  = (b == 3);
                @(posedge clk);
                while (!s0_tready) @(posedge clk);
                #0.1;
            end
            s0_tvalid = 1'b0;
            s0_tlast  = 1'b0;
            packets_sent = packets_sent + 1;
        end
    endtask

    initial begin
        $display("\n================================================================================");
        $display(" [JUDGE BREAK TEST 3] UNRECOVERABLE MULTI-BIT NOISE & TELEMETRY SQUELCH BOUNDARY");
        $display("================================================================================");
        rst = 1;
        s0_tvalid = 0; s0_tlast = 0; s0_tdata = 0; s0_tkeep = 0;
        corrupt_lane0_mask = 0;
        #20 rst = 0;
        repeat (5) @(posedge clk);

        $display("[ATTACK INJECTION] Injecting 3-Bit PAM4 Symbol Burst (Exceeds SEC-DED correction capability)...");
        fork
            send_packet(0);
            begin
                while (!phy_flit_start) @(posedge clk);
                repeat (6) @(posedge clk);
                corrupt_lane0_mask = 64'h7; // Flip 3 bits simultaneously!
                @(posedge clk);
                corrupt_lane0_mask = 0;
            end
        join

        repeat (50) @(posedge clk);

        $display("\n--------------------------------------------------------------------------------");
        $display(" JUDGE AUDIT CONCLUSION:");
        $display("--------------------------------------------------------------------------------");
        $display(" Packets Injected Across Link     : %0d", packets_sent);
        $display(" Fatal Multi-Bit Errors Flagged   : %0d", fatal_errors_seen);
        $display(" Corrupt Packets Emitted to Host  : %0d", packets_received);

        if (fatal_errors_seen >= 1 && packets_received == 0) begin
            $display(" >>> [HARDWARE FOOLPROOF SIGN-OFF] <<<");
            $display(" Successfully verified: When fatal multi-bit corruption occurs, the bridge");
            $display(" asserts fec_fatal AND instantly squelches m_axis_tvalid.");
            $display(" Zero corrupted bytes leaked into host memory!");
        end else begin
            $display(" >>> [CODE BREAK CONFIRMED] <<<");
            $display(" Architectural Limitation: Corrupt payload leaked downstream.");
        end
        $finish;
    end

endmodule
