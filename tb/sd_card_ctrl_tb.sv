`timescale 1ns/1ps

module sd_card_ctrl_tb;

    localparam int unsigned CLK_FREQ_HZ = 10_000_000;
    localparam int unsigned SCLK_FREQ_HZ = 1_000_000;
    localparam int unsigned UART_BAUD_RATE = 1_000_000;
    localparam int unsigned UART_CYCLES_PER_BIT = CLK_FREQ_HZ / UART_BAUD_RATE;
    localparam time CLK_PERIOD = 100ns;
    localparam time UART_BIT_PERIOD = CLK_PERIOD * UART_CYCLES_PER_BIT;

    localparam int RESPONSE_OK = 0;
    localparam int RESPONSE_R1_ERROR = 1;
    localparam int RESPONSE_TIMEOUT = 2;

    logic i_clk;
    logic i_rst_n;
    logic o_cs_n;
    logic o_sclk;
    logic o_mosi;
    logic i_miso;
    logic o_uart_tx;

    sd_card_ctrl #(
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .SCLK_FREQ_HZ  (SCLK_FREQ_HZ),
        .UART_BAUD_RATE(UART_BAUD_RATE)
    ) dut (
        .i_clk    (i_clk),
        .i_rst_n  (i_rst_n),
        .o_cs_n   (o_cs_n),
        .o_sclk   (o_sclk),
        .o_mosi   (o_mosi),
        .i_miso   (i_miso),
        .o_uart_tx(o_uart_tx)
    );

    task automatic exchange_byte(
        input logic [7:0] expected_tx,
        input logic [7:0] response,
        input logic first_byte
    );
        if (first_byte) begin
            i_miso = response[7];
        end else begin
            @(negedge o_sclk);
            i_miso = response[7];
        end

        for (int bit_index = 7; bit_index >= 0; bit_index--) begin
            @(posedge o_sclk);
            #1ns;
            if (o_mosi !== expected_tx[bit_index]) begin
                $fatal(1,
                       "MOSI mismatch at bit %0d: expected %0b, got %0b",
                       bit_index, expected_tx[bit_index], o_mosi);
            end
            if (bit_index > 0) begin
                @(negedge o_sclk);
                i_miso = response[bit_index-1];
            end
        end
    endtask

    task automatic receive_uart_byte(output logic [7:0] received);
        @(negedge o_uart_tx);
        #(UART_BIT_PERIOD / 2);
        if (o_uart_tx !== 1'b0) begin
            $fatal(1, "UART start bit is invalid");
        end

        for (int bit_index = 0; bit_index < 8; bit_index++) begin
            #UART_BIT_PERIOD;
            received[bit_index] = o_uart_tx;
        end

        #UART_BIT_PERIOD;
        if (o_uart_tx !== 1'b1) begin
            $fatal(1, "UART stop bit is invalid");
        end
    endtask

    task automatic expect_uart_message(input string expected);
        logic [7:0] received;

        for (int char_index = 0; char_index < expected.len(); char_index++) begin
            receive_uart_byte(received);
            if (received !== expected[char_index]) begin
                $fatal(1,
                       "UART mismatch at character %0d: expected 0x%02x, got 0x%02x",
                       char_index, expected[char_index], received);
            end
        end
    endtask

    task automatic emulate_card(input int response_mode);
        int initial_clock_count;
        logic [7:0] expected_command [0:5];

        expected_command[0] = 8'h40;
        expected_command[1] = 8'h00;
        expected_command[2] = 8'h00;
        expected_command[3] = 8'h00;
        expected_command[4] = 8'h00;
        expected_command[5] = 8'h95;

        initial_clock_count = 0;
        while (o_cs_n === 1'b1) begin
            @(posedge o_sclk or negedge o_cs_n);
            if (o_cs_n === 1'b1) begin
                initial_clock_count++;
                if (o_mosi !== 1'b1) begin
                    $fatal(1, "MOSI must remain High during initial clocks");
                end
            end
        end

        if (initial_clock_count < 80) begin
            $fatal(1,
                   "Only %0d initial SCLK rising edges were generated",
                   initial_clock_count);
        end

        for (int byte_index = 0; byte_index < 6; byte_index++) begin
            exchange_byte(expected_command[byte_index], 8'hff, byte_index == 0);
        end

        if (response_mode == RESPONSE_OK) begin
            exchange_byte(8'hff, 8'h01, 1'b0);
        end else if (response_mode == RESPONSE_R1_ERROR) begin
            exchange_byte(8'hff, 8'h05, 1'b0);
        end else begin
            repeat (8) begin
                exchange_byte(8'hff, 8'hff, 1'b0);
            end
        end

        @(posedge o_cs_n);
        i_miso = 1'b1;
    endtask

    task automatic run_scenario(
        input int response_mode,
        input string final_message
    );
        i_rst_n = 1'b0;
        i_miso = 1'b1;
        repeat (5) @(posedge i_clk);

        if ((o_cs_n !== 1'b1)
            | (o_sclk !== 1'b0)
            | (o_mosi !== 1'b1)
            | (o_uart_tx !== 1'b1)) begin
            $fatal(1, "Reset outputs are incorrect");
        end

        @(negedge i_clk);
        i_rst_n = 1'b1;

        fork
            begin
                emulate_card(response_mode);
            end
            begin
                expect_uart_message("80CLK OK\r\n");
                expect_uart_message("CMD0 TX\r\n");
                expect_uart_message(final_message);
            end
        join

        repeat (UART_CYCLES_PER_BIT + 5) @(posedge i_clk);
        if ((o_cs_n !== 1'b1) | (o_sclk !== 1'b0)) begin
            $fatal(1, "SPI outputs did not return to idle");
        end
    endtask

    initial begin
        i_clk = 1'b0;
        forever #(CLK_PERIOD / 2) i_clk = ~i_clk;
    end

    initial begin
        i_rst_n = 1'b0;
        i_miso = 1'b1;

        run_scenario(RESPONSE_OK, "CMD0 OK\r\n");
        run_scenario(RESPONSE_R1_ERROR, "CMD0 R1 ERR\r\n");
        run_scenario(RESPONSE_TIMEOUT, "CMD0 TIMEOUT\r\n");

        $display("sd_card_ctrl_tb: PASS");
        $finish;
    end

endmodule
