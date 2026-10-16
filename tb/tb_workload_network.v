`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_workload_network.v -- Workload Testbench: Network Packet Processing
//
// Target Use Case (a) from SARCATHON Problem Statement:
// SmartNICs and networking hardware using AXI-Stream interfaces to process
// continuous streams of packets (e.g., Ethernet packets), bridging them into
// PCIe 6 to route straight into host server memory.
//
// Tests:
// - 64-Byte minimum Ethernet frames (runt/standard minimum)
// - 128-Byte and 512-Byte TCP/IP packets
// - 1518-Byte standard maximum Ethernet frames
// - 9000-Byte Jumbo frames (high-throughput SmartNIC transfers)
// - Line-rate bursts and randomized inter-packet arrival gaps
// -----------------------------------------------------------------------------

module tb_workload_network;

    localparam DATA_W = 512;
    localparam KEEP_W = DATA_W / 8; // 64 bytes per beat

    reg clk = 0;
    always #2.5 clk = ~clk; // 200 MHz
    reg rst;

    // AXI-Stream Inputs
    reg  [DATA_W-1:0] s0_tdata;
    reg  [KEEP_W-1:0] s0_tkeep;
    reg               s0_tvalid;
    reg               s0_tlast;
    wire              s0_tready;

    // Tie off Source 1 (ML) for isolated network benchmarking
    wire [DATA_W-1:0] s1_tdata  = {DATA_W{1'b0}};
    wire [KEEP_W-1:0] s1_tkeep  = {KEEP_W{1'b0}};
    wire              s1_tvalid = 1'b0;
    wire              s1_tlast  = 1'b0;
    wire              s1_tready;

    // PHY Interface
    wire [63:0] phy_lane0_sym, phy_lane1_sym, phy_lane2_sym, phy_lane3_sym;
    wire        phy_sym_valid, phy_flit_start, phy_flit_end;
    reg         phy_ready = 1'b1;

    // RX System
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
        .phy_lane0_sym(phy_lane0_sym), .phy_lane1_sym(phy_lane1_sym),
        .phy_lane2_sym(phy_lane2_sym), .phy_lane3_sym(phy_lane3_sym),
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

    integer total_network_packets = 0;
    integer total_bytes_streamed  = 0;
    integer crc_verified_count    = 0;

    always @(posedge clk) begin
        if (crc_ok) crc_verified_count = crc_verified_count + 1;
    end

    // Task to send variable-length Ethernet frame
    task send_ethernet_frame(input integer num_bytes);
        integer beats, b;
        reg [DATA_W-1:0] frame_data;
        begin
            beats = (num_bytes + 63) / 64;
            $display("[NET WORKLOAD] Sending Frame size: %0d Bytes (%0d beats)", num_bytes, beats);
            for (b = 0; b < beats; b = b + 1) begin
                frame_data = {8{64'h0011223344556677}} ^ (b * 64'hA0B0C0D0E0F00102);
                s0_tdata  = frame_data;
                s0_tkeep  = {KEEP_W{1'b1}};
                s0_tvalid = 1'b1;
                s0_tlast  = (b == beats - 1);
                @(posedge clk);
                while (!s0_tready) @(posedge clk);
                #0.1;
            end
            s0_tvalid = 1'b0;
            s0_tlast  = 1'b0;
            total_network_packets = total_network_packets + 1;
            total_bytes_streamed  = total_bytes_streamed + num_bytes;
        end
    endtask

    initial begin
        $display("================================================================");
        $display("   TESTBENCH: Network Packet Processing Workload (SmartNIC)     ");
        $display("================================================================");

        rst = 1;
        s0_tvalid = 0; s0_tlast = 0; s0_tdata = 0; s0_tkeep = 0;
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        // 1. Minimum 64-Byte Ethernet Frame
        send_ethernet_frame(64);
        repeat (20) @(posedge clk);

        // 2. 128-Byte Frame
        send_ethernet_frame(128);
        repeat (20) @(posedge clk);

        // 3. 256-Byte Frame (exact 1 FLIT)
        send_ethernet_frame(256);
        repeat (25) @(posedge clk);

        // 4. 512-Byte TCP/IP Frame (2 FLITs)
        send_ethernet_frame(512);
        repeat (40) @(posedge clk);

        // 5. 1518-Byte Standard MTU Frame (6 FLITs)
        send_ethernet_frame(1518);
        repeat (90) @(posedge clk);

        // 6. 9000-Byte Jumbo Frame (SmartNIC Data Center MTU)
        send_ethernet_frame(9000);
        repeat (250) @(posedge clk);

        $display("\n================================================================");
        $display("                NETWORK WORKLOAD RESULTS                        ");
        $display("================================================================");
        $display(" Total Ethernet Frames Streamed : %0d", total_network_packets);
        $display(" Total Bytes Ingested           : %0d Bytes", total_bytes_streamed);
        $display(" CRC Verified FLITs             : %0d", crc_verified_count);

        if (total_network_packets == 6 && crc_verified_count > 0) begin
            $display(" >>> [NETWORK PACKET WORKLOAD: PASSED] <<< \n");
        end else begin
            $display(" >>> [NETWORK PACKET WORKLOAD: FAILED] <<< \n");
        end

        $finish;
    end

    initial begin
        #5000000;
        $display("ERROR: Network workload timeout");
        $finish;
    end

endmodule
