
[section Examples]

A weather data publishing server, also found in the [uri {http://zguide.zeromq.org/page:all#Getting-the-Message-Out} {ZeroMQ Guide}]:

[example {#
# Weather update server
# Binds PUB socket to tcp:#*:5556
# Publishes random weather updates
#

package require zmq

# Prepare our context and publisher
zmq context context

zmq socket publisher context PUB
publisher bind "tcp://*:5556"
if {$::tcl_platform(platform) ne "windows"} {
    publisher bind "ipc://weather.ipc"
}

# Initialize random number generator
expr {srand([clock seconds])}

while {1} {
    # Get values that will fool the boss
    set zipcode [expr {int(rand()*100000)}]
    set temperature [expr {int(rand()*215)-80}]
    set relhumidity [expr {int(rand()*50)+50}]
    # Send message to all subscribers
    set data [format "%05d %d %d" $zipcode $temperature $relhumidity]
    if {$zipcode eq "10001"} {
	puts $data
    }
    zmq message msg -data $data
    publisher send_msg msg
    msg destroy
    update idletasks
}

publisher destroy
context destroy}]

And the corresponding client:

[example {#
# Weather update client
# Connects SUB socket to tcp:#localhost:5556
# Collects weather updates and finds avg temp in zipcode
#

package require zmq

# Socket to talk to server
zmq context context
zmq socket subscriber context SUB
subscriber connect "tcp://localhost:5556"

# Subscribe to zipcode, default is NYC, 10001
if {[llength $argv]} {
    set filter [lindex $argv 0]
} else {
    set filter "10001"
}

subscriber setsockopt SUBSCRIBE $filter

# Process updates
set total_temp 0
for {set update_nbr 0} {$update_nbr < 10} {incr update_nbr} {
    zmq message msg
    subscriber recv_msg msg
    lassign [msg data] zipcode temperature relhumidity
    puts [msg data]
    msg close
    incr total_temp $temperature
}

puts "Averate temperatur for zipcode $filter was [expr {$total_temp/$update_nbr}]F"

subscriber destroy
context destroy}]

Or the client rewritten to process the messages from the publisher asynchronously:

[example {#
# Weather update client
# Connects SUB socket to tcp:#localhost:5556
# Collects weather updates and finds avg temp in zipcode
#

package require zmq

# Socket to talk to server
zmq context context
zmq socket subscriber context SUB
subscriber connect "tcp://localhost:5556"

# Subscribe to zipcode, default is NYC, 10001
if {[llength $argv]} {
    set filter [lindex $argv 0]
} else {
    set filter "10001"
}

proc get_weather {} {
    global total_temp cnt done
    set data [subscriber recv]
    puts $data
    lassign $data zipcode temperature relhumidity
    incr total_temp $temperature
    incr cnt
    if {$cnt >= 10} {
	set done 1
    }
}

subscriber setsockopt SUBSCRIBE $filter
set total_temp 0
set cnt 0
subscriber readable get_weather

# Process updates
vwait done

puts "Averate temperatur for zipcode $filter was [expr {$total_temp/$cnt}]F"

subscriber destroy
context destroy}]

More Tcl example can be found in the [uri {http://zguide.zeromq.org/page:all} {ZeroMQ Guide}].
