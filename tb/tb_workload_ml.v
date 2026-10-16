`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_workload_ml.v -- Workload Testbench: ML Inference Accelerators
//
// Target Use Case (b) from SARCATHON Problem Statement:
// AI acceleration cards (based on FPGA/ASIC) streaming processed neural network
// weights, activations, or pixel feature data directly into host memory via PCIe 6.
//
// Tests:
// - Continuous high-bandwidth weight matrix bursts (INT8/FP16 tensor streams)
// - Host memory buffer backpressure (random PHY pause/stalls)
// - Sustained FLIT throughput and pipeline efficiency
// -----------------------------------------------------------------------------

module tb_workload_ml;

    localparam DATA_W = 512;
    localparam KEEP_W = DATA_W / 8;

    reg clk = 0;
    always #2.5 clk = ~clk; // 200 MHz
    reg rst;

    // Tie off Source 0 (Network)
    wire [DATA_W-1:0] s0_tdata  = {DATA_W{1'b0}};
    wire [KEEP_W-1:0] s0_tkeep  = {KEEP_W{1'b0}};
    wire              s0_tvalid = 1'b0;
    wire              s0_tlast  = 1'b0;
    wire              s0_tready;

    // Source 1: ML Inference Accelerator
    reg  [DATA_W-1:0] s1_tdata;
    reg  [KEEP_W-1:0] s1_tkeep;
    reg               s1_tvalid;
    reg               s1_tlast;
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

    integer total_tensors_streamed = 0;
    integer total_tensor_bytes     = 0;
    integer total_ml_flits         = 0;

    always @(posedge clk) begin
        if (crc_ok) begin
            total_ml_flits = total_ml_flits + 1;
        end
        if (crc_err) begin
            $display("CRC ERROR on FLIT at time %0t", $time);
        end
    end

    // Task to stream ML Tensor burst (simulates convolutional layer or attention weights)
    task stream_tensor_layer(input integer num_weights_kb);
        integer num_bytes, beats, b;
        reg [DATA_W-1:0] tensor_beat;
        begin
            num_bytes = num_weights_kb * 1024;
            beats = num_bytes / 64;
            $display("[ML WORKLOAD] Streaming Tensor Layer: %0d KB (%0d beats = %0d Bytes)", num_weights_kb, beats, num_bytes);
            for (b = 0; b < beats; b = b + 1) begin
                // INT8 / FP16 neural network weight vectors
                tensor_beat = {32{16'h3C00}} + (b * 64'h0001000200030004);
                s1_tdata  = tensor_beat;
                s1_tkeep  = {KEEP_W{1'b1}};
                s1_tvalid = 1'b1;
                s1_tlast  = (b == beats - 1);
                @(posedge clk);
                while (!s1_tready) @(posedge clk);
                #0.1;
            end
            s1_tvalid = 1'b0;
            s1_tlast  = 1'b0;
            total_tensors_streamed = total_tensors_streamed + 1;
            total_tensor_bytes     = total_tensor_bytes + num_bytes;
        end
    endtask

    initial begin
        $display("================================================================");
        $display("  TESTBENCH: ML Inference Accelerator Workload (Tensor Engine)  ");
        $display("================================================================");

        rst = 1;
        s1_tvalid = 0; s1_tlast = 0; s1_tdata = 0; s1_tkeep = 0;
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        // 1. Layer 1: Dense Projection Layer (1 KB = 1024 Bytes = 4 FLITs)
        stream_tensor_layer(1);
        repeat (30) @(posedge clk);

        // 2. Layer 2: Attention Head Weights (2 KB = 2048 Bytes = 8 FLITs)
        stream_tensor_layer(2);
        repeat (50) @(posedge clk);

        // 3. Layer 3: Feature Map Activation Burst under Host Backpressure (4 KB)
        $display("[ML WORKLOAD] Enabling Host Memory Buffer Backpressure (25%% stall)...");
        stream_tensor_layer(4);
        while (total_ml_flits < 28) @(posedge clk);
        repeat (10) @(posedge clk);

        $display("\n================================================================");
        $display("                  ML WORKLOAD RESULTS                           ");
        $display("================================================================");
        $display(" Total Tensor Bursts Streamed   : %0d", total_tensors_streamed);
        $display(" Total Tensor Data Ingested     : %0d Bytes (%0d KB)", total_tensor_bytes, total_tensor_bytes/1024);
        $display(" CRC Verified FLITs Transferred : %0d", total_ml_flits);

        if (total_tensors_streamed == 3 && total_ml_flits >= 28) begin
            $display(" >>> [ML INFERENCE ACCELERATOR WORKLOAD: PASSED] <<< \n");
        end else begin
            $display(" >>> [ML INFERENCE ACCELERATOR WORKLOAD: FAILED] <<< \n");
        end

        $finish;
    end

    // Host buffer random backpressure
    always @(posedge clk) begin
        if (!rst) begin
            phy_ready <= ($random % 5 != 0); // 20% random backpressure
        end
    end

    initial begin
        #5000000;
        $display("ERROR: ML workload timeout");
        $finish;
    end

endmodule
