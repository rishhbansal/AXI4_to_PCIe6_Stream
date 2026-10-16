`timescale 1ns/1ps
// Unit test: drives the generated s2_crc32_beat (DATA_W=64) with the
// classic check string "123456789" split across 8-byte beats and confirms
// crc_part matches the standard CRC-32/802.3 check value 0xCBF43926.
module tb_crc_beat;
    localparam DATA_W = 64;
    localparam N = DATA_W/8;

    reg  [31:0] crc_in;
    reg  [DATA_W-1:0] data;
    reg  [N-1:0] keep;
    wire [31:0] crc_full, crc_part;
    wire [7:0] nvalid;

    s2_crc32_beat #(.DATA_W(DATA_W)) dut (
        .crc_in(crc_in), .data(data), .keep(keep),
        .crc_full(crc_full), .crc_part(crc_part), .nvalid(nvalid)
    );

    integer errors = 0;

    task check_full(input [31:0] exp, input [255:0] name);
        begin
            if (crc_full !== exp) begin
                $display("FAIL: %0s expected crc_full=%08h got %08h", name, exp, crc_full);
                errors = errors + 1;
            end else
                $display("PASS: %0s crc_full=%08h", name, crc_full);
        end
    endtask

    initial begin
        // "123456789" = 9 bytes -> first beat 8 bytes, second beat 1 byte
        crc_in = 32'hFFFFFFFF;
        data = {"9","8","7","6","5","4","3","2","1"}; // index data[7:0]='1' little-endian byte0
        // byte0 must be '1' (0x31): build explicitly to avoid ordering confusion
        data = 64'h0;
        data[7:0]   = "1";
        data[15:8]  = "2";
        data[23:16] = "3";
        data[31:24] = "4";
        data[39:32] = "5";
        data[47:40] = "6";
        data[55:48] = "7";
        data[63:56] = "8";
        keep = 8'hFF;
        #1;
        crc_in = crc_full;

        data = 64'h0;
        data[7:0] = "9";
        keep = 8'h01;
        #1;
        if ((~crc_part) !== 32'hCBF43926) begin
            $display("FAIL: CRC-32 check value expected cbf43926 got %08h", ~crc_part);
            errors = errors + 1;
        end else
            $display("PASS: CRC-32 check value (\"123456789\") = %08h", ~crc_part);

        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
