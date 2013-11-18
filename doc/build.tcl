package require doctools

if {[llength $argv]} {
    lassign $argv format
} else {
    set format html
}

set on [doctools::new on -format $format]
set f [open zmq.html w]
puts $f [$on format {[include zmq.man]}]
close $f

$on destroy
