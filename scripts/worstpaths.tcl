# worstpaths.tcl - the failing setup paths of a fit that is already on disk.
#
# A fit that misses timing says only the slack; which registers are at the two
# ends is what says where to put a pipeline stage, and it does not need another
# forty-minute fit to find out - the netlist and the timing netlist are still
# in db/.
#
# THE SECOND REPORT IS THE POINT. One bad endpoint with a wide fan-in fills
# every slot of the first, and then a pipeline stage in front of it only
# uncovers whatever was behind. `-to` with that endpoint removed asks what the
# next one would be, which is what decides whether one refit will do.
#
#   "$QUARTUS_BIN/quartus_sta" -t scripts/worstpaths.tcl
#   EXCLUDE=*line_left* to skip a different endpoint
project_open sgiindy
create_timing_netlist
read_sdc
update_timing_netlist

set excl "*line_left*"
if {[info exists ::env(EXCLUDE)]} { set excl $::env(EXCLUDE) }

puts "==== worst 30 setup paths ===="
report_timing -setup -npaths 30 -detail summary -stdout

puts "==== worst 30 with $excl removed from the endpoints ===="
set keep [remove_from_collection [get_keepers *] [get_keepers $excl]]
report_timing -setup -npaths 3 -detail summary -to $keep -stdout
report_timing -setup -npaths 1 -detail full_path -to $keep -stdout

delete_timing_netlist
project_close
