set fnm [lindex $argv 0]
set f [open $fnm]
set ll [split [read $f] \n]
close $f

set fails 0

foreach l $ll {
    if {[regexp {^==== .* FAILED$} $l]} {
	puts "$l"
	incr fails
    }
}

exit [expr {$fails != 0}]
