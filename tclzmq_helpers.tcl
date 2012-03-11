namespace eval  ::tclzmq {
    proc s_send {socket data} {
	variable msgid
	set msg [::tclzmq::message msg[incr msgid] -data $data]
	$socket send $msg
	$msg close
    }

    proc s_recv {socket} {
	variable msgid
	set msg [::tclzmq::message msg[incr msgid]]
	$socket recv $msg
	set rt [$msg data]
	$msg close
	return $rt
    }
}
