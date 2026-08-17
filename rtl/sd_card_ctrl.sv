module sd_card_ctrl #(
    parameter int unsigned CLK_FREQ_HZ             = 50_000_000,
    parameter int unsigned SCLK_FREQ_HZ            = 500_000,
    parameter int unsigned ACMD41_MAX_ATTEMPTS     = 1000,
    parameter int unsigned READ_TOKEN_MAX_BYTES    = 8192,
    parameter int unsigned WRITE_RESPONSE_MAX_BYTES = 8192,
    parameter int unsigned WRITE_BUSY_MAX_BYTES    = 65535
) (
    input  logic i_clk,
    input  logic i_rst_n,

    output logic o_cs_n,
    output logic o_sclk,
    output logic o_mosi,
    input  logic i_miso,

    input  logic         i_read_valid,
    input  logic [49:0]  i_read_address,
    output logic         o_read_ready,
    output logic         o_read_data_valid,
    output logic [511:0] o_read_data,
    input  logic         i_read_data_ready,

    input  logic         i_write_valid,
    input  logic [49:0]  i_write_address,
    input  logic [511:0] i_write_data,
    output logic         o_write_ready,

    output logic [2:0] o_command,
    output logic [2:0] o_result,
    output logic       o_clock_event,
    output logic       o_command_event,
    output logic       o_result_event
);

    // -------------------------------------------------------------------------
    // SD SPI command packets
    // -------------------------------------------------------------------------

    localparam logic [47:0] CMD0_DATA   = 48'h40_00_00_00_00_95;
    localparam logic [47:0] CMD8_DATA   = 48'h48_00_00_01_aa_87;
    localparam logic [47:0] CMD55_DATA  = 48'h77_00_00_00_00_01;
    localparam logic [47:0] ACMD41_DATA = 48'h69_40_00_00_00_01;
    localparam logic [47:0] CMD58_DATA  = 48'h7a_00_00_00_00_01;

    // -------------------------------------------------------------------------
    // Controller state and result encoding
    //
    // The FSM generates at least 80 initial clocks, then performs CMD0, CMD8,
    // CMD55/ACMD41 polling, and CMD58. After initialization it accepts
    // request-driven CMD17 reads and CMD24 writes in SD SPI mode.
    // -------------------------------------------------------------------------

    typedef enum logic [3:0] {
        INIT_CLOCKS,
        INIT_STOP,
        LOAD_CMD,
        TRANSFER,
        TRANSFER_STOP,
        POST_CLOCKS,
        POST_STOP,
        WAIT_READ,
        READ_RESPONSE,
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
        COMMAND_CMD17,
        COMMAND_CMD24
    } command_t;

    // -------------------------------------------------------------------------
    // State registers and transfer indices
    //
    // Each cmd_index bit selects one of the six active-command bytes.
    // rx_index discards the six bytes received during transmission, then
    // counts R1 attempts.
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
    result_t cmd24_result;
    command_t command;
    command_t command_d;
    command_t command_after_ok;

    logic [5:0] cmd_index;
    logic [5:0] cmd_index_d;
    logic [3:0] rx_index;
    logic [3:0] rx_index_d;
    logic [15:0] acmd41_attempt_count;
    logic [15:0] acmd41_attempt_count_d;
    logic [15:0] read_token_wait_count;
    logic [15:0] read_token_wait_count_d;
    logic [9:0] read_byte_count;
    logic [9:0] read_byte_count_d;
    logic [49:0] read_request_address;
    logic [511:0] read_data;
    logic [511:0] read_data_d;
    logic [9:0] write_tx_count;
    logic [9:0] write_tx_count_d;
    logic [9:0] write_rx_count;
    logic [9:0] write_rx_count_d;
    logic [15:0] write_response_wait_count;
    logic [15:0] write_response_wait_count_d;
    logic [15:0] write_busy_wait_count;
    logic [15:0] write_busy_wait_count_d;
    logic [49:0] write_request_address;
    logic [511:0] write_data;

    // -------------------------------------------------------------------------
    // SPI controller interface
    // -------------------------------------------------------------------------

    logic spi_cs_en;
    logic spi_sclk_en;
    logic [9:0] spi_sclk_count;
    logic [31:0] read_address;
    logic [31:0] write_address;
    logic [47:0] cmd17_data;
    logic [47:0] cmd24_data;
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
    logic read_response_available;
    logic retry_read_available;
    logic write_done_available;
    logic acmd41_last_attempt;
    logic read_token_seen;
    logic read_token_seen_d;
    logic read_token_valid;
    logic read_token_error;
    logic read_token_timeout;
    logic read_data_capture;
    logic read_data_selected;
    logic read_block_complete;
    logic cmd17_r1_error;
    logic read_request_fire;
    logic read_response_fire;
    logic write_request_fire;
    logic write_payload_tx;
    logic write_payload_done;
    logic write_payload_rx_done;
    logic write_token_tx;
    logic write_data_tx;
    logic write_crc_tx;
    logic write_slice_selected;
    logic [9:0] write_block_index;
    logic [7:0] write_slice_byte;
    logic write_response_seen;
    logic write_response_seen_d;
    logic write_data_accepted;
    logic write_data_accepted_d;
    logic write_response_valid;
    logic write_response_accept;
    logic write_response_error;
    logic write_response_timeout;
    logic write_busy_complete;
    logic write_busy_timeout;
    logic cmd24_r1_error;
    logic command_update;

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

    // The request address represents physical address bits [55:6].
    // Bits [34:3] are the SDHC 512-byte block address, and bits [2:0]
    // select one of the eight 64-byte regions in that block.
    assign read_address = read_request_address[34:3];
    assign write_address = write_request_address[34:3];
    assign cmd17_data = {8'h51, read_address, 8'h01};
    assign cmd24_data = {8'h58, write_address, 8'h01};

    assign command_data =
        ((command == COMMAND_CMD0  ) ? CMD0_DATA   : '0) |
        ((command == COMMAND_CMD8  ) ? CMD8_DATA   : '0) |
        ((command == COMMAND_CMD55 ) ? CMD55_DATA  : '0) |
        ((command == COMMAND_ACMD41) ? ACMD41_DATA : '0) |
        ((command == COMMAND_CMD58 ) ? CMD58_DATA  : '0) |
        ((command == COMMAND_CMD17 ) ? cmd17_data  : '0) |
        ((command == COMMAND_CMD24 ) ? cmd24_data  : '0);

    assign write_payload_done = write_tx_count >= 10'd515;
    assign write_payload_rx_done = write_rx_count >= 10'd515;
    assign write_payload_tx =
        (state == TRANSFER) & (command == COMMAND_CMD24)
        & r1_seen & !write_payload_done
        & (write_tx_count <= write_rx_count);
    assign write_token_tx = write_payload_tx & (write_tx_count == 10'd0);
    assign write_data_tx =
        write_payload_tx
        & (write_tx_count >= 10'd1)
        & (write_tx_count <= 10'd512);
    assign write_crc_tx =
        write_payload_tx
        & (write_tx_count >= 10'd513)
        & (write_tx_count <= 10'd514);
    assign write_block_index = write_tx_count - 10'd1;
    assign write_slice_selected =
        write_data_tx
        & (write_block_index[8:6] == write_request_address[2:0]);
    assign write_slice_byte =
        write_data[(6'd63 - write_block_index[5:0]) * 8 +: 8];

    assign spi_tx_data =
        ((state == LOAD_CMD) & cmd_index[0] ? command_data[47:40] : '0) |
        ((state == LOAD_CMD) & cmd_index[1] ? command_data[39:32] : '0) |
        ((state == LOAD_CMD) & cmd_index[2] ? command_data[31:24] : '0) |
        ((state == LOAD_CMD) & cmd_index[3] ? command_data[23:16] : '0) |
        ((state == LOAD_CMD) & cmd_index[4] ? command_data[15: 8] : '0) |
        ((state == LOAD_CMD) & cmd_index[5] ? command_data[ 7: 0] : '0) |
        (write_token_tx ? 8'hfe : '0) |
        ((write_data_tx & write_slice_selected) ? write_slice_byte : '0) |
        (write_crc_tx ? 8'hff : '0);

    assign spi_tx_valid = (state == LOAD_CMD) | write_payload_tx;
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

    assign response_capture  = spi_rx_fire & r1_seen & response_needed;
    assign response_complete = response_capture & (response_index == 2'd3);
    assign response_payload  = {response_data[23:0], spi_rx_data};

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
    assign read_data_selected =
        read_data_capture
        & (read_byte_count < 10'd512)
        & (read_byte_count[8:6] == read_request_address[2:0]);
    assign read_block_complete =
        read_data_capture & (read_byte_count == 10'd513);

    // -------------------------------------------------------------------------
    // CMD24 data-block handling
    //
    // After R1, send FEh, 512 data bytes, and two CRC bytes. The selected
    // 64-byte region carries the write payload; the rest of the block is 0.
    // Then wait for a data-response token and for the card busy flag to clear.
    // -------------------------------------------------------------------------

    assign cmd24_r1_error =
        r1_valid & (command == COMMAND_CMD24) & (spi_rx_data != 8'h00);
    assign write_response_valid =
        spi_rx_fire & (command == COMMAND_CMD24) & write_payload_rx_done
        & !write_response_seen & (spi_rx_data != 8'hff);
    assign write_response_accept =
        write_response_valid & ((spi_rx_data & 8'h1f) == 8'h05);
    assign write_response_error =
        write_response_valid & ((spi_rx_data & 8'h1f) != 8'h05);
    assign write_response_timeout =
        spi_rx_fire & (command == COMMAND_CMD24) & write_payload_rx_done
        & !write_response_seen & (spi_rx_data == 8'hff)
        & (write_response_wait_count >= (WRITE_RESPONSE_MAX_BYTES - 1));
    assign write_busy_complete =
        spi_rx_fire & write_response_seen & write_data_accepted
        & (spi_rx_data != 8'h00);
    assign write_busy_timeout =
        spi_rx_fire & write_response_seen & write_data_accepted
        & (spi_rx_data == 8'h00)
        & (write_busy_wait_count >= (WRITE_BUSY_MAX_BYTES - 1));

    // -------------------------------------------------------------------------
    // Transfer completion and command result decoding
    // -------------------------------------------------------------------------

    assign transfer_done =
        r1_timeout |
        (r1_valid & !response_needed
         & (command != COMMAND_CMD17) & (command != COMMAND_CMD24)) |
        response_complete |
        cmd17_r1_error |
        read_token_error |
        read_token_timeout |
        read_block_complete |
        cmd24_r1_error |
        write_response_error |
        write_response_timeout |
        write_busy_timeout |
        write_busy_complete;

    assign acmd41_last_attempt =
        acmd41_attempt_count >= (ACMD41_MAX_ATTEMPTS - 1);

    assign cmd0_result = result_t'(
        (spi_rx_data == 8'h01) ? RESULT_OK : RESULT_ERROR);
    assign cmd8_result = result_t'(
        ((r1_byte == 8'h01) && (response_payload == 32'h0000_01aa))
        ? RESULT_OK : RESULT_ERROR);
    assign cmd55_result = result_t'(
        (spi_rx_data == 8'h01) ? RESULT_OK : RESULT_ERROR);
    assign acmd41_result = result_t'(
        ((spi_rx_data == 8'h00)                             ? RESULT_OK      : '0) |
        (((spi_rx_data == 8'h01) && acmd41_last_attempt   ) ? RESULT_TIMEOUT : '0) |
        (((spi_rx_data == 8'h01) && !acmd41_last_attempt  ) ? RESULT_BUSY    : '0) |
        (((spi_rx_data != 8'h00) && (spi_rx_data != 8'h01)) ? RESULT_ERROR   : '0)
    );
    assign cmd58_result = result_t'(
        ((r1_byte == 8'h00) && response_payload[31])
        ? RESULT_OK : RESULT_ERROR);
    assign cmd17_result = result_t'(
        (read_block_complete ? RESULT_OK : '0) |
        (read_token_timeout ? RESULT_TIMEOUT : '0) |
        ((cmd17_r1_error | read_token_error) ? RESULT_ERROR : '0)
    );
    assign cmd24_result = result_t'(
        (write_busy_complete ? RESULT_OK : '0) |
        ((write_response_timeout | write_busy_timeout) ? RESULT_TIMEOUT : '0) |
        ((cmd24_r1_error | write_response_error) ? RESULT_ERROR : '0)
    );

    assign result_d = result_t'(
        (r1_timeout                                   ? RESULT_TIMEOUT : '0) |
        ((!r1_timeout && (command == COMMAND_CMD0)  ) ? cmd0_result    : '0) |
        ((!r1_timeout && (command == COMMAND_CMD8)  ) ? cmd8_result    : '0) |
        ((!r1_timeout && (command == COMMAND_CMD55) ) ? cmd55_result   : '0) |
        ((!r1_timeout && (command == COMMAND_ACMD41)) ? acmd41_result  : '0) |
        ((!r1_timeout && (command == COMMAND_CMD58) ) ? cmd58_result   : '0) |
        ((!r1_timeout && (command == COMMAND_CMD17) ) ? cmd17_result   : '0) |
        ((!r1_timeout && (command == COMMAND_CMD24) ) ? cmd24_result   : '0)
    );

    `DFFR_VAL(result, result_d, transfer_done, i_clk, i_rst_n, RESULT_NONE)

    // -------------------------------------------------------------------------
    // Response state and receive counters
    // -------------------------------------------------------------------------

    assign r1_seen_d = (state == TRANSFER) & (r1_valid | r1_seen);
    
    assign r1_byte_d = r1_valid ? spi_rx_data : r1_byte;
    
    assign response_index_d =
        (state != TRANSFER)
        ? 2'd0
        : (response_capture ? (response_index + 2'd1) : response_index);
    
    assign response_data_d = 
        (state != TRANSFER) 
        ? 32'd0
        : (response_capture ? {response_data[23:0], spi_rx_data} : response_data);
    
    assign read_token_seen_d = 
        (state != TRANSFER)
        ? 1'b0
        : (read_token_valid ? 1'b1 : read_token_seen);

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
        : (read_data_capture ? (read_byte_count + 10'd1) : read_byte_count);

    assign read_data_d =
        (( read_data_selected) ? {read_data[503:0], spi_rx_data} : '0) |
        ((!read_data_selected & !read_request_fire) ? read_data : '0);

    assign write_tx_count_d =
        (state != TRANSFER)
        ? 10'd0
        : ((write_payload_tx & spi_tx_fire)
           ? (write_tx_count + 10'd1)
           : write_tx_count);

    assign write_rx_count_d =
        (state != TRANSFER)
        ? 10'd0
        : ((spi_rx_fire & r1_seen & (command == COMMAND_CMD24)
            & (write_rx_count < 10'd515))
           ? (write_rx_count + 10'd1)
           : write_rx_count);

    assign write_response_seen_d =
        (state != TRANSFER)
        ? 1'b0
        : (write_response_valid ? 1'b1 : write_response_seen);

    assign write_data_accepted_d =
        (state != TRANSFER)
        ? 1'b0
        : (write_response_accept ? 1'b1 : write_data_accepted);

    assign write_response_wait_count_d =
        ((state != TRANSFER) | write_response_seen | write_response_valid
         | !write_payload_rx_done)
        ? 16'd0
        : ((spi_rx_fire & (command == COMMAND_CMD24) & (spi_rx_data == 8'hff))
           ? (write_response_wait_count + 16'd1)
           : write_response_wait_count);

    assign write_busy_wait_count_d =
        ((state != TRANSFER) | !write_response_seen | !write_data_accepted)
        ? 16'd0
        : ((spi_rx_fire & (spi_rx_data == 8'h00))
           ? (write_busy_wait_count + 16'd1)
           : write_busy_wait_count);

    `DFFR(r1_seen              , r1_seen_d              , 1'b1    , i_clk, i_rst_n)
    `DFFR(r1_byte              , r1_byte_d              , r1_valid, i_clk, i_rst_n)
    `DFFR(response_index       , response_index_d       , 1'b1    , i_clk, i_rst_n)
    `DFFR(response_data        , response_data_d        , 1'b1    , i_clk, i_rst_n)
    `DFFR(read_token_seen      , read_token_seen_d      , 1'b1    , i_clk, i_rst_n)
    `DFFR(read_token_wait_count, read_token_wait_count_d, 1'b1    , i_clk, i_rst_n)
    `DFFR(read_byte_count      , read_byte_count_d      , 1'b1    , i_clk, i_rst_n)
    `DFFR(read_request_address , i_read_address         , read_request_fire, i_clk, i_rst_n)
    `DFFR(read_data            , read_data_d            , 1'b1    , i_clk, i_rst_n)
    `DFFR(write_tx_count       , write_tx_count_d       , 1'b1    , i_clk, i_rst_n)
    `DFFR(write_rx_count       , write_rx_count_d       , 1'b1    , i_clk, i_rst_n)
    `DFFR(write_response_seen  , write_response_seen_d  , 1'b1    , i_clk, i_rst_n)
    `DFFR(write_data_accepted  , write_data_accepted_d  , 1'b1    , i_clk, i_rst_n)
    `DFFR(write_response_wait_count, write_response_wait_count_d, 1'b1, i_clk, i_rst_n)
    `DFFR(write_busy_wait_count, write_busy_wait_count_d, 1'b1    , i_clk, i_rst_n)
    `DFFR(write_request_address, i_write_address        , write_request_fire, i_clk, i_rst_n)
    `DFFR(write_data           , i_write_data           , write_request_fire, i_clk, i_rst_n)

    // -------------------------------------------------------------------------
    // Initialization state machine
    //
    // INIT_CLOCKS   : generate at least 80 clocks while CS is High
    // INIT_STOP     : wait until SCLK is Low before stopping it
    // LOAD_CMD      : enqueue all six active-command bytes before asserting CS
    // TRANSFER      : transmit the active command and receive its response
    // TRANSFER_STOP : wait until SCLK is Low before deasserting CS
    // POST_CLOCKS   : provide eight clocks with CS High between commands
    // POST_STOP     : stop the post-command clock while SCLK is Low
    // WAIT_READ     : accept a 64-byte read or write request after initialization
    // READ_RESPONSE : hold the selected 64-byte result until accepted
    // DONE          : hold the interface idle until reset
    // -------------------------------------------------------------------------

    assign o_read_ready = state == WAIT_READ;
    assign read_request_fire = i_read_valid & o_read_ready;
    assign o_write_ready = (state == WAIT_READ) & !i_read_valid;
    assign write_request_fire = i_write_valid & o_write_ready;
    assign o_read_data_valid = state == READ_RESPONSE;
    assign o_read_data = read_data;
    assign read_response_fire = o_read_data_valid & i_read_data_ready;
    assign o_command = command;
    assign o_result = result;
    assign o_clock_event = (state == INIT_STOP) & !o_sclk;
    assign o_command_event = (state == LOAD_CMD) & spi_tx_fire & cmd_index[5];
    assign o_result_event = (state == TRANSFER_STOP) & !o_sclk;
    assign command_update = o_result_event;

    assign next_command_available =
        ((result == RESULT_OK)
         & (command != COMMAND_CMD17)
         & (command != COMMAND_CMD24)) |
        (result == RESULT_BUSY);
    assign read_response_available =
        (result == RESULT_OK) & (command == COMMAND_CMD17);
    assign retry_read_available =
        (result != RESULT_OK) & (command == COMMAND_CMD17);
    assign write_done_available =
        (command == COMMAND_CMD24);
    assign result_done_state = state_t'(
        (read_response_available ? READ_RESPONSE : '0) |
        ((next_command_available | retry_read_available | write_done_available)
         ? POST_CLOCKS : '0) |
        ((!read_response_available
          & !next_command_available
          & !retry_read_available
          & !write_done_available) ? DONE : '0)
    );

    assign state_d = state_t'(
        ((state == INIT_CLOCKS  ) ? ((spi_sclk_count >= 10'd80)          ? INIT_STOP     : INIT_CLOCKS  ) : '0) |
        ((state == INIT_STOP    ) ? (!o_sclk                             ? LOAD_CMD      : INIT_STOP    ) : '0) |
        ((state == LOAD_CMD     ) ? ((spi_tx_fire & cmd_index[5])        ? TRANSFER      : LOAD_CMD     ) : '0) |
        ((state == TRANSFER     ) ? (transfer_done                       ? TRANSFER_STOP : TRANSFER     ) : '0) |
        ((state == TRANSFER_STOP) ? (!o_sclk                             ? result_done_state : TRANSFER_STOP) : '0) |
        ((state == POST_CLOCKS  ) ? ((spi_sclk_count >= 10'd8)           ? POST_STOP     : POST_CLOCKS  ) : '0) |
        ((state == POST_STOP    ) ?
            ((!o_sclk & ((command == COMMAND_CMD17) | (command == COMMAND_CMD24))) ? WAIT_READ : '0) |
            ((!o_sclk & (command != COMMAND_CMD17) & (command != COMMAND_CMD24)) ? LOAD_CMD  : '0) |
            (o_sclk ? POST_STOP : '0) : '0) |
        ((state == WAIT_READ    ) ? ((read_request_fire | write_request_fire) ? LOAD_CMD : WAIT_READ) : '0) |
        ((state == READ_RESPONSE) ? (read_response_fire                  ? POST_CLOCKS   : READ_RESPONSE) : '0) |
        ((state == DONE         ) ? (DONE                                                               ) : '0)
    );

    `DFFR_VAL(state, state_d, 1'b1, i_clk, i_rst_n, INIT_CLOCKS)

    assign command_after_ok = command_t'(
        ((command == COMMAND_CMD0  ) ? COMMAND_CMD8   : '0) |
        ((command == COMMAND_CMD8  ) ? COMMAND_CMD55  : '0) |
        ((command == COMMAND_CMD55 ) ? COMMAND_ACMD41 : '0) |
        ((command == COMMAND_ACMD41) ? COMMAND_CMD58  : '0) |
        ((command == COMMAND_CMD58 ) ? COMMAND_CMD17  : '0) |
        ((command == COMMAND_CMD17 ) ? COMMAND_CMD17  : '0) |
        ((command == COMMAND_CMD24 ) ? COMMAND_CMD24  : '0)
    );

    assign command_d = command_t'(
        ((state == WAIT_READ) && write_request_fire ?
            COMMAND_CMD24 : '0) |
        ((state == WAIT_READ) && read_request_fire ?
            COMMAND_CMD17 : '0) |
        ((state != WAIT_READ) && command_update && (result == RESULT_BUSY) ?
            COMMAND_CMD55 : '0) |
        ((state != WAIT_READ) && command_update && (result == RESULT_OK) ?
            command_after_ok : '0) |
        ((state == WAIT_READ) && !write_request_fire && !read_request_fire ?
            command : '0) |
        ((state != WAIT_READ)
          && (!command_update
              || ((result != RESULT_BUSY) && (result != RESULT_OK))) ?
            command : '0)
    );

    `DFFR_VAL(command, command_d, 1'b1, i_clk, i_rst_n, COMMAND_CMD0)

    // -------------------------------------------------------------------------
    // Index next-state logic
    //
    // Each index resets outside its owning phase so a reset or phase change
    // cannot leave a stale command or receive position.
    // -------------------------------------------------------------------------

    assign cmd_index_d = (state != LOAD_CMD)
                       ? 6'b00_0001
                       : (spi_tx_fire ? (cmd_index << 1) : cmd_index);
    assign rx_index_d = (state != TRANSFER)
                      ? '0
                      : (spi_rx_fire ? (rx_index + 4'd1) : rx_index);
    assign acmd41_attempt_count_d =
        (transfer_done && (command == COMMAND_ACMD41))
        ? (acmd41_attempt_count + 16'd1)
        : acmd41_attempt_count;

    `DFFR_VAL(cmd_index, cmd_index_d, 1'b1, i_clk, i_rst_n, 6'b00_0001)
    `DFFR(rx_index  , rx_index_d  , 1'b1, i_clk, i_rst_n)
    `DFFR(acmd41_attempt_count, acmd41_attempt_count_d, 1'b1, i_clk, i_rst_n)

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

endmodule