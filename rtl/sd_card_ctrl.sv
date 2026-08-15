module sd_card_ctrl #(
    parameter int unsigned CLK_FREQ_HZ   = 50_000_000,
    parameter int unsigned SCLK_FREQ_HZ  = 500_000,
    parameter int unsigned UART_BAUD_RATE = 115200
) (
    input  logic i_clk,
    input  logic i_rst_n,

    output logic o_cs_n,
    output logic o_sclk,
    output logic o_mosi,
    input  logic i_miso,

    output logic o_uart_tx
);

    // -------------------------------------------------------------------------
    // UART message constants
    //
    // Initialization progress and the final CMD0 result are sent as ASCII
    // strings. All messages are right-aligned to the same packed-vector width.
    // -------------------------------------------------------------------------

    localparam int unsigned UART_CLK_FREQ_MHZ = CLK_FREQ_HZ / 1_000_000;
    localparam int unsigned MSG_MAX_BYTES = 14;

    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CLOCK_OK = "80CLK OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD_TX = "CMD0 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD_OK = "CMD0 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_R1_ERROR = "CMD0 R1 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_TIMEOUT = "CMD0 TIMEOUT\r\n";

    // -------------------------------------------------------------------------
    // Controller state and result encoding
    //
    // The FSM generates at least 80 initial clocks, loads CMD0, waits for R1,
    // stops SCLK while it is Low, and finally reports the result over UART.
    // -------------------------------------------------------------------------

    typedef enum logic [3:0] {
        INIT_CLOCKS,
        INIT_STOP,
        MSG_CLOCK,
        LOAD_CMD,
        MSG_CMD,
        TRANSFER,
        TRANSFER_STOP,
        MSG_RESULT,
        DONE
    } state_t;

    typedef enum logic [1:0] {
        RESULT_NONE,
        RESULT_OK,
        RESULT_R1_ERROR,
        RESULT_TIMEOUT
    } result_t;

    // -------------------------------------------------------------------------
    // State registers and transfer indices
    //
    // cmd_index selects the six CMD0 bytes. rx_index discards the six bytes
    // received while CMD0 is transmitted, then counts up to eight R1 attempts.
    // uart_index selects the next character of the active UART message.
    // -------------------------------------------------------------------------

    state_t state;
    state_t state_d;
    result_t result;
    result_t result_d;

    logic [2:0] cmd_index;
    logic [2:0] cmd_index_d;
    logic [3:0] rx_index;
    logic [3:0] rx_index_d;
    logic [3:0] uart_index;
    logic [3:0] uart_index_d;

    // -------------------------------------------------------------------------
    // SPI controller interface
    // -------------------------------------------------------------------------

    logic spi_cs_en;
    logic spi_sclk_en;
    logic [9:0] spi_sclk_count;
    logic [7:0] spi_tx_data;
    logic spi_tx_valid;
    logic spi_tx_ready;
    logic [7:0] spi_rx_data;
    logic spi_rx_valid;
    logic spi_rx_ready;
    logic spi_rx_overflow;
    logic spi_tx_fire;
    logic spi_rx_fire;

    // -------------------------------------------------------------------------
    // UART transmitter interface and message selector
    // -------------------------------------------------------------------------

    logic uart_valid;
    logic uart_ready;
    logic uart_fire;
    logic uart_message_active;
    logic [4:0] uart_message_length;
    logic [MSG_MAX_BYTES*8-1:0] uart_message;
    logic [4:0] uart_byte_number;
    logic [7:0] uart_data;
    logic uart_message_done;

    // -------------------------------------------------------------------------
    // R1 response detection
    // -------------------------------------------------------------------------

    logic r1_valid;
    logic r1_timeout;
    logic transfer_done;

    // -------------------------------------------------------------------------
    // SPI enable control
    //
    // CS remains de-asserted during the initial clock phase. During INIT_STOP
    // and TRANSFER_STOP, SCLK stays enabled until a natural Low phase is seen.
    // -------------------------------------------------------------------------

    assign spi_cs_en =
        (state == TRANSFER     ) |
        (state == TRANSFER_STOP);

    assign spi_sclk_en =
        (state == INIT_CLOCKS  ) |
        (state == INIT_STOP    ) |
        (state == TRANSFER     ) |
        (state == TRANSFER_STOP);

    // -------------------------------------------------------------------------
    // CMD0 transmit data
    //
    // CMD0 consists of command byte 40h, a zero argument, and required CRC 95h.
    // A byte is advanced only when the SPI TX FIFO accepts valid data.
    // -------------------------------------------------------------------------

    assign spi_tx_data = (cmd_index == 3'd0) ? 8'h40
                       : (cmd_index == 3'd5) ? 8'h95
                                             : 8'h00;
    assign spi_tx_valid = state == LOAD_CMD;
    assign spi_tx_fire = spi_tx_valid & spi_tx_ready;

    // -------------------------------------------------------------------------
    // R1 receive and timeout handling
    //
    // Received bytes 0 through 5 overlap the transmitted command and are
    // ignored. A following byte with bit 7 cleared is a valid R1 response.
    // Eight consecutive bytes with bit 7 set are treated as a timeout.
    // -------------------------------------------------------------------------

    assign spi_rx_ready = state == TRANSFER;
    assign spi_rx_fire = spi_rx_valid & spi_rx_ready;
    assign r1_valid = spi_rx_fire & (rx_index >= 4'd6) & !spi_rx_data[7];
    assign r1_timeout = spi_rx_fire & (rx_index == 4'd13) & spi_rx_data[7];
    assign transfer_done = r1_valid | r1_timeout;

    assign result_d = r1_timeout
                    ? RESULT_TIMEOUT
                    : ((spi_rx_data == 8'h01) ? RESULT_OK : RESULT_R1_ERROR);

    // -------------------------------------------------------------------------
    // UART message output
    //
    // The current state/result selects a packed message and its length.
    // Characters advance only on the uart_valid/uart_ready handshake.
    // -------------------------------------------------------------------------

    assign uart_message_active = (state == MSG_CLOCK)
                               | (state == MSG_CMD)
                               | (state == MSG_RESULT);
    assign uart_message_length = (state == MSG_CLOCK) ? 5'd10
                               : (state == MSG_CMD) ? 5'd9
                               : ((result == RESULT_OK) ? 5'd9
                                  : ((result == RESULT_R1_ERROR) ? 5'd13 : 5'd14));
    assign uart_message = (state == MSG_CLOCK) ? MSG_CLOCK_OK
                        : (state == MSG_CMD) ? MSG_CMD_TX
                        : ((result == RESULT_OK) ? MSG_CMD_OK
                           : ((result == RESULT_R1_ERROR) ? MSG_R1_ERROR : MSG_TIMEOUT));
    assign uart_byte_number = uart_message_active
                            ? (uart_message_length - 5'd1 - {1'b0, uart_index})
                            : 5'd0;
    assign uart_data = uart_message[uart_byte_number*8 +: 8];
    assign uart_valid = uart_message_active;
    assign uart_fire = uart_valid & uart_ready;
    assign uart_message_done = uart_fire
                             & ({1'b0, uart_index} == (uart_message_length - 5'd1));

    // -------------------------------------------------------------------------
    // Initialization state machine
    //
    // INIT_CLOCKS   : generate at least 80 clocks while CS is High
    // INIT_STOP     : wait until SCLK is Low before stopping it
    // MSG_CLOCK     : report completion of the initial clocks
    // LOAD_CMD      : enqueue all six CMD0 bytes before asserting CS
    // MSG_CMD       : report that CMD0 is ready to transmit
    // TRANSFER      : transmit CMD0 and poll for an R1 response
    // TRANSFER_STOP : wait until SCLK is Low before deasserting CS
    // MSG_RESULT    : report success, an R1 error, or a timeout
    // DONE          : hold the interface idle until reset
    // -------------------------------------------------------------------------

    assign state_d = (state == INIT_CLOCKS)
                   ? ((spi_sclk_count >= 10'd80) ? INIT_STOP : INIT_CLOCKS)
                   : (state == INIT_STOP)
                     ? (!o_sclk ? MSG_CLOCK : INIT_STOP)
                     : (state == MSG_CLOCK)
                       ? (uart_message_done ? LOAD_CMD : MSG_CLOCK)
                       : (state == LOAD_CMD)
                         ? ((spi_tx_fire & (cmd_index == 3'd5)) ? MSG_CMD : LOAD_CMD)
                         : (state == MSG_CMD)
                           ? (uart_message_done ? TRANSFER : MSG_CMD)
                           : (state == TRANSFER)
                             ? (transfer_done ? TRANSFER_STOP : TRANSFER)
                             : (state == TRANSFER_STOP)
                               ? (!o_sclk ? MSG_RESULT : TRANSFER_STOP)
                               : (state == MSG_RESULT)
                                 ? (uart_message_done ? DONE : MSG_RESULT)
                                 : DONE;

    // -------------------------------------------------------------------------
    // Index next-state logic
    //
    // Each index resets outside its owning phase so a reset or phase change
    // cannot leave a stale command, receive, or message position.
    // -------------------------------------------------------------------------

    assign cmd_index_d = (state != LOAD_CMD)
                       ? 3'd0
                       : (spi_tx_fire ? (cmd_index + 3'd1) : cmd_index);
    assign rx_index_d = (state != TRANSFER)
                      ? 4'd0
                      : (spi_rx_fire ? (rx_index + 4'd1) : rx_index);
    assign uart_index_d = !uart_message_active
                        ? 4'd0
                        : (uart_fire
                           ? (uart_message_done ? 4'd0 : (uart_index + 4'd1))
                           : uart_index);

    // -------------------------------------------------------------------------
    // Sequential registers
    //
    // All state is implemented with rtl_primitive DFF macros. No behavioral
    // sequential block is declared directly in this module.
    // -------------------------------------------------------------------------

    `DFFR_VAL(state, state_d, 1'b1, i_clk, i_rst_n, INIT_CLOCKS)
    `DFFR_VAL(result, result_d, transfer_done, i_clk, i_rst_n, RESULT_NONE)
    `DFFR(cmd_index, cmd_index_d, 1'b1, i_clk, i_rst_n)
    `DFFR(rx_index, rx_index_d, 1'b1, i_clk, i_rst_n)
    `DFFR(uart_index, uart_index_d, 1'b1, i_clk, i_rst_n)

    // -------------------------------------------------------------------------
    // SPI controller instance
    //
    // spi_ctrl generates Mode-0 SCLK, drives the SD pins, and buffers transmit
    // and receive bytes through its valid/ready FIFO interfaces.
    // -------------------------------------------------------------------------

    spi_ctrl #(
        .CLK_FREQ_HZ  (CLK_FREQ_HZ),
        .SCLK_FREQ_HZ (SCLK_FREQ_HZ)
    ) u_spi_ctrl (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_cs_en       (spi_cs_en),
        .i_sclk_en     (spi_sclk_en),
        .o_mosi        (o_mosi),
        .i_miso        (i_miso),
        .o_sclk        (o_sclk),
        .o_sclk_count  (spi_sclk_count),
        .o_cs_n        (o_cs_n),
        .i_tx_data     (spi_tx_data),
        .i_tx_valid    (spi_tx_valid),
        .o_tx_ready    (spi_tx_ready),
        .o_rx_data     (spi_rx_data),
        .o_rx_valid    (spi_rx_valid),
        .i_rx_ready    (spi_rx_ready),
        .o_rx_overflow (spi_rx_overflow)
    );

    // -------------------------------------------------------------------------
    // UART transmitter instance
    //
    // uart_tx serializes each selected status character and provides FIFO
    // backpressure through uart_ready.
    // -------------------------------------------------------------------------

    uart_tx #(
        .BAUD_RATE   (UART_BAUD_RATE),
        .CLK_FREQ_MHZ(UART_CLK_FREQ_MHZ)
    ) u_uart_tx (
        .i_clk   (i_clk),
        .i_rst_n (i_rst_n),
        .o_tx    (o_uart_tx),
        .i_wdata (uart_data),
        .i_wvalid(uart_valid),
        .o_wready(uart_ready)
    );

endmodule