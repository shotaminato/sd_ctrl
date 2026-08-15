create_clock -period 20.000 -name i_clk [get_ports {i_clk}]
derive_pll_clocks
derive_clock_uncertainty

# The SPI clock is generated from i_clk by a divide-by-100 fabric divider:
# 50 MHz / 100 = 500 kHz. Keep this ratio synchronized with SCLK_FREQ_HZ.
# Define the clock first at the fabric register Q, then forward it through the
# output buffer so TimeQuest includes both clock-generation and pin delays.
create_generated_clock -name sd_sclk_int -source [get_pins {spi_ctrl:u_spi_ctrl|o_sclk|clk}] -divide_by 100 [get_pins {spi_ctrl:u_spi_ctrl|o_sclk|q}]
create_generated_clock -name sd_sclk     -source [get_pins {spi_ctrl:u_spi_ctrl|o_sclk|q}] [get_ports {o_sclk}]

# Conservative SD SPI timing budget (Mode 0):
#   card input setup/hold: 5 ns
#   card output delay:     0 ns to 14 ns
#   PCB/skew margin:       1 ns
#
# MOSI and CS_N are observed on the rising edge of SCLK. A negative minimum
# output delay represents the receiver hold-time requirement.
set_output_delay -clock [get_clocks {sd_sclk}] -max  6.000 [get_ports {o_mosi o_cs_n}]
set_output_delay -clock [get_clocks {sd_sclk}] -min -6.000 [get_ports {o_mosi o_cs_n}]

# In SPI Mode 0 the card launches MISO on the falling edge of SCLK. The
# minimum includes the 1 ns board/skew uncertainty around a nominal 0 ns tCO.
set_input_delay -clock [get_clocks {sd_sclk}] -clock_fall -max 15.000 [get_ports {i_miso}]
set_input_delay -clock [get_clocks {sd_sclk}] -clock_fall -min -1.000 [get_ports {i_miso}]

# External asynchronous reset enters dedicated reset logic.
set_false_path -from [get_ports {i_rst_n}]

# UART TX has no shared external timing reference; its baud timing is
# generated and verified inside the i_clk domain.
set_false_path -to [get_ports {o_uart_tx}]
