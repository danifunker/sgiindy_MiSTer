# One clock, asked for more than it will get, on purpose.
#
# 50 MHz is not the target - it is a probe. Constrain the design at a rate it
# cannot meet and TimeQuest reports the worst path and the achievable Fmax,
# which is the number worth having. The MiSTer N64 core runs this same R4300i
# at 93.75 MHz, so that is the figure to compare against.
create_clock -name CLK_50 -period 20.000 [get_ports {CLK_50}]
derive_clock_uncertainty
set_false_path -from [get_ports {RESET_N SEED}]
set_false_path -to   [get_ports {OUT_BIT LOCKED}]
