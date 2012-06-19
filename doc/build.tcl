package require doctools

set on [doctools::new on -format html]
set f [open zmq.html w]
puts $f [$on format {[include zmq.man]}]
close $f

$on destroy
