module sd_card_ctrl #(
    parameter int unsigned CLK_FREQ_HZ          = 50_000_000,
    parameter int unsigned SCLK_FREQ_HZ         = 500_000,
    parameter int unsigned UART_BAUD_RATE       = 115200,
    parameter int unsigned ACMD41_MAX_ATTEMPTS  = 1000,
    parameter int unsigned READ_TOKEN_MAX_BYTES = 8192
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
    // Initialization progress and each command result are sent as ASCII
    // strings. All messages are right-aligned to the same packed-vector width.
    // -------------------------------------------------------------------------

    localparam int unsigned UART_CLK_FREQ_MHZ = CLK_FREQ_HZ / 1_000_000;
    localparam int unsigned MSG_MAX_BYTES = 16;

    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CLOCK_OK       = "80CLK OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_TX        = "CMD0 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_TX        = "CMD8 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_TX       = "CMD55 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_TX      = "ACMD41 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD58_TX       = "CMD58 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_TX       = "CMD17 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_OK        = "CMD0 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_OK        = "CMD8 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_OK       = "CMD55 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_OK      = "ACMD41 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_SD_INIT_OK     = "SD INIT OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_OK       = "CMD17 READ OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_BUSY    = "ACMD41 BUSY\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_ERROR     = "CMD0 R1 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_ERROR     = "CMD8 R7 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_ERROR    = "CMD55 R1 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_ERROR   = "ACMD41 R1 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD58_ERROR    = "CMD58 OCR ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_ERROR    = "CMD17 READ ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_TIMEOUT   = "CMD0 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_TIMEOUT   = "CMD8 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_TIMEOUT  = "CMD55 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_TIMEOUT = "ACMD41 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD58_TIMEOUT  = "CMD58 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_TIMEOUT  = "CMD17 TIMEOUT\r\n";

    // -------------------------------------------------------------------------
    // SD SPI command packets
    // -------------------------------------------------------------------------

    localparam logic [47:0] CMD0_DATA   = 48'h40_00_00_00_00_95;
    localparam logic [47:0] CMD8_DATA   = 48'h48_00_00_01_aa_87;
    localparam logic [47:0] CMD55_DATA  = 48'h77_00_00_00_00_01;
    localparam logic [47:0] ACMD41_DATA = 48'h69_40_00_00_00_01;
    localparam logic [47:0] CMD58_DATA  = 48'h7a_00_00_00_00_01;
    localparam logic [31:0] DEFAULT_READ_ADDRESS = 32'h0000_0000;

    // -------------------------------------------------------------------------
    // Controller state and result encoding
    //
    // The FSM generates at least 80 initial clocks, then performs CMD0, CMD8,
    // CMD55/ACMD41 polling, CMD58, and a CMD17 block read in SD SPI mode.
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
        POST_CLOCKS,
        POST_STOP,
        SEND_READ_DATA,
        DONE
    } state_t;

    typedef enum logic [2:0] {
        RESULT_NONE,
        RESULT_OK,
        RESULT_ERROR,
        RESULT_TIMEOUT,
        RESULT_BUSY
    } result_t;

    typedef enum logic [2:0] {
        COMMAND_CMD0,
        COMMAND_CMD8,
        COMMAND_CMD55,
        COMMAND_ACMD41,
        COMMAND_CMD58,
        COMMAND_CMD17
    } command_t;

    // -------------------------------------------------------------------------
    // State registers and transfer indices
    //
    // Each cmd_index bit selects one of the six active-command bytes.
    // rx_index discards the six bytes received during transmission, then
    // counts R1 attempts.
    // uart_index selects the next character of the active UART message.
    // -------------------------------------------------------------------------

    state_t state;
    state_t state_d;
    state_t result_done_state;
    result_t result;
    result_t result_d;
    result_t cmd0_result;
    result_t cmd8_result;
    result_t cmd55_result;
    result_t acmd41_result;
    result_t cmd58_result;
    result_t cmd17_result;
    command_t command;
    command_t command_d;
    command_t command_after_ok;

    logic [5:0] cmd_index;
    logic [5:0] cmd_index_d;
    logic [3:0] rx_index;
    logic [3:0] rx_index_d;
    logic [3:0] uart_index;
    logic [3:0] uart_index_d;
    logic [15:0] acmd41_attempt_count;
    logic [15:0] acmd41_attempt_count_d;
    logic [15:0] read_token_wait_count;
    logic [15:0] read_token_wait_count_d;
    logic [9:0] read_byte_count;
    logic [9:0] read_byte_count_d;
    logic [9:0] uart_read_count;
    logic [9:0] uart_read_count_d;

    // -------------------------------------------------------------------------
    // SPI controller interface
    // -------------------------------------------------------------------------

    logic spi_cs_en;
    logic spi_sclk_en;
    logic [9:0] spi_sclk_count;
    logic [31:0] read_address;
    logic [47:0] cmd17_data;
    logic [47:0] command_data;
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
    // CMD17 read-data FIFO
    // -------------------------------------------------------------------------

    logic [7:0] read_fifo_data;
    logic read_fifo_write_valid;
    logic read_fifo_write_ready;
    logic read_fifo_valid;
    logic read_fifo_ready;

    // -------------------------------------------------------------------------
    // UART transmitter interface and message selector
    // -------------------------------------------------------------------------

    logic uart_valid;
    logic uart_ready;
    logic uart_fire;
    logic uart_read_active;
    logic uart_read_fire;
    logic uart_read_done;
    logic uart_message_active;
    logic [4:0] uart_message_length;
    logic [MSG_MAX_BYTES*8-1:0] uart_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_command_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_result_ok_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_result_error_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_result_timeout_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_selected_result_message;
    logic [4:0] uart_byte_number;
    logic [4:0] uart_command_message_length;
    logic [4:0] uart_result_ok_message_length;
    logic [4:0] uart_result_error_message_length;
    logic [4:0] uart_result_timeout_message_length;
    logic [4:0] uart_selected_result_message_length;
    logic [7:0] uart_data;
    logic uart_message_done;

    // -------------------------------------------------------------------------
    // R1 response detection
    // -------------------------------------------------------------------------

    logic r1_valid;
    logic r1_timeout;
    logic r1_seen;
    logic r1_seen_d;
    logic [7:0] r1_byte;
    logic [7:0] r1_byte_d;
    logic response_needed;
    logic response_capture;
    logic response_complete;
    logic [1:0] response_index;
    logic [1:0] response_index_d;
    logic [31:0] response_data;
    logic [31:0] response_data_d;
    logic [31:0] response_payload;
    logic transfer_done;
    logic next_command_available;
    logic send_read_data_available;
    logic acmd41_last_attempt;
    logic read_token_seen;
    logic read_token_seen_d;
    logic read_token_valid;
    logic read_token_error;
    logic read_token_timeout;
    logic read_data_capture;
    logic read_block_complete;
    logic cmd17_r1_error;

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
        (state == TRANSFER_STOP) |
        (state == POST_CLOCKS  ) |
        (state == POST_STOP    );

    // -------------------------------------------------------------------------
    // Command transmit data
    //
    // CMD0 and CMD8 use their mandatory valid CRC values. CRC checking is
    // disabled after CMD0, so the remaining commands use an end-bit-only CRC.
    // -------------------------------------------------------------------------

    // read_address is fixed for the initial autonomous read. A future external
    // request interface can replace this assignment with a request-latched
    // address without changing the command serializer.
    assign read_address = DEFAULT_READ_ADDRESS;
    assign cmd17_data = {8'h51, read_address, 8'h01};

    assign command_data =
        ((command == COMMAND_CMD0  ) ? CMD0_DATA   : '0) |
        ((command == COMMAND_CMD8  ) ? CMD8_DATA   : '0) |
        ((command == COMMAND_CMD55 ) ? CMD55_DATA  : '0) |
        ((command == COMMAND_ACMD41) ? ACMD41_DATA : '0) |
        ((command == COMMAND_CMD58 ) ? CMD58_DATA  : '0) |
        ((command == COMMAND_CMD17 ) ? cmd17_data  : '0);

    assign spi_tx_data =
        (cmd_index[0] ? command_data[47:40] : '0) |
        (cmd_index[1] ? command_data[39:32] : '0) |
        (cmd_index[2] ? command_data[31:24] : '0) |
        (cmd_index[3] ? command_data[23:16] : '0) |
        (cmd_index[4] ? command_data[15: 8] : '0) |
        (cmd_index[5] ? command_data[ 7: 0] : '0);

    assign spi_tx_valid = state == LOAD_CMD;
    assign spi_tx_fire = spi_tx_valid & spi_tx_ready;

    // -------------------------------------------------------------------------
    // SPI receive handshake and R1 response detection
    //
    // Received bytes 0 through 5 overlap the transmitted command and are
    // ignored. A response byte with bit 7 cleared is accepted as R1.
    // -------------------------------------------------------------------------

    assign spi_rx_ready = state == TRANSFER;
    assign spi_rx_fire = spi_rx_valid & spi_rx_ready;
    assign response_needed =
        (command == COMMAND_CMD8) | (command == COMMAND_CMD58);
    assign r1_valid =
        spi_rx_fire & !r1_seen & (rx_index >= 4'd6) & !spi_rx_data[7];
    assign r1_timeout =
        spi_rx_fire & !r1_seen & (rx_index == 4'd13) & spi_rx_data[7];

    // -------------------------------------------------------------------------
    // R3/R7 extended response handling
    //
    // CMD8 and CMD58 collect four additional response bytes after R1.
    // -------------------------------------------------------------------------

    assign response_capture = spi_rx_fire & r1_seen & response_needed;
    assign response_complete =
        response_capture & (response_index == 2'd3);
    assign response_payload = {response_data[23:0], spi_rx_data};

    // -------------------------------------------------------------------------
    // CMD17 data-block handling
    //
    // Wait for FEh, store 512 data bytes, then consume two CRC bytes.
    // -------------------------------------------------------------------------

    assign cmd17_r1_error =
        r1_valid & (command == COMMAND_CMD17) & (spi_rx_data != 8'h00);
    assign read_token_valid =
        spi_rx_fire & r1_seen & (command == COMMAND_CMD17)
        & !read_token_seen & (spi_rx_data == 8'hfe);
    assign read_token_error =
        spi_rx_fire & r1_seen & (command == COMMAND_CMD17)
        & !read_token_seen & (spi_rx_data != 8'hff)
        & (spi_rx_data != 8'hfe);
    assign read_token_timeout =
        spi_rx_fire & r1_seen & (command == COMMAND_CMD17)
        & !read_token_seen & (spi_rx_data == 8'hff)
        & (read_token_wait_count >= (READ_TOKEN_MAX_BYTES - 1));
    assign read_data_capture =
        spi_rx_fire & (command == COMMAND_CMD17) & read_token_seen;
    assign read_block_complete =
        read_data_capture & (read_byte_count == 10'd513);
    assign read_fifo_write_valid =
        read_data_capture & (read_byte_count < 10'd512)
        & read_fifo_write_ready;

    // -------------------------------------------------------------------------
    // Transfer completion and command result decoding
    // -------------------------------------------------------------------------

    assign transfer_done =
        r1_timeout |
        (r1_valid & !response_needed & (command != COMMAND_CMD17)) |
        response_complete |
        cmd17_r1_error |
        read_token_error |
        read_token_timeout |
        read_block_complete;

    assign acmd41_last_attempt =
        acmd41_attempt_count >= (ACMD41_MAX_ATTEMPTS - 1);

    assign cmd0_result = (spi_rx_data == 8'h01)
                       ? RESULT_OK : RESULT_ERROR;
    assign cmd8_result =
        ((r1_byte == 8'h01) && (response_payload == 32'h0000_01aa))
        ? RESULT_OK : RESULT_ERROR;
    assign cmd55_result = (spi_rx_data == 8'h01)
                        ? RESULT_OK : RESULT_ERROR;
    assign acmd41_result = result_t'(
        ((spi_rx_data == 8'h00)                             ? RESULT_OK      : '0) |
        (((spi_rx_data == 8'h01) && acmd41_last_attempt   ) ? RESULT_TIMEOUT : '0) |
        (((spi_rx_data == 8'h01) && !acmd41_last_attempt  ) ? RESULT_BUSY    : '0) |
        (((spi_rx_data != 8'h00) && (spi_rx_data != 8'h01)) ? RESULT_ERROR   : '0)
    );
    assign cmd58_result =
        ((r1_byte == 8'h00) && response_payload[31])
        ? RESULT_OK : RESULT_ERROR;
    assign cmd17_result = result_t'(
        (read_block_complete ? RESULT_OK : '0) |
        (read_token_timeout ? RESULT_TIMEOUT : '0) |
        ((cmd17_r1_error | read_token_error) ? RESULT_ERROR : '0)
    );

    assign result_d = result_t'(
        (r1_timeout                                   ? RESULT_TIMEOUT : '0) |
        ((!r1_timeout && (command == COMMAND_CMD0)  ) ? cmd0_result    : '0) |
        ((!r1_timeout && (command == COMMAND_CMD8)  ) ? cmd8_result    : '0) |
        ((!r1_timeout && (command == COMMAND_CMD55) ) ? cmd55_result   : '0) |
        ((!r1_timeout && (command == COMMAND_ACMD41)) ? acmd41_result  : '0) |
        ((!r1_timeout && (command == COMMAND_CMD58) ) ? cmd58_result   : '0) |
        ((!r1_timeout && (command == COMMAND_CMD17) ) ? cmd17_result   : '0)
    );

    `DFFR_VAL(result, result_d, transfer_done, i_clk, i_rst_n, RESULT_NONE)

    // -------------------------------------------------------------------------
    // Response state and receive counters
    // -------------------------------------------------------------------------

    assign r1_seen_d = (state != TRANSFER)
                     ? 1'b0
                     : (r1_valid ? 1'b1 : r1_seen);
    assign r1_byte_d = r1_valid ? spi_rx_data : r1_byte;
    assign response_index_d = (state != TRANSFER)
                            ? 2'd0
                            : (response_capture
                               ? (response_index + 2'd1)
                               : response_index);
    assign response_data_d = (state != TRANSFER)
                           ? 32'd0
                           : (response_capture
                              ? {response_data[23:0], spi_rx_data}
                              : response_data);
    assign read_token_seen_d = (state != TRANSFER)
                             ? 1'b0
                             : (read_token_valid
                                ? 1'b1
                                : read_token_seen);
    assign read_token_wait_count_d =
        ((state != TRANSFER) | read_token_seen | read_token_valid)
        ? 16'd0
        : ((spi_rx_fire & r1_seen & (command == COMMAND_CMD17)
            & (spi_rx_data == 8'hff))
           ? (read_token_wait_count + 16'd1)
           : read_token_wait_count);
    assign read_byte_count_d =
        (state != TRANSFER)
        ? 10'd0
        : (read_data_capture
           ? (read_byte_count + 10'd1)
           : read_byte_count);

    `DFFR(r1_seen              , r1_seen_d              , 1'b1    , i_clk, i_rst_n)
    `DFFR(r1_byte              , r1_byte_d              , r1_valid, i_clk, i_rst_n)
    `DFFR(response_index       , response_index_d       , 1'b1    , i_clk, i_rst_n)
    `DFFR(response_data        , response_data_d        , 1'b1    , i_clk, i_rst_n)
    `DFFR(read_token_seen      , read_token_seen_d      , 1'b1    , i_clk, i_rst_n)
    `DFFR(read_token_wait_count, read_token_wait_count_d, 1'b1    , i_clk, i_rst_n)
    `DFFR(read_byte_count      , read_byte_count_d      , 1'b1    , i_clk, i_rst_n)

    // -------------------------------------------------------------------------
    // UART message output
    //
    // The current state/result selects a packed message and its length.
    // Characters advance only on the uart_valid/uart_ready handshake.
    // -------------------------------------------------------------------------

    assign uart_message_active =
        (state == MSG_CLOCK ) |
        (state == MSG_CMD   ) |
        (state == MSG_RESULT);

    assign uart_command_message =
        ((command == COMMAND_CMD0  ) ? MSG_CMD0_TX   : '0) |
        ((command == COMMAND_CMD8  ) ? MSG_CMD8_TX   : '0) |
        ((command == COMMAND_CMD55 ) ? MSG_CMD55_TX  : '0) |
        ((command == COMMAND_ACMD41) ? MSG_ACMD41_TX : '0) |
        ((command == COMMAND_CMD58 ) ? MSG_CMD58_TX  : '0) |
        ((command == COMMAND_CMD17 ) ? MSG_CMD17_TX  : '0);

    assign uart_command_message_length =
        ((command == COMMAND_CMD0  ) ? 5'd9  : '0) |
        ((command == COMMAND_CMD8  ) ? 5'd9  : '0) |
        ((command == COMMAND_CMD55 ) ? 5'd10 : '0) |
        ((command == COMMAND_ACMD41) ? 5'd11 : '0) |
        ((command == COMMAND_CMD58 ) ? 5'd10 : '0) |
        ((command == COMMAND_CMD17 ) ? 5'd10 : '0);

    assign uart_result_ok_message =
        ((command == COMMAND_CMD0  ) ? MSG_CMD0_OK    : '0) |
        ((command == COMMAND_CMD8  ) ? MSG_CMD8_OK    : '0) |
        ((command == COMMAND_CMD55 ) ? MSG_CMD55_OK   : '0) |
        ((command == COMMAND_ACMD41) ? MSG_ACMD41_OK  : '0) |
        ((command == COMMAND_CMD58 ) ? MSG_SD_INIT_OK : '0) |
        ((command == COMMAND_CMD17 ) ? MSG_CMD17_OK   : '0);

    assign uart_result_ok_message_length =
        ((command == COMMAND_CMD0  ) ? 5'd9  : '0) |
        ((command == COMMAND_CMD8  ) ? 5'd9  : '0) |
        ((command == COMMAND_CMD55 ) ? 5'd10 : '0) |
        ((command == COMMAND_ACMD41) ? 5'd11 : '0) |
        ((command == COMMAND_CMD58 ) ? 5'd12 : '0) |
        ((command == COMMAND_CMD17 ) ? 5'd15 : '0);

    assign uart_result_error_message =
        ((command == COMMAND_CMD0  ) ? MSG_CMD0_ERROR   : '0) |
        ((command == COMMAND_CMD8  ) ? MSG_CMD8_ERROR   : '0) |
        ((command == COMMAND_CMD55 ) ? MSG_CMD55_ERROR  : '0) |
        ((command == COMMAND_ACMD41) ? MSG_ACMD41_ERROR : '0) |
        ((command == COMMAND_CMD58 ) ? MSG_CMD58_ERROR  : '0) |
        ((command == COMMAND_CMD17 ) ? MSG_CMD17_ERROR  : '0);

    assign uart_result_error_message_length =
        ((command == COMMAND_CMD0  ) ? 5'd13 : '0) |
        ((command == COMMAND_CMD8  ) ? 5'd13 : '0) |
        ((command == COMMAND_CMD55 ) ? 5'd14 : '0) |
        ((command == COMMAND_ACMD41) ? 5'd15 : '0) |
        ((command == COMMAND_CMD58 ) ? 5'd15 : '0) |
        ((command == COMMAND_CMD17 ) ? 5'd16 : '0);

    assign uart_result_timeout_message =
        ((command == COMMAND_CMD0  ) ? MSG_CMD0_TIMEOUT   : '0) |
        ((command == COMMAND_CMD8  ) ? MSG_CMD8_TIMEOUT   : '0) |
        ((command == COMMAND_CMD55 ) ? MSG_CMD55_TIMEOUT  : '0) |
        ((command == COMMAND_ACMD41) ? MSG_ACMD41_TIMEOUT : '0) |
        ((command == COMMAND_CMD58 ) ? MSG_CMD58_TIMEOUT  : '0) |
        ((command == COMMAND_CMD17 ) ? MSG_CMD17_TIMEOUT  : '0);

    assign uart_result_timeout_message_length =
        ((command == COMMAND_CMD0  ) ? 5'd14 : '0) |
        ((command == COMMAND_CMD8  ) ? 5'd14 : '0) |
        ((command == COMMAND_CMD55 ) ? 5'd15 : '0) |
        ((command == COMMAND_ACMD41) ? 5'd16 : '0) |
        ((command == COMMAND_CMD58 ) ? 5'd15 : '0) |
        ((command == COMMAND_CMD17 ) ? 5'd15 : '0);

    assign uart_selected_result_message =
        ((result == RESULT_OK     ) ? uart_result_ok_message      : '0) |
        ((result == RESULT_BUSY   ) ? MSG_ACMD41_BUSY             : '0) |
        ((result == RESULT_ERROR  ) ? uart_result_error_message   : '0) |
        ((result == RESULT_TIMEOUT) ? uart_result_timeout_message : '0);

    assign uart_selected_result_message_length =
        ((result == RESULT_OK     ) ? uart_result_ok_message_length      : '0) |
        ((result == RESULT_BUSY   ) ? 5'd13                              : '0) |
        ((result == RESULT_ERROR  ) ? uart_result_error_message_length   : '0) |
        ((result == RESULT_TIMEOUT) ? uart_result_timeout_message_length : '0);

    assign uart_message =
        ((state == MSG_CLOCK ) ? MSG_CLOCK_OK                : '0) |
        ((state == MSG_CMD   ) ? uart_command_message        : '0) |
        ((state == MSG_RESULT) ? uart_selected_result_message : '0);

    assign uart_message_length =
        ((state == MSG_CLOCK ) ? 5'd10                               : '0) |
        ((state == MSG_CMD   ) ? uart_command_message_length         : '0) |
        ((state == MSG_RESULT) ? uart_selected_result_message_length : '0);

    assign uart_byte_number = uart_message_active
                            ? (uart_message_length - 5'd1 - {1'b0, uart_index})
                            : 5'd0;
    assign uart_read_active = state == SEND_READ_DATA;
    assign read_fifo_ready = uart_read_active & uart_ready;
    assign uart_read_fire = read_fifo_valid & read_fifo_ready;
    assign uart_read_done =
        uart_read_fire & (uart_read_count == 10'd511);
    assign uart_data =
        (uart_message_active
         ? uart_message[uart_byte_number*8 +: 8] : '0) |
        ((uart_read_active & read_fifo_valid) ? read_fifo_data : '0);
    assign uart_valid =
        uart_message_active | (uart_read_active & read_fifo_valid);
    assign uart_fire = uart_message_active & uart_ready;
    assign uart_message_done = uart_fire
                             & ({1'b0, uart_index} == (uart_message_length - 5'd1));

    // -------------------------------------------------------------------------
    // Initialization state machine
    //
    // INIT_CLOCKS   : generate at least 80 clocks while CS is High
    // INIT_STOP     : wait until SCLK is Low before stopping it
    // MSG_CLOCK     : report completion of the initial clocks
    // LOAD_CMD      : enqueue all six active-command bytes before asserting CS
    // MSG_CMD       : report that the active command is ready to transmit
    // TRANSFER      : transmit the active command and receive its response
    // TRANSFER_STOP : wait until SCLK is Low before deasserting CS
    // MSG_RESULT    : report success, busy, an error, or a timeout
    // POST_CLOCKS   : provide eight clocks with CS High between commands
    // POST_STOP     : stop the post-command clock while SCLK is Low
    // SEND_READ_DATA: send the 512-byte CMD17 payload over UART
    // DONE          : hold the interface idle until reset
    // -------------------------------------------------------------------------

    assign next_command_available =
        ((result == RESULT_OK) & (command != COMMAND_CMD17)) |
        (result == RESULT_BUSY);
    assign send_read_data_available =
        (result == RESULT_OK) & (command == COMMAND_CMD17);
    assign result_done_state = state_t'(
        (send_read_data_available ? SEND_READ_DATA : '0) |
        (next_command_available ? POST_CLOCKS : '0) |
        ((!send_read_data_available & !next_command_available) ? DONE : '0)
    );

    assign state_d = state_t'(
        ((state == INIT_CLOCKS  ) ? ((spi_sclk_count >= 10'd80)          ? INIT_STOP     : INIT_CLOCKS  ) : '0) |
        ((state == INIT_STOP    ) ? (!o_sclk                             ? MSG_CLOCK     : INIT_STOP    ) : '0) |
        ((state == MSG_CLOCK    ) ? (uart_message_done                   ? LOAD_CMD      : MSG_CLOCK    ) : '0) |
        ((state == LOAD_CMD     ) ? ((spi_tx_fire & cmd_index[5])        ? MSG_CMD       : LOAD_CMD     ) : '0) |
        ((state == MSG_CMD      ) ? (uart_message_done                   ? TRANSFER      : MSG_CMD      ) : '0) |
        ((state == TRANSFER     ) ? (transfer_done                       ? TRANSFER_STOP : TRANSFER     ) : '0) |
        ((state == TRANSFER_STOP) ? (!o_sclk                             ? MSG_RESULT    : TRANSFER_STOP) : '0) |
        ((state == MSG_RESULT   ) ? (uart_message_done                   ? result_done_state : MSG_RESULT) : '0) |
        ((state == POST_CLOCKS  ) ? ((spi_sclk_count >= 10'd8)           ? POST_STOP     : POST_CLOCKS  ) : '0) |
        ((state == POST_STOP    ) ? (!o_sclk                             ? LOAD_CMD      : POST_STOP    ) : '0) |
        ((state == SEND_READ_DATA) ? (uart_read_done                     ? DONE          : SEND_READ_DATA) : '0) |
        ((state == DONE         ) ? (DONE                                                               ) : '0)
    );

    `DFFR_VAL(state, state_d, 1'b1, i_clk, i_rst_n, INIT_CLOCKS)

    assign command_after_ok = command_t'(
        ((command == COMMAND_CMD0  ) ? COMMAND_CMD8   : '0) |
        ((command == COMMAND_CMD8  ) ? COMMAND_CMD55  : '0) |
        ((command == COMMAND_CMD55 ) ? COMMAND_ACMD41 : '0) |
        ((command == COMMAND_ACMD41) ? COMMAND_CMD58  : '0) |
        ((command == COMMAND_CMD58 ) ? COMMAND_CMD17  : '0) |
        ((command == COMMAND_CMD17 ) ? COMMAND_CMD17  : '0)
    );

    assign command_d = command_t'(
        (((state == MSG_RESULT) && uart_message_done
          && (result == RESULT_BUSY)) ?
            COMMAND_CMD55 : '0) |
        (((state == MSG_RESULT) && uart_message_done
          && (result == RESULT_OK)) ?
            command_after_ok : '0) |
        ((!((state == MSG_RESULT) && uart_message_done
            && ((result == RESULT_BUSY) || (result == RESULT_OK)))) ?
            command : '0)
    );

    `DFFR_VAL(command, command_d, 1'b1, i_clk, i_rst_n, COMMAND_CMD0)

    // -------------------------------------------------------------------------
    // Index next-state logic
    //
    // Each index resets outside its owning phase so a reset or phase change
    // cannot leave a stale command, receive, or message position.
    // -------------------------------------------------------------------------

    assign cmd_index_d = (state != LOAD_CMD)
                       ? 6'b00_0001
                       : (spi_tx_fire ? (cmd_index << 1) : cmd_index);
    assign rx_index_d = (state != TRANSFER)
                      ? '0
                      : (spi_rx_fire ? (rx_index + 4'd1) : rx_index);
    assign uart_index_d = !uart_message_active
                        ? '0
                        : (uart_fire
                           ? (uart_message_done ? 4'd0 : (uart_index + 4'd1))
                           : uart_index);
    assign uart_read_count_d = !uart_read_active
                             ? 10'd0
                             : (uart_read_fire
                                ? (uart_read_count + 10'd1)
                                : uart_read_count);
    assign acmd41_attempt_count_d =
        (transfer_done && (command == COMMAND_ACMD41))
        ? (acmd41_attempt_count + 16'd1)
        : acmd41_attempt_count;

    `DFFR_VAL(cmd_index, cmd_index_d, 1'b1, i_clk, i_rst_n, 6'b00_0001)
    `DFFR(rx_index  , rx_index_d  , 1'b1, i_clk, i_rst_n)
    `DFFR(uart_index, uart_index_d, 1'b1, i_clk, i_rst_n)
    `DFFR(uart_read_count, uart_read_count_d, 1'b1, i_clk, i_rst_n)
    `DFFR(acmd41_attempt_count, acmd41_attempt_count_d, 1'b1, i_clk, i_rst_n)

    // -------------------------------------------------------------------------
    // CMD17 read-data FIFO instance
    // -------------------------------------------------------------------------

    fifo #(
        .WIDTH (8),
        .DEPTH (512)
    ) u_read_fifo (
        .i_clk    (i_clk),
        .i_rst_n  (i_rst_n),
        .i_wvalid (read_fifo_write_valid),
        .o_wready (read_fifo_write_ready),
        .i_wdata  (spi_rx_data),
        .o_rvalid (read_fifo_valid),
        .i_rready (read_fifo_ready),
        .o_rdata  (read_fifo_data)
    );

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