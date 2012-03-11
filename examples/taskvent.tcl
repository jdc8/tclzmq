#
# Task ventilator
# Binds PUSH socket to tcp://localhost:5557
# Sends batch of tasks to workers via that socket
#

package require tclzmq

tclzmq::context context 1

tclzmq::socket sender context PUSH
sender bind "tcp://*:5557"

tclzmq::socket sink context PUSH
sink connect "tcp://localhost:5558"

puts -nonewline "Press Enter when the workers are ready: "
flush stdout
gets stdin c
puts "Sending tasks to workers..."

# The first message is "0" and signals start of batch
tclzmq::s_send sink "0"

# Initialize random number generator
expr {srand([clock seconds])}

# Send 100 tasks
set total_msec 0
for {set task_nbr 0} {$task_nbr < 100} {incr task_nbr} {
    set workload [expr {int(rand()*100)+1}]
    incr total_msec $workload
    tclzmq::s_send sender $workload
}
puts "Total expected cost: $total_msec msec"
after 1000

sink close
sender close
context term
