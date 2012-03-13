#
# Weather update server
# Binds PUB socket to tcp:#*:5556
# Publishes random weather updates
#

package require tclzmq

# Prepare our context and publisher
tclzmq::context context 1
tclzmq::socket publisher context PUB
publisher bind "tcp://*:5556"
publisher bind "ipc://weather.ipc"

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
    tclzmq::message msg -data $data
    publisher send msg
    msg close
}

publisher close
context term
