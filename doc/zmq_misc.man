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
