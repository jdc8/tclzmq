[section {Devices}]

[list_begin definitions]

[call [cmd {zmq device}] [arg deviceType] [arg inputSocketName] [arg outputSocketName]]

Start a built-in ZeroMQ device. Known devices are:

[list_begin options]
[opt_def FORWARDER]
[opt_def QUEUE]
[opt_def STREAMER]
[list_end]

[list_end]
