# constraints.sdc - Timing constraints for OoO Issue Queue
# Target: 500 MHz (2.0 ns period)
# Process: generic standard cell (scale for target node)

set CLK_PERIOD 2.0
set CLK_NAME   clk

create_clock -name $CLK_NAME -period $CLK_PERIOD [get_ports clk]

# Input arrival: signals from outside core arrive 0.2 ns after clock edge
set_input_delay  -clock $CLK_NAME 0.2 [all_inputs]

# Output required: combinational outputs (issue_valid, issue_src*) captured 0.3 ns before next edge
set_output_delay -clock $CLK_NAME 0.3 [all_outputs]

# Critical path: CAM tag comparison (cdb_tag vs rs_src1_tag[i] for all i in RS_DEPTH)
# plus age-based priority mux (O(RS_DEPTH) compare chain)
# Budget: 1.5 ns combinational, 0.5 ns setup/hold margin
set_max_delay 1.5 -from [get_ports cdb_tag] -to [get_ports issue_valid]
set_max_delay 1.5 -from [get_ports cdb_tag] -to [get_ports issue_src1]
set_max_delay 1.5 -from [get_ports cdb_tag] -to [get_ports issue_src2]

# False paths: rs_rd is trace-only, not on any timing-critical output
set_false_path -from [get_cells rs_rd*]

# Load: typical fanout for a 28nm-class cell
set_load 0.01 [all_outputs]
