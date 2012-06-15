package require doctools

set on [doctools::new on -format html]
set f [open zmq.man r]
set txt [read $f]
close $f

set f [open zmq.html w]
puts $f [$on format $txt]
close $f

$on destroy
