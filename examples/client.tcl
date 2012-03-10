source tclzmq.tcl

critcl::load

tclzmq::context context 2
tclzmq::socket client context $tclzmq::ZMQ_REQ
client connect "tcp://*:5555"

for {set i 0} {$i < 10} {incr i} {
    tclzmq::message msg -data "Hello @ [clock format [clock seconds]]"
    client send msg 0
    msg close

    tclzmq::message msg
    client recv msg 0
    puts  "Received [msg data]/[msg size]"
    msg close
}

client close
context term

