package require tclzmq

critcl::load

tclzmq::context context 1
tclzmq::socket responder context REP
responder bind "tcp://*:5555"

while {1} {
    tclzmq::message request
    responder recv request 0
    puts "Received [request data]"
    request close

    tclzmq::message reply -data "World @ [clock format [clock seconds]]"
    responder send reply 0
    reply close
}
$responder close
$context term

