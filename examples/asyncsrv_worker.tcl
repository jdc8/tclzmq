#
# Asynchronous client-to-server (DEALER to ROUTER)
#
# This is our worker task
# Accept a request and reply with the same text a random number of
# times, with random delays between replies.

package require tclzmq

tclzmq context context 1
tclzmq socket worker context DEALER
worker connect "ipc://backend"

expr {srand([pid])}

while {1} {
    # The DEALER socket gives us the address envelope and message
    set address [worker s_recv]
#    worker s_recv
    set content [worker s_recv]

    puts "worker received $content from $address"

    # Send 0..4 replies back
    set replies [expr {int(rand()*5)}]
    for {set reply 0} {$reply < $replies} {incr reply} {
	# Sleep for some fraction of a second
	after [expr {int(rand()*1000) + 1}]
	puts "worker send $content to $address"
	worker s_sendmore $address
#	worker s_sendmore ""
	worker s_send $content
    }
}

