set f [open build.sh w]
puts $f "critcl -pkg -libdir \"[info library]\" tclzmq.tcl"
close $f

