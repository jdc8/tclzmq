set f [open build.sh w]
puts $f "[lindex $argv 0] -pkg -libdir \"[info library]\" tclzmq.tcl"
close $f

