namespace eval ::zmq {
    namespace export *
    namespace ensemble create

    proc zmsg_recv {socket} {
	set rt [list]
	lappend rt [$socket recv]
	while {[$socket getsockopt RCVMORE]} {
	    lappend rt [$socket recv]
	}
	return $rt
    }

    proc zmsg_send {socket msgl} {
	foreach m [lrange $msgl 0 end-1] {
	    $socket sendmore $m
	}
	$socket send [lindex $msgl end]
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
	set msgl [lassign $msgl first]
	return $first
    }

    proc zmsg_add {msgl data} {
	return [list $msgl $data]
    }

    proc zmsg_dump {msgl} {
	set rt [list]
	if {[llength $msgl]} {
	    set m .#[pid]
	    foreach data $msgl {
		zmq message $m -data $data
		lappend rt [$m dump]
		$m close
	    }
	} else {
	    lappend rt "NULL"
	}
	return $rt
    }
}
