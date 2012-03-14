#
#  Synchronized subscriber
#

package require tclzmq

tclzmq::context context 1

# First, connect our subscriber socket
tclzmq::socket subscriber context SUB
subscriber connect "tcp://localhost:5561"
subscriber setsockopt SUBSCRIBE ""

# 0MQ is so fast, we need to wait a while…
after 1000

# Second, synchronize with publisher
tclzmq::socket syncclient context REQ
syncclient connect "tcp://localhost:5562"

# - send a synchronization request
syncclient s_send ""

# - wait for synchronization reply
syncclient s_recv

# Third, get our updates and report how many we got
set update_nbr 0
while {1} {
    set string [subscriber s_recv]
    if {$string eq "END"} {
	break;
    }
    incr update_nbr
}
puts "Received $update_nbr updates"

subscriber close
syncclient close
context term
