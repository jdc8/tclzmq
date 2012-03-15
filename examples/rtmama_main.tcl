#
# Custom routing Router to Mama (ROUTER to REQ) main code
#
# While this example runs in a single process, that is just to make
# it easier to start and stop the example. Each thread has its own
# context and conceptually acts as a separate process.
#

package require tclzmq

tclzmq::context context 1

tclzmq::socket client context ROUTER
client bind "ipc://routing.ipc"

set NBR_WORKERS 10

for {set task_nbr 0} {$task_nbr < $NBR_WORKERS * 10} {incr task_nbr} {
    # LRU worker is next waiting in queue
    set address [client s_recv]
    set empty [client s_recv]
    set ready [client s_recv]
    puts "$task_nbr: $ready"
    client s_sendmore $address
    client s_sendmore ""
    client s_send "This is the workload"
}

# Now ask mamas to shut down and report their results
for {set worker_nbr 0} {$worker_nbr < $NBR_WORKERS} {incr worker_nbr} {
    set address [client s_recv]
    set empty [client s_recv]
    set ready [client s_recv]

    client s_sendmore $address
    client s_sendmore ""
    client s_send "END"
}

client close
context term
