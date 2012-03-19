namespace eval ::tclzmq {
    namespace export *
    namespace ensemble create

    proc zmsg_recv {socket} {
	set rt [list]
	lappend rt [$socket s_recv]
	while {[$socket getsockopt RCVMORE]} {
	    lappend rt [$socket s_recv]
	}
	return $rt
    }

    proc zmsg_send {socket msgl} {
	foreach m [lrange $msgl 0 end-1] {
	    $socket s_sendmore $m
	}
	$socket s_send [lindex $msgl end]
    }

    proc zmsg_unwrap {msglnm} {
	upvar $msglnm msgl
	set data ""
	if {[llength $msgl]} {
	    set msgl [lassign $msgl data]
	}
	if {[llength $msgl] && [string length [lindex $msgl 0]] == 0} {
	    set msgl [lassign $msgl empty]
	}
	return $data
    }

    proc zmsg_wrap {msgl data} {
	return [list $data "" {*}$msgl]
    }

    proc zmsg_push {msgl data} {
	return [list $data {*}$msgl]
    }

    proc zmsg_pop {msglnm} {
	upvar $msglnm msgl
	set msgl [lassign $msgl] first
	return $first
    }

    proc zmsg_add {msgl data} {
	return [lappend $msgl $data]
    }

    proc zmsg_dump {msgl} {
	puts stderr "--------------------------------------"
	if {[llength $msgl]} {
	    set m .#[pid]
	    foreach data $msgl {
		tclzmq message $m -data $data
		$m s_dump
		$m close
	    }
	} else {
	    puts stderr "NULL"
	}
    }
}
