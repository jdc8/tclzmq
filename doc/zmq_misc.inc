[section {Socket monitoring}]

[list_begin definitions]

[call [cmd zmq] [method monitor] [arg contextName] [arg socketName] [arg callbackCommand] [opt [arg eventsList]]]

Helper function for monitoring socket events. This function is a wrapper for the
[term {socket monitor}] and [term {socket recv_monitor_event}] commands. The
event dictionary as read with the [term {socket recv_monitor_event}] is
lappended to the callback-command and the callback command is executed each time
one of the specified events is triggered for the specified socket. The
event-loop must be executed in order to be able to receive monitoring callback
in this way.

[list_end]

Supported events for monitoring are:

[list_begin options]
[opt_def ACCEPTED]
[opt_def ACCEPT_FAILED]
[opt_def ALL]
[opt_def BIND_FAILED]
[opt_def CLOSED]
[opt_def CLOSE_FAILED]
[opt_def CONNECTED]
[opt_def CONNECT_DELAYED]
[opt_def CONNECT_RETRIED]
[opt_def DISCONNECTED]
[opt_def LISTENING]
[list_end]

[section {Miscellaneous}]

[list_begin definitions]

[call [cmd {zmq version}]]

Return the ZeroMQ version used by the Tcl wrapper.

[call [cmd {zmq errno}]]

Return the last returned ZeroMQ error code.

[call [cmd {zmq strerror}] [arg errorNumber]]

Return the human readable string for a ZeroMQ error code.

[call [cmd {zmq max_block_time}] [arg blockTime]]

Set maximum blocking time for the Tcl event loop waiting for ZeroMQ event in
micro seconds. Default is 1000 micro seconds.

[list_end]
