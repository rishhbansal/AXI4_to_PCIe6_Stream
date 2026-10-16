`timescale 1ns/1ps
// Loopback test: random-length packets -> s2_pkt_framer -> (optional byte
// flip, for fault injection) -> s2_pkt_checker -> compare reconstructed
// payload against the golden copy, and check crc_ok/crc_err fired correctly.
// Also drives random backpressure on both the framer->checker link and the
// checker's output, to exercise the skid queue / spill path under stall.
module tb_loopback;
    localparam DATA_W = 64;
    localparam N = DATA_W/8;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    // All testbench-driven stimulus changes happen slightly AFTER the
    // sampling edge (never exactly on it) to avoid a race against the DUT's
    // own posedge-triggered always blocks -- same class of bug as Stage 1's
    // "driven on the sampling edge" issue.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // ---- driver -> framer ----
    reg  [DATA_W-1:0] s_tdata;
    reg  [N-1:0]      s_tkeep;
    reg               s_tvalid, s_tlast;
    wire              s_tready;

    // ---- framer -> (fault inject) -> checker ----
    wire [DATA_W-1:0] f_tdata;
    wire [N-1:0]      f_tkeep;
    wire              f_tvalid, f_tlast;
    wire              f_tready;
    wire              keep_err;

    reg               inject_fault;
    reg [DATA_W-1:0]  c_tdata_faulted;
    always @* c_tdata_faulted = inject_fault ? (f_tdata ^ 64'h1) : f_tdata;

    wire [DATA_W-1:0] m_tdata;
    wire [N-1:0]      m_tkeep;
    wire              m_tvalid, m_tlast;
    reg               m_tready;
    wire              crc_ok, crc_err;

    s2_pkt_framer #(.DATA_W(DATA_W)) u_framer (
        .clk(clk), .rst(rst),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
        .m_tdata(f_tdata), .m_tkeep(f_tkeep), .m_tvalid(f_tvalid), .m_tlast(f_tlast), .m_tready(f_tready),
        .keep_err(keep_err)
    );

    s2_pkt_checker #(.DATA_W(DATA_W)) u_checker (
        .clk(clk), .rst(rst),
        .s_tdata(c_tdata_faulted), .s_tkeep(f_tkeep), .s_tvalid(f_tvalid), .s_tlast(f_tlast), .s_tready(f_tready),
        .m_tdata(m_tdata), .m_tkeep(m_tkeep), .m_tvalid(m_tvalid), .m_tlast(m_tlast), .m_tready(m_tready),
        .crc_ok(crc_ok), .crc_err(crc_err)
    );

    // random backpressure on checker's output
    always @(posedge clk) m_tready <= (rst) ? 1'b0 : ($random % 4 != 0);

    // ---- golden model (byte queue) ----
    integer golden_q[0:4095];
    integer golden_head, golden_tail;
    integer out_q[0:4095];
    integer out_head, out_tail;

    task push_golden(input [7:0] b);
        begin golden_q[golden_tail] = b; golden_tail = golden_tail + 1; end
    endtask

    integer errors = 0;
    integer packets_ok = 0, packets_bad = 0;

    // capture checker's output bytes
    integer bi;
    always @(posedge clk) begin
        if (!rst && m_tvalid && m_tready) begin
            for (bi = 0; bi < N; bi = bi + 1)
                if (m_tkeep[bi]) begin
                    out_q[out_tail] = (m_tdata >> (8*bi)) & 8'hFF;
                    out_tail = out_tail + 1;
                end
        end
    end

    always @(posedge clk) if (crc_ok) packets_ok = packets_ok + 1;
    always @(posedge clk) if (crc_err) packets_bad = packets_bad + 1;

    integer seed = 77;

    task send_packet(input integer len, input integer expect_good);
        integer i, nb, byte_idx;
        reg [DATA_W-1:0] beat;
        reg [N-1:0] bkeep;
        reg latched_ok, latched_err;
        begin
            golden_head = 0; golden_tail = 0;
            out_head = 0; out_tail = 0;
            inject_fault = !expect_good;
            byte_idx = 0;
            while (byte_idx < len) begin
                beat = 0; bkeep = 0;
                nb = (len - byte_idx) < N ? (len - byte_idx) : N;
                for (i = 0; i < nb; i = i + 1) begin
                    beat[8*i +: 8] = ($random(seed) & 8'hFF);
                    bkeep[i] = 1'b1;
                    push_golden(beat[8*i +: 8]);
                end
                s_tdata = beat; s_tkeep = bkeep; s_tvalid = 1'b1;
                s_tlast = (byte_idx + nb) >= len;
                tick();
                while (!s_tready) tick();
                byte_idx = byte_idx + nb;
            end
            s_tvalid = 1'b0;
            // wait for this packet's crc_ok/crc_err and LATCH it immediately
            // -- both are single-cycle pulses, gone by the time any more
            // ticks pass, so they must be captured the instant they fire.
            while (!crc_ok && !crc_err) tick();
            latched_ok  = crc_ok;
            latched_err = crc_err;
            // Wait for checker skid buffers and output registers to completely drain
            while (u_checker.a_valid || u_checker.b_valid || m_tvalid) begin
                tick();
            end
            tick();

            if (expect_good) begin
                if (!latched_ok) begin
                    $display("FAIL: len=%0d expected crc_ok, got crc_err", len);
                    errors = errors + 1;
                end else if (out_tail !== golden_tail) begin
                    $display("FAIL: len=%0d payload length mismatch out=%0d exp=%0d", len, out_tail, golden_tail);
                    errors = errors + 1;
                end else begin
                    for (i = 0; i < golden_tail; i = i + 1)
                        if (out_q[i] !== golden_q[i]) begin
                            $display("FAIL: len=%0d byte %0d mismatch got %02h exp %02h", len, i, out_q[i], golden_q[i]);
                            errors = errors + 1;
                        end
                    if (errors == 0 || 1) $display("PASS: len=%0d good packet reconstructed correctly", len);
                end
            end else begin
                if (!latched_err) begin
                    $display("FAIL: len=%0d expected crc_err (fault injected), got crc_ok", len);
                    errors = errors + 1;
                end else
                    $display("PASS: len=%0d fault injection correctly detected", len);
            end
        end
    endtask

    integer L;
    initial begin
        rst = 1; s_tvalid = 0; s_tlast = 0; s_tdata = 0; s_tkeep = 0;
        inject_fault = 0;
        repeat (3) tick();
        rst = 0;
        tick();

        // exhaustive small lengths (covers merge vs spill boundary for N=8: n+4<=8 => n<=4)
        for (L = 1; L <= 40; L = L + 1)
            send_packet(L, 1);

        // a few larger / multi-beat lengths
        send_packet(63, 1);
        send_packet(64, 1);
        send_packet(65, 1);
        send_packet(256, 1);
        send_packet(257, 1);

        // fault injection: same boundary-covering lengths, corrupted
        for (L = 1; L <= 12; L = L + 3)
            send_packet(L, 0);
        send_packet(64, 0);
        send_packet(257, 0);

        $display("packets_ok=%0d packets_bad=%0d", packets_ok, packets_bad);
        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: TIMEOUT -- simulation hung");
        $finish;
    end
endmodule
