create_clock -period 20.000 -name i_clk [get_ports {i_clk}]
derive_pll_clocks
derive_clock_uncertainty

# External asynchronous inputs enter dedicated synchronizers.
set_false_path -from [get_ports {i_rst_n}]
set_false_path -to [get_ports {o_tx}]