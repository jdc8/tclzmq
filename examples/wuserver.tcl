#
# Weather update server
# Binds PUB socket to tcp:#*:5556
# Publishes random weather updates
#

package require -exact zmq 3.2

proc monitor {context socket event data} {
    puts "Monitor callback: context=$context, socket=$socket, event=$event, data=$data"
}

# Prepare our context and publisher
puts context
zmq context context

puts pub
zmq socket publisher context PUB
puts bind
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
context destroy
