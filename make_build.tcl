set CRITCL [lindex $argv 1]
set ZMQDIR [file normalize [lindex $argv 2]]
set cmd [list $CRITCL -I \"[file join $ZMQDIR include]\" -L \"[file join $ZMQDIR lib]\" -pkg]
switch -exact -- [lindex $argv 0] {
    package {}
    install { lappend cmd -libdir \"[info library]\" }
}
lappend cmd tclzmq.tcl
set f [open build.sh w]
puts $f [join $cmd " "]
close $f

