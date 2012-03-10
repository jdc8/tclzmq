package require tclzmq

tclzmq::context context 2
tclzmq::socket client context REQ
client connect "tcp://*:5555"

for {set i 0} {$i < 10} {incr i} {
    tclzmq::message msg -data "Hello @ [clock format [clock seconds]]"
    client send msg
    msg close

    tclzmq::message msg
    client recv msg
    puts  "Received [msg data]/[msg size]"
    msg close
}

client close
context term

