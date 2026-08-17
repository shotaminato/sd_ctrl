module uart_tx_top #(
    parameter int unsigned CLK_FREQ_HZ    = 50_000_000,
    parameter int unsigned UART_BAUD_RATE = 115200
) (
    input  logic i_clk,
    input  logic i_rst_n,

    input  logic [2:0] i_command,
    input  logic [2:0] i_result,
    input  logic       i_clock_event,
    input  logic       i_command_event,
    input  logic       i_result_event,

    input  logic         i_read_data_valid,
    input  logic [511:0] i_read_data,
    output logic         o_read_data_ready,

    output logic o_uart_tx
);

    localparam int unsigned UART_CLK_FREQ_MHZ = CLK_FREQ_HZ / 1_000_000;
    localparam int unsigned MSG_MAX_BYTES = 16;

    localparam logic [1:0] EVENT_CLOCK  = 2'd1;
    localparam logic [1:0] EVENT_CMD    = 2'd2;
    localparam logic [1:0] EVENT_RESULT = 2'd3;

    localparam logic [2:0] COMMAND_CMD0   = 3'd0;
    localparam logic [2:0] COMMAND_CMD8   = 3'd1;
    localparam logic [2:0] COMMAND_CMD55  = 3'd2;
    localparam logic [2:0] COMMAND_ACMD41 = 3'd3;
    localparam logic [2:0] COMMAND_CMD58  = 3'd4;
    localparam logic [2:0] COMMAND_CMD17  = 3'd5;
    localparam logic [2:0] COMMAND_CMD24  = 3'd6;

    localparam logic [2:0] RESULT_OK      = 3'd1;
    localparam logic [2:0] RESULT_ERROR   = 3'd2;
    localparam logic [2:0] RESULT_TIMEOUT = 3'd3;
    localparam logic [2:0] RESULT_BUSY    = 3'd4;

    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CLOCK_OK       = "80CLK OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_TX        = "CMD0 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_TX        = "CMD8 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_TX       = "CMD55 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_TX      = "ACMD41 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD58_TX       = "CMD58 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_TX       = "CMD17 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD24_TX       = "CMD24 TX\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_OK        = "CMD0 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_OK        = "CMD8 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_OK       = "CMD55 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_OK      = "ACMD41 OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_SD_INIT_OK     = "SD INIT OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_OK       = "CMD17 READ OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD24_OK       = "CMD24 WRITE OK\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_BUSY    = "ACMD41 BUSY\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_ERROR     = "CMD0 R1 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_ERROR     = "CMD8 R7 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_ERROR    = "CMD55 R1 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_ERROR   = "ACMD41 R1 ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD58_ERROR    = "CMD58 OCR ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_ERROR    = "CMD17 READ ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD24_ERROR    = "CMD24 WR ERR\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD0_TIMEOUT   = "CMD0 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD8_TIMEOUT   = "CMD8 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD55_TIMEOUT  = "CMD55 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_ACMD41_TIMEOUT = "ACMD41 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD58_TIMEOUT  = "CMD58 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD17_TIMEOUT  = "CMD17 TIMEOUT\r\n";
    localparam logic [MSG_MAX_BYTES*8-1:0] MSG_CMD24_TIMEOUT  = "CMD24 TIMEOUT\r\n";

    logic [7:0] event_wdata;
    logic event_wvalid;
    logic event_wready;
    logic [7:0] event_rdata;
    logic event_rvalid;
    logic event_rready;

    logic msg_active;
    logic msg_active_d;
    logic msg_start;
    logic [7:0] held_event;
    logic [7:0] held_event_d;
    logic [7:0] active_event;
    logic [1:0] active_event_type;
    logic [2:0] active_command;
    logic [2:0] active_result;
    logic uart_message_active;
    logic [3:0] uart_index;
    logic [3:0] uart_index_d;
    logic uart_fire;
    logic uart_message_done;
    logic [4:0] uart_message_length;
    logic [4:0] uart_byte_number;
    logic [MSG_MAX_BYTES*8-1:0] uart_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_command_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_result_ok_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_result_error_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_result_timeout_message;
    logic [MSG_MAX_BYTES*8-1:0] uart_selected_result_message;
    logic [4:0] uart_command_message_length;
    logic [4:0] uart_result_ok_message_length;
    logic [4:0] uart_result_error_message_length;
    logic [4:0] uart_result_timeout_message_length;
    logic [4:0] uart_selected_result_message_length;

    logic [5:0] read_uart_index;
    logic [5:0] read_uart_index_d;
    logic [5:0] read_uart_byte_number;
    logic read_uart_fire;
    logic read_uart_done;
    logic [7:0] status_uart_data;
    logic [7:0] uart_data;
    logic uart_valid;
    logic uart_ready;

    assign event_wvalid =
        (i_clock_event | i_command_event | i_result_event) & event_wready;
    assign event_wdata =
        (i_clock_event
         ? {EVENT_CLOCK, i_command, i_result} : '0) |
        (i_command_event
         ? {EVENT_CMD, i_command, i_result} : '0) |
        (i_result_event
         ? {EVENT_RESULT, i_command, i_result} : '0);

    fifo #(
        .WIDTH(8),
        .DEPTH(8)
    ) u_event_fifo (
        .i_clk   (i_clk),
        .i_rst_n (i_rst_n),
        .i_wvalid(event_wvalid),
        .o_wready(event_wready),
        .i_wdata (event_wdata),
        .o_rvalid(event_rvalid),
        .i_rready(event_rready),
        .o_rdata (event_rdata)
    );

    assign msg_start = !msg_active & event_rvalid;
    assign event_rready = msg_start;
    assign held_event_d = msg_start ? event_rdata : held_event;
    assign active_event = msg_start ? event_rdata : held_event;
    assign active_event_type = active_event[7:6];
    assign active_command = active_event[5:3];
    assign active_result = active_event[2:0];
    assign uart_message_active = msg_start | msg_active;

    assign uart_command_message =
        ((active_command == COMMAND_CMD0  ) ? MSG_CMD0_TX   : '0) |
        ((active_command == COMMAND_CMD8  ) ? MSG_CMD8_TX   : '0) |
        ((active_command == COMMAND_CMD55 ) ? MSG_CMD55_TX  : '0) |
        ((active_command == COMMAND_ACMD41) ? MSG_ACMD41_TX : '0) |
        ((active_command == COMMAND_CMD58 ) ? MSG_CMD58_TX  : '0) |
        ((active_command == COMMAND_CMD17 ) ? MSG_CMD17_TX  : '0) |
        ((active_command == COMMAND_CMD24 ) ? MSG_CMD24_TX  : '0);

    assign uart_command_message_length =
        ((active_command == COMMAND_CMD0  ) ? 5'd9  : '0) |
        ((active_command == COMMAND_CMD8  ) ? 5'd9  : '0) |
        ((active_command == COMMAND_CMD55 ) ? 5'd10 : '0) |
        ((active_command == COMMAND_ACMD41) ? 5'd11 : '0) |
        ((active_command == COMMAND_CMD58 ) ? 5'd10 : '0) |
        ((active_command == COMMAND_CMD17 ) ? 5'd10 : '0) |
        ((active_command == COMMAND_CMD24 ) ? 5'd10 : '0);

    assign uart_result_ok_message =
        ((active_command == COMMAND_CMD0  ) ? MSG_CMD0_OK    : '0) |
        ((active_command == COMMAND_CMD8  ) ? MSG_CMD8_OK    : '0) |
        ((active_command == COMMAND_CMD55 ) ? MSG_CMD55_OK   : '0) |
        ((active_command == COMMAND_ACMD41) ? MSG_ACMD41_OK  : '0) |
        ((active_command == COMMAND_CMD58 ) ? MSG_SD_INIT_OK : '0) |
        ((active_command == COMMAND_CMD17 ) ? MSG_CMD17_OK   : '0) |
        ((active_command == COMMAND_CMD24 ) ? MSG_CMD24_OK   : '0);

    assign uart_result_ok_message_length =
        ((active_command == COMMAND_CMD0  ) ? 5'd9  : '0) |
        ((active_command == COMMAND_CMD8  ) ? 5'd9  : '0) |
        ((active_command == COMMAND_CMD55 ) ? 5'd10 : '0) |
        ((active_command == COMMAND_ACMD41) ? 5'd11 : '0) |
        ((active_command == COMMAND_CMD58 ) ? 5'd12 : '0) |
        ((active_command == COMMAND_CMD17 ) ? 5'd15 : '0) |
        ((active_command == COMMAND_CMD24 ) ? 5'd16 : '0);

    assign uart_result_error_message =
        ((active_command == COMMAND_CMD0  ) ? MSG_CMD0_ERROR   : '0) |
        ((active_command == COMMAND_CMD8  ) ? MSG_CMD8_ERROR   : '0) |
        ((active_command == COMMAND_CMD55 ) ? MSG_CMD55_ERROR  : '0) |
        ((active_command == COMMAND_ACMD41) ? MSG_ACMD41_ERROR : '0) |
        ((active_command == COMMAND_CMD58 ) ? MSG_CMD58_ERROR  : '0) |
        ((active_command == COMMAND_CMD17 ) ? MSG_CMD17_ERROR  : '0) |
        ((active_command == COMMAND_CMD24 ) ? MSG_CMD24_ERROR  : '0);

    assign uart_result_error_message_length =
        ((active_command == COMMAND_CMD0  ) ? 5'd13 : '0) |
        ((active_command == COMMAND_CMD8  ) ? 5'd13 : '0) |
        ((active_command == COMMAND_CMD55 ) ? 5'd14 : '0) |
        ((active_command == COMMAND_ACMD41) ? 5'd15 : '0) |
        ((active_command == COMMAND_CMD58 ) ? 5'd15 : '0) |
        ((active_command == COMMAND_CMD17 ) ? 5'd16 : '0) |
        ((active_command == COMMAND_CMD24 ) ? 5'd14 : '0);

    assign uart_result_timeout_message =
        ((active_command == COMMAND_CMD0  ) ? MSG_CMD0_TIMEOUT   : '0) |
        ((active_command == COMMAND_CMD8  ) ? MSG_CMD8_TIMEOUT   : '0) |
        ((active_command == COMMAND_CMD55 ) ? MSG_CMD55_TIMEOUT  : '0) |
        ((active_command == COMMAND_ACMD41) ? MSG_ACMD41_TIMEOUT : '0) |
        ((active_command == COMMAND_CMD58 ) ? MSG_CMD58_TIMEOUT  : '0) |
        ((active_command == COMMAND_CMD17 ) ? MSG_CMD17_TIMEOUT  : '0) |
        ((active_command == COMMAND_CMD24 ) ? MSG_CMD24_TIMEOUT  : '0);

    assign uart_result_timeout_message_length =
        ((active_command == COMMAND_CMD0  ) ? 5'd14 : '0) |
        ((active_command == COMMAND_CMD8  ) ? 5'd14 : '0) |
        ((active_command == COMMAND_CMD55 ) ? 5'd15 : '0) |
        ((active_command == COMMAND_ACMD41) ? 5'd16 : '0) |
        ((active_command == COMMAND_CMD58 ) ? 5'd15 : '0) |
        ((active_command == COMMAND_CMD17 ) ? 5'd15 : '0) |
        ((active_command == COMMAND_CMD24 ) ? 5'd14 : '0);

    assign uart_selected_result_message =
        ((active_result == RESULT_OK     ) ? uart_result_ok_message      : '0) |
        ((active_result == RESULT_BUSY   ) ? MSG_ACMD41_BUSY             : '0) |
        ((active_result == RESULT_ERROR  ) ? uart_result_error_message   : '0) |
        ((active_result == RESULT_TIMEOUT) ? uart_result_timeout_message : '0);

    assign uart_selected_result_message_length =
        ((active_result == RESULT_OK     ) ? uart_result_ok_message_length      : '0) |
        ((active_result == RESULT_BUSY   ) ? 5'd13                              : '0) |
        ((active_result == RESULT_ERROR  ) ? uart_result_error_message_length   : '0) |
        ((active_result == RESULT_TIMEOUT) ? uart_result_timeout_message_length : '0);

    assign uart_message =
        ((active_event_type == EVENT_CLOCK ) ? MSG_CLOCK_OK                 : '0) |
        ((active_event_type == EVENT_CMD   ) ? uart_command_message         : '0) |
        ((active_event_type == EVENT_RESULT) ? uart_selected_result_message : '0);

    assign uart_message_length =
        ((active_event_type == EVENT_CLOCK ) ? 5'd10                               : '0) |
        ((active_event_type == EVENT_CMD   ) ? uart_command_message_length         : '0) |
        ((active_event_type == EVENT_RESULT) ? uart_selected_result_message_length : '0);

    assign uart_byte_number = uart_message_active
                            ? (uart_message_length - 5'd1 - {1'b0, uart_index})
                            : 5'd0;
    assign status_uart_data = uart_message_active
                            ? uart_message[uart_byte_number*8 +: 8] : '0;
    assign uart_fire = uart_message_active & uart_ready;
    assign uart_message_done = uart_fire
                             & ({1'b0, uart_index} == (uart_message_length - 5'd1));
    assign msg_active_d =
        (msg_start ? 1'b1 : 1'b0) |
        ((msg_active & !uart_message_done) ? 1'b1 : 1'b0);
    assign uart_index_d = !uart_message_active
                        ? 4'd0
                        : (uart_fire
                           ? (uart_message_done ? 4'd0 : (uart_index + 4'd1))
                           : uart_index);

    `DFFR(msg_active , msg_active_d , 1'b1, i_clk, i_rst_n)
    `DFFR(held_event , held_event_d , 1'b1, i_clk, i_rst_n)
    `DFFR(uart_index , uart_index_d , 1'b1, i_clk, i_rst_n)

    assign read_uart_byte_number = 6'd63 - read_uart_index;
    assign read_uart_fire = i_read_data_valid & !uart_message_active & uart_ready;
    assign read_uart_done =
        read_uart_fire & (read_uart_index == 6'd63);
    assign o_read_data_ready = read_uart_done;
    assign uart_data =
        (uart_message_active ? status_uart_data : '0) |
        ((i_read_data_valid & !uart_message_active)
         ? i_read_data[read_uart_byte_number*8 +: 8] : '0);
    assign uart_valid = uart_message_active
                      | (i_read_data_valid & !uart_message_active);
    assign read_uart_index_d =
        ((!i_read_data_valid | read_uart_done) ? 6'd0 : '0) |
        ((i_read_data_valid & read_uart_fire & !read_uart_done)
         ? (read_uart_index + 6'd1) : '0) |
        ((i_read_data_valid & !read_uart_fire) ? read_uart_index : '0);

    `DFFR(read_uart_index, read_uart_index_d, 1'b1, i_clk, i_rst_n)

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
