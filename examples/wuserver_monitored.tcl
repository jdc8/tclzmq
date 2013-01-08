#
# Weather update server
# Binds PUB socket to tcp:#*:5556
# Publishes random weather updates
#

package require zmq

# Log zipcode for debugging, default is NYC, 10001
if {[llength $argv]} {
    set filter $argv
} else {
    set filter {10001}
}

# Prepare our context and publisher
zmq context context

zmq socket publisher context PUB

publisher bind "tcp://*:5556"
if {$::tcl_platform(platform) ne "windows"} {
    publisher bind "ipc://weather.ipc"
}

zmq socket_monitor publisher "inproc://monitor.req" ALL
zmq socket monitor context PAIR
monitor connect "inproc://monitor.req"
proc monitor_callback {args} {
    if {[catch {monitor recv_monitor_event} msg]} {
	puts "monitor callback error: $msg"
    } else {
	puts "Monitor: $msg"
    }
}
monitor readable monitor_callback

# Initialize random number generator
expr {srand([clock seconds])}

while {1} {
    # Get values that will fool the boss
    set zipcode [expr {int(rand()*100000)}]
    set temperature [expr {int(rand()*215)-80}]
    set relhumidity [expr {int(rand()*50)+50}]
    # Send message to all subscribers
    set data [format "%05d %d %d" $zipcode $temperature $relhumidity]
    if {$zipcode in $filter} {
	puts $data
    }
    zmq message msg -data $data
    publisher send_msg msg
    msg destroy
    # Make sure the monitor callback can get called
    update idletasks
}

publisher destroy
context destroy
