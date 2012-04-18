package require http

set tkn [http::geturl [lindex $argv 0]]
if {[http::status $tkn] eq "ok"} {
    set f [open [lindex $argv 1] w]
    fconfigure $f -translation binary
    puts -nonewline $f [http::data $tkn]
    close $f
}
http::cleanup $tkn
