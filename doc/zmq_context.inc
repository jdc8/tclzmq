[section "Contexts"]

[subsection {Context PACKAGE COMMANDS}]

[list_begin definitions]

[call [cmd {zmq context}] [opt [arg contextName]] [opt [arg {-io_threads <ioThreads>}]]]

This command creates a new ZeroMQ context object and associated Tcl object
command whose name is [arg contextName] if specified or auto generated if not
specified. The object command will be created under the current namespace if the
[arg contextName] is not fully qualified, and in the specified namespace
otherwise. The object command name is returned by this command. The object
command methods are explained in section [sectref {Context OBJECT METHODS}].

[list_end]

[subsection {Context OBJECT METHODS}]

[list_begin definitions]

[call [arg contextName] [method cget] [arg optionName]]

Get context option. See [cmd configure] method for list of supported
options.

[call [arg contextName] [method configure] [opt [arg optionName]] [opt [arg "optionValue optionName optionValue ..."]]]

Query or modify context options.  If no option is specified, returns a list
describing all of the available options. If option is specified with no value,
then the command returns the value for the specified option. If one or more
option-value pairs are specified, then the command modifies the given context
option(s) to have the given value(s); in this case the command returns an empty
string. Supported options with associated data type are:

[list_begin options]
[opt_def IO_THREADS] integer
[opt_def MAX_SOCKETS] integer
[list_end]

[call [arg contextName] [method destroy]]

Destroy the ZeroMQ context and delete the associated Tcl object command.

[call [arg contextName] [method get] [arg optionName]]

Get context option. See [cmd configure] method for list of supported options.

[call [arg contextName] [method set] [arg optionName] [arg optionValue]]

Set context option. See [cmd configure] method for list of supported options.

[list_end]
