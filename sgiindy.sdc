derive_pll_clocks
derive_clock_uncertainty

# ---- core specific constraints ---------------------------------------------
#
# THE SCC'S SERIAL CLOCK IS A CLOCK, AND IT IS UNCONSTRAINED. `sclk` in
# sgiindy.sv is a 3.6864 MHz square wave made by toggling a register from a
# numerically controlled oscillator on clk_sys, and z8530_scc.sv genuinely
# clocks on it - `always @(posedge sclk_a ...)` at lines 339, 343, 395 and
# half a dozen more. It is a second clock domain, crossed in both directions
# by Gray-coded FIFO pointers and two-flop synchronisers.
#
# (An earlier version of this comment claimed sclk was sampled as data and
# clocked nothing. That was wrong, and it was the sort of wrong that stops the
# next person from looking.)
#
# What follows from that: STA reports "1 Unconstrained Clock" and this is it,
# so nothing inside the serial domain is being timed, and the fitter gave it
# local routing rather than a global network. At 3.6864 MHz through
# shift-register-depth logic there is about 270 ns of slack to lose and it
# will almost certainly work - but "almost certainly" is not a measurement.
#
# It is left unconstrained rather than cut with a false path, because
# "unconstrained" is visible in the timing report and a false path is not.
# THE HONEST FIX IS TO STOP USING IT AS A CLOCK: an NCO output belongs on a
# clock *enable* against clk_sys, which removes the domain, the crossing and
# this comment together. Constraining it here would only make the report
# quiet.

# The two CPU error outputs and the console byte tap are debug taps with
# nothing driven from them on hardware; sgiindy.sv leaves them unconnected and
# Quartus will strip them.
