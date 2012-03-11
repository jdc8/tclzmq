package require tclzmq

tclzmq::context context 1
tclzmq::socket responder context REP
responder bind "tcp://*:5555"

while {1} {
    tclzmq::message request
    responder recv request
    puts "Received [request data]"
    request close

    tclzmq::message reply -data "World @ [clock format [clock seconds]]"
    responder send reply
    reply close
}
responder close
context term

