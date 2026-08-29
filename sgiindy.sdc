derive_pll_clocks
derive_clock_uncertainty

# ---- core specific constraints ---------------------------------------------
#
# THE SCC'S SERIAL CLOCK IS NOT A CLOCK. `sclk` in sgiindy.sv is a 3.6864 MHz
# square wave built by a numerically controlled oscillator on clk_sys, and it
# is used as DATA - z8530_scc.sv samples it against clk_sys rather than
# clocking anything with it. Left to itself the fitter would find a long
# combinational path through the baud generator and try to close it at the
# system clock, which it does not need to: a UART's bit time is measured in
# thousands of cycles.
#
# It is left unconstrained deliberately rather than cut, because "unconstrained"
# is visible in the timing report and a false path is not.

# The two CPU error outputs and the console byte tap are debug taps with
# nothing driven from them on hardware; sgiindy.sv leaves them unconnected and
# Quartus will strip them.
