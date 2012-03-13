#
#  Simple message queuing broker
#  Same as request-reply broker but using QUEUE device
#

package require tclzmq

tclzmq::context context 1

#  Socket facing clients
tclzmq::socket frontend context ROUTER
frontend bind "tcp://*:5559"

#  Socket facing services
tclzmq::socket backend context DEALER
backend bind "tcp://*:5560"

#  Start built-in device
tclzmq::device QUEUE frontend backend

#  We never get here…
frontend close
backend close
context term

