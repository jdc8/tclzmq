# Custom routing Router to Dealer, main part

package require tclzmq

tclzmq::context context 1

tclzmq::socket client context ROUTER
client bind "ipc://routing.ipc"

# Wait for threads to connect, since otherwise the messages
# we send won't be routable.
puts -nonewline "Press Enter when the workers are ready: "
flush stdout
gets stdin c

# Send 10 tasks scattered to A twice as often as B
expr {srand([clock seconds])}

for {set task_nbr 0} {$task_nbr < 10} {incr task_nbr} {
    # Send two message parts, first the address…
    if {[expr {int(rand() * 3)}] > 0} {
	client s_sendmore "A"
    } else {
	client s_sendmore "B"
    }
    # And then the workload
    client s_send "This is the workload"
}

client s_sendmore "A"
client s_send "END"

client s_sendmore "B"
client s_send "END"

client close
context term
