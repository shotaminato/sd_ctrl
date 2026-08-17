module sd_card_ctrl_top #(
    parameter int unsigned CLK_FREQ_HZ              = 50_000_000,
    parameter int unsigned SCLK_FREQ_HZ             = 500_000,
    parameter int unsigned UART_BAUD_RATE           = 115200,
    parameter int unsigned ACMD41_MAX_ATTEMPTS      = 1000,
    parameter int unsigned READ_TOKEN_MAX_BYTES     = 8192,
    parameter int unsigned WRITE_RESPONSE_MAX_BYTES = 8192,
    parameter int unsigned WRITE_BUSY_MAX_BYTES     = 65535
) (
    input  logic i_clk,
    input  logic i_rst_n,

    output logic o_cs_n,
    output logic o_sclk,
    output logic o_mosi,
    input  logic i_miso,

    input  logic [9:0] i_addr,

    output logic o_uart_tx
);

    logic [49:0] read_address;
    logic [9:0] addr_q;
    logic [9:0] addr_issued;
    logic [9:0] addr_issued_d;

    logic [2:0] sd_command;
    logic [2:0] sd_result;
    logic clock_event;
    logic command_event;
    logic result_event;
    logic [511:0] read_data;
    logic read_data_valid;
    logic read_data_ready;
    logic read_valid;
    logic read_ready;
    logic read_fire;
    logic read_issued;
    logic read_issued_d;
    logic write_valid = 1'b0;
    logic [49:0] write_address = 50'd0;
    logic [511:0] write_data = 512'd0;
    logic write_ready;

    assign read_address = {40'd0, addr_q};
    assign read_valid = read_ready
                      & ((!read_issued) | (addr_q != addr_issued));
    assign read_fire = read_valid & read_ready;
    assign read_issued_d = read_issued | read_fire;
    assign addr_issued_d =
        (read_fire ? addr_q : '0) |
        ((!read_fire) ? addr_issued : '0);

    `DFFR(addr_q      , i_addr         , 1'b1, i_clk, i_rst_n)
    `DFFR(addr_issued , addr_issued_d  , 1'b1, i_clk, i_rst_n)
    `DFFR(read_issued , read_issued_d  , 1'b1, i_clk, i_rst_n)

    sd_card_ctrl #(
        .CLK_FREQ_HZ              (CLK_FREQ_HZ),
        .SCLK_FREQ_HZ             (SCLK_FREQ_HZ),
        .ACMD41_MAX_ATTEMPTS      (ACMD41_MAX_ATTEMPTS),
        .READ_TOKEN_MAX_BYTES     (READ_TOKEN_MAX_BYTES),
        .WRITE_RESPONSE_MAX_BYTES (WRITE_RESPONSE_MAX_BYTES),
        .WRITE_BUSY_MAX_BYTES     (WRITE_BUSY_MAX_BYTES)
    ) u_sd_card_ctrl (
        .i_clk            (i_clk),
        .i_rst_n          (i_rst_n),
        .o_cs_n           (o_cs_n),
        .o_sclk           (o_sclk),
        .o_mosi           (o_mosi),
        .i_miso           (i_miso),
        .i_read_valid     (read_valid),
        .i_read_address   (read_address),
        .o_read_ready     (read_ready),
        .o_read_data_valid(read_data_valid),
        .o_read_data      (read_data),
        .i_read_data_ready(read_data_ready),
        .i_write_valid    (write_valid),
        .i_write_address  (write_address),
        .i_write_data     (write_data),
        .o_write_ready    (write_ready),
        .o_command        (sd_command),
        .o_result         (sd_result),
        .o_clock_event    (clock_event),
        .o_command_event  (command_event),
        .o_result_event   (result_event)
    );

    uart_tx_top #(
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .UART_BAUD_RATE(UART_BAUD_RATE)
    ) u_uart_tx_top (
        .i_clk            (i_clk),
        .i_rst_n          (i_rst_n),
        .i_command        (sd_command),
        .i_result         (sd_result),
        .i_clock_event    (clock_event),
        .i_command_event  (command_event),
        .i_result_event   (result_event),
        .i_read_data_valid(read_data_valid),
        .i_read_data      (read_data),
        .o_read_data_ready(read_data_ready),
        .o_uart_tx        (o_uart_tx)
    );

endmodule
