package require critcl 3

namespace eval ::zmq {
}

critcl::license {Jos Decoster} {LGPLv3 / BSD}
critcl::summary {A Tcl wrapper for the ZeroMQ messaging library}
critcl::description {
    zmq is a Tcl binding for the zeromq library (http://www.zeromq.org/)
    for interprocess communication.
}
critcl::subject ZeroMQ ZMQ 0MQ ;#\u2205MQ
critcl::subject {messaging} {inter process communication} RPC
critcl::subject {message queue} {queue} broadcast communication
critcl::subject {producer - consumer} {publish - subscribe}

critcl::meta origin https://github.com/jdc8/tclzmq

critcl::userconfig define mode {choose mode of ZMQ to build and link against.} {static dynamic}

if {[string match "win32*" [::critcl::targetplatform]]} {
    critcl::clibraries -llibzmq -luuid -lws2_32 -lcomctl32 -lrpcrt4
    switch -exact -- [critcl::userconfig query mode] {
	static {
	    critcl::cflags /DDLL_EXPORT
	}
	dynamic {
	}
    }
} else {
    switch -exact -- [critcl::userconfig query mode] {
	static {
	    critcl::clibraries -l:libzmq.a -lstdc++
	}
	dynamic {
	    critcl::clibraries -lzmq
	}
    }

    critcl::clibraries -lpthread -lm

    if {[string match "macosx*" [::critcl::targetplatform]]} {
	critcl::clibraries -lgcc_eh
    } elseif {[string match "*mingw32*" [::critcl::targetplatform]]} {
	critcl::clibraries -luuid
    } else {
	critcl::clibraries -lrt -luuid
    }
}
#critcl::cflags -ansi -pedantic -Wall


# Get local build configuration
if {[file exists "[file dirname [info script]]/zmq_config.tcl"]} {
    set fd [open "[file dirname [info script]]/zmq_config.tcl"]
    eval [read $fd]
    close $fd
}

critcl::tcl 8.5
critcl::tsources zmq_helper.tcl


critcl::ccode {

#include "errno.h"
#include "string.h"
#include "stdio.h"
#include "zmq.h"
#ifndef _WIN32
#include "pthread.h"
#endif

#ifdef _MSC_VER
    typedef __int64          int64_t;
    typedef unsigned __int64 uint64_t;
#else
#include <stdint.h>
#endif

#ifndef ZMQ_HWM
#define ZMQ_HWM 1
#endif

#if ZMQ_VERSION >= ZMQ_MAKE_VERSION(4, 1, 0)
    /*  Socket event data  */
    typedef struct {
        uint16_t event;  // id of the event as bitfield
        int32_t  value; // value is either error code, fd or reconnect interval
    } zmq_event_t;
#endif

    typedef struct {
	Tcl_Interp* interp;
	Tcl_HashTable* readableCommands;
	Tcl_HashTable* writableCommands;
	Tcl_HashTable* contextClientData;
	Tcl_HashTable* socketClientData;
	int block_time;
	int id;
    } ZmqClientData;

    typedef struct {
	void* context;
	Tcl_Obj* tcl_cmd;
	ZmqClientData* zmqClientData;
    } ZmqContextClientData;

    typedef struct {
	void* context;
	void* socket;
	Tcl_Obj* tcl_cmd;
	ZmqClientData* zmqClientData;
    } ZmqSocketClientData;

    typedef struct {
	void* message;
	Tcl_Obj* tcl_cmd;
	ZmqClientData* zmqClientData;
    } ZmqMessageClientData;

    typedef struct {
	Tcl_Event event; /* Must be first */
	Tcl_Interp* ip;
	Tcl_Obj* cmd;
    } ZmqEvent;

    static int last_zmq_errno = 0;

    static void zmq_free_client_data(void* p) { ckfree(p); }

    static void zmq_ckfree(void* p, void* h) { ckfree(p); }

    static void* known_command(Tcl_Interp* ip, Tcl_Obj* obj, const char* what) {
	Tcl_CmdInfo ci;
	if (!Tcl_GetCommandInfo(ip, Tcl_GetStringFromObj(obj, 0), &ci)) {
	    Tcl_Obj* err;
	    err = Tcl_NewObj();
	    Tcl_AppendToObj(err, what, -1);
	    Tcl_AppendToObj(err, " \"", -1);
	    Tcl_AppendObjToObj(err, obj);
	    Tcl_AppendToObj(err, "\" does not exists", -1);
	    Tcl_SetObjResult(ip, err);
	    return 0;
	}
	return ci.objClientData;
    }

    static void* known_context(Tcl_Interp* ip, Tcl_Obj* obj)
    {
	void* p = known_command(ip, obj, "context");
	if (p)
	    return ((ZmqContextClientData*)p)->context;
	return 0;
    }

    static void* known_socket(Tcl_Interp* ip, Tcl_Obj* obj)
    {
	void* p = known_command(ip, obj, "socket");
	if (p)
	    return ((ZmqSocketClientData*)p)->socket;
	return 0;
    }

    static void* known_message(Tcl_Interp* ip, Tcl_Obj* obj)
    {
	void* p = known_command(ip, obj, "message");
	if (p)
	    return ((ZmqMessageClientData*)p)->message;
	return 0;
    }

    static const char* conames[]      = { "IO_THREADS", "MAX_SOCKETS", NULL };
    static const int   conames_cget[] = { 1,            1 };

    static int get_context_option(Tcl_Interp* ip, Tcl_Obj* obj, int* name)
    {
	enum ExObjCOptionNames { CON_IO_THREADS, CON_MAX_SOCKETS };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, conames, "name", 0, &index) != TCL_OK)
	    return TCL_ERROR;
	switch((enum ExObjCOptionNames)index) {
	case CON_IO_THREADS: *name = ZMQ_IO_THREADS; break;
	case CON_MAX_SOCKETS: *name = ZMQ_MAX_SOCKETS; break;
	}
	return TCL_OK;
    }

    static const char* monames[]      = { "MORE", NULL };
    static const int   monames_cget[] = { 1 };

    static int get_message_option(Tcl_Interp* ip, Tcl_Obj* obj, int* name)
    {
	enum ExObjMOptionNames { MSG_MORE };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, monames, "name", 0, &index) != TCL_OK)
	    return TCL_ERROR;
	switch((enum ExObjMOptionNames)index) {
	case MSG_MORE: *name = ZMQ_MORE; break;
	}
	return TCL_OK;
    }

    static const char* sonames[]      = { "HWM", "SNDHWM", "RCVHWM", "AFFINITY", "IDENTITY", "SUBSCRIBE", "UNSUBSCRIBE",
					  "RATE", "RECOVERY_IVL", "SNDBUF", "RCVBUF", "RCVMORE", "FD", "EVENTS",
					  "TYPE", "LINGER", "RECONNECT_IVL", "BACKLOG", "RECONNECT_IVL_MAX",
					  "MAXMSGSIZE", "MULTICAST_HOPS", "RCVTIMEO", "SNDTIMEO", "LAST_ENDPOINT",
					  "TCP_KEEPALIVE", "TCP_KEEPALIVE_CNT", "TCP_KEEPALIVE_IDLE",
					  "TCP_KEEPALIVE_INTVL", "TCP_ACCEPT_FILTER", "IMMEDIATE",
	                                  "ROUTER_MANDATORY", "XPUB_VERBOSE", "MECHANISM",
					  "PLAIN_SERVER", "PLAIN_USERNAME", "PLAIN_PASSWORD",
					  "CURVE_SERVER", "CURVE_PUBLICKEY", "CURVE_SECRETKEY", "CURVE_SERVERKEY",
					  "PROBE_ROUTER", "REQ_CORRELATE", "REQ_RELAXED", "CONFLATE", "ZAP_DOMAIN",
					  "IPV6", NULL };
    static int         sonames_cget[] = { 0,     1,        1,        1,          1,          0,           0,
                                          1,      1,              1,        1,        1,         0,    1,
                                          1,      1,        1,               1,         1,
                                          1,            1,                1,          1,          1,
                                          1,               1,                   1,
                                          1,                     0,                   1,
                                          0,                  0,              1,
					  1,              1,                1,
					  2,              2,                 2,                 2,
					  0,              0,               0,             0,          1,
					  1,      0 };

    static int get_socket_option(Tcl_Interp* ip, Tcl_Obj* obj, int* name)
    {
	enum ExObjOptionNames { ON_HWM, ON_SNDHWM, ON_RCVHWM, ON_AFFINITY, ON_IDENTITY, ON_SUBSCRIBE, ON_UNSUBSCRIBE,
				ON_RATE, ON_RECOVERY_IVL, ON_SNDBUF, ON_RCVBUF, ON_RCVMORE, ON_FD, ON_EVENTS,
				ON_TYPE, ON_LINGER, ON_RECONNECT_IVL, ON_BACKLOG, ON_RECONNECT_IVL_MAX,
				ON_MAXMSGSIZE, ON_MULTICAST_HOPS, ON_RCVTIMEO, ON_SNDTIMEO, ON_LAST_ENDPOINT,
				ON_TCP_KEEPALIVE, ON_TCP_KEEPALIVE_CNT, ON_TCP_KEEPALIVE_IDLE,
				ON_TCP_KEEPALIVE_INTVL, ON_TCP_ACCEPT_FILTER, ON_IMMEDIATE,
				ON_ROUTER_MANDATORY, ON_XPUB_VERBOSE, ON_MECHANISM,
				ON_PLAIN_SERVER, ON_PLAIN_USERNAME, ON_PLAIN_PASSWORD,
				ON_CURVE_SERVER, ON_CURVE_PUBLICKEY, ON_CURVE_SECRETKEY, ON_CURVE_SERVERKEY,
				ON_PROBE_ROUTER, ON_REQ_CORRELATE, ON_REQ_RELAXED, ON_CONFLATE, ON_ZAP_DOMAIN,
				ON_IPV6 };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, sonames, "name", 0, &index) != TCL_OK)
	    return TCL_ERROR;
	switch((enum ExObjOptionNames)index) {
	case ON_HWM: *name = ZMQ_HWM; break;
	case ON_AFFINITY: *name = ZMQ_AFFINITY; break;
	case ON_IDENTITY: *name = ZMQ_IDENTITY; break;
	case ON_SUBSCRIBE: *name = ZMQ_SUBSCRIBE; break;
	case ON_UNSUBSCRIBE: *name = ZMQ_UNSUBSCRIBE; break;
	case ON_RATE: *name = ZMQ_RATE; break;
	case ON_RECOVERY_IVL: *name = ZMQ_RECOVERY_IVL; break;
	case ON_SNDBUF: *name = ZMQ_SNDBUF; break;
	case ON_RCVBUF: *name = ZMQ_RCVBUF; break;
	case ON_RCVMORE: *name = ZMQ_RCVMORE; break;
	case ON_FD: *name = ZMQ_FD; break;
	case ON_EVENTS: *name = ZMQ_EVENTS; break;
	case ON_TYPE: *name = ZMQ_TYPE; break;
	case ON_LINGER: *name = ZMQ_LINGER; break;
	case ON_RECONNECT_IVL: *name = ZMQ_RECONNECT_IVL; break;
	case ON_BACKLOG: *name = ZMQ_BACKLOG; break;
	case ON_RECONNECT_IVL_MAX: *name = ZMQ_RECONNECT_IVL_MAX; break;
	case ON_MAXMSGSIZE: *name = ZMQ_MAXMSGSIZE; break;
	case ON_SNDHWM: *name = ZMQ_SNDHWM; break;
	case ON_RCVHWM: *name = ZMQ_RCVHWM; break;
	case ON_MULTICAST_HOPS: *name = ZMQ_MULTICAST_HOPS; break;
	case ON_RCVTIMEO: *name = ZMQ_RCVTIMEO; break;
	case ON_SNDTIMEO: *name = ZMQ_SNDTIMEO; break;
	case ON_LAST_ENDPOINT: *name = ZMQ_LAST_ENDPOINT; break;
	case ON_ROUTER_MANDATORY: *name = ZMQ_ROUTER_MANDATORY; break;
	case ON_TCP_KEEPALIVE: *name = ZMQ_TCP_KEEPALIVE; break;
	case ON_TCP_KEEPALIVE_CNT: *name = ZMQ_TCP_KEEPALIVE_CNT; break;
	case ON_TCP_KEEPALIVE_IDLE: *name = ZMQ_TCP_KEEPALIVE_IDLE; break;
	case ON_TCP_KEEPALIVE_INTVL: *name = ZMQ_TCP_KEEPALIVE_INTVL; break;
	case ON_TCP_ACCEPT_FILTER: *name = ZMQ_TCP_ACCEPT_FILTER; break;
	case ON_IMMEDIATE: *name = ZMQ_IMMEDIATE; break;
	case ON_XPUB_VERBOSE: *name = ZMQ_XPUB_VERBOSE; break;
	case ON_IPV6: *name = ZMQ_IPV6; break;
	case ON_MECHANISM: *name = ZMQ_MECHANISM; break;
	case ON_PLAIN_SERVER: *name = ZMQ_PLAIN_SERVER; break;
	case ON_PLAIN_USERNAME: *name = ZMQ_PLAIN_USERNAME; break;
	case ON_PLAIN_PASSWORD: *name = ZMQ_PLAIN_PASSWORD; break;
	case ON_CURVE_SERVER: *name = ZMQ_CURVE_SERVER; break;
	case ON_CURVE_PUBLICKEY: *name = ZMQ_CURVE_PUBLICKEY; break;
	case ON_CURVE_SECRETKEY: *name = ZMQ_CURVE_SECRETKEY; break;
	case ON_CURVE_SERVERKEY: *name = ZMQ_CURVE_SERVERKEY; break;
	case ON_PROBE_ROUTER: *name = ZMQ_PROBE_ROUTER; break;
	case ON_REQ_CORRELATE: *name = ZMQ_REQ_CORRELATE; break;
	case ON_REQ_RELAXED: *name = ZMQ_REQ_RELAXED; break;
	case ON_CONFLATE: *name = ZMQ_CONFLATE; break;
	case ON_ZAP_DOMAIN: *name = ZMQ_ZAP_DOMAIN; break;
	}
	return TCL_OK;
    }

    static int get_mechanism(Tcl_Interp* ip, Tcl_Obj* obj, int* name)
    {
	static const char* mflags[] = {"NULL", "PLAIN", "CURVE", NULL};
	enum ExObjMechanismNames { OM_NULL, OM_PLAIN, OM_CURVE };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, mflags, "mechanism", 0, &index) != TCL_OK)
	    return TCL_ERROR;
	switch((enum ExObjMechanismNames)index) {
	case OM_NULL: *name = ZMQ_NULL; break;
	case OM_PLAIN: *name = ZMQ_PLAIN; break;
	case OM_CURVE: *name = ZMQ_CURVE; break;
	}
	return TCL_OK;
    }

    static int get_poll_flags(Tcl_Interp* ip, Tcl_Obj* fl, int* events)
    {
	int objc = 0;
	Tcl_Obj** objv = 0;
	int i = 0;
	if (Tcl_ListObjGetElements(ip, fl, &objc, &objv) != TCL_OK) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("event flags not specified as list", -1));
	    return TCL_ERROR;
	}
	for(i = 0; i < objc; i++) {
	    static const char* eflags[] = {"POLLIN", "POLLOUT", "POLLERR", NULL};
	    enum ExObjEventFlags {ZEF_POLLIN, ZEF_POLLOUT, ZEF_POLLERR};
	    int efindex = -1;
	    if (Tcl_GetIndexFromObj(ip, objv[i], eflags, "event_flag", 0, &efindex) != TCL_OK)
		return TCL_ERROR;
	    switch((enum ExObjEventFlags)efindex) {
	    case ZEF_POLLIN: *events = *events | ZMQ_POLLIN; break;
	    case ZEF_POLLOUT: *events = *events | ZMQ_POLLOUT; break;
	    case ZEF_POLLERR: *events = *events | ZMQ_POLLERR; break;
	    }
	}
	return TCL_OK;
    }

    static Tcl_Obj* set_poll_flags(Tcl_Interp* ip, int revents)
    {
	Tcl_Obj* fresult = Tcl_NewListObj(0, NULL);
	if (revents & ZMQ_POLLIN) {
	    Tcl_ListObjAppendElement(ip, fresult, Tcl_NewStringObj("POLLIN", -1));
	}
	if (revents & ZMQ_POLLOUT) {
	    Tcl_ListObjAppendElement(ip, fresult, Tcl_NewStringObj("POLLOUT", -1));
	}
	if (revents & ZMQ_POLLERR) {
	    Tcl_ListObjAppendElement(ip, fresult, Tcl_NewStringObj("POLLERR", -1));
	}
	return fresult;
    }

    static int get_monitor_flags(Tcl_Interp* ip, Tcl_Obj* fl, int* events)
    {
	int objc = 0;
	Tcl_Obj** objv = 0;
	int i = 0;
	if (Tcl_ListObjGetElements(ip, fl, &objc, &objv) != TCL_OK) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("monitor events not specified as list", -1));
	    return TCL_ERROR;
	}
	for(i = 0; i < objc; i++) {
	    static const char* eflags[] = {"CONNECTED", "CONNECT_DELAYED", "CONNECT_RETRIED", "LISTENING", "BIND_FAILED", "ACCEPTED", "ACCEPT_FAILED", "CLOSED", "CLOSE_FAILED", "DISCONNECTED", "MONITOR_STOPPED", "ALL", NULL};
	    enum ExObjEventFlags {ZEV_CONNECTED, ZEV_CONNECT_DELAYED, ZEV_CONNECT_RETRIED, ZEV_LISTENING, ZEV_BIND_FAILED, ZEV_ACCEPTED, ZEV_ACCEPT_FAILED, ZEV_CLOSED, ZEV_CLOSE_FAILED, ZEV_DISCONNECTED, ZEV_MONITOR_STOPPED, ZEV_ALL};
	    int efindex = -1;
	    if (Tcl_GetIndexFromObj(ip, objv[i], eflags, "monitor_event_flag", 0, &efindex) != TCL_OK)
		return TCL_ERROR;
	    switch((enum ExObjEventFlags)efindex) {
	    case ZEV_CONNECTED: *events = *events | ZMQ_EVENT_CONNECTED; break;
	    case ZEV_CONNECT_DELAYED: *events = *events | ZMQ_EVENT_CONNECT_DELAYED; break;
	    case ZEV_CONNECT_RETRIED: *events = *events | ZMQ_EVENT_CONNECT_RETRIED; break;
	    case ZEV_LISTENING: *events = *events | ZMQ_EVENT_LISTENING; break;
	    case ZEV_BIND_FAILED: *events = *events | ZMQ_EVENT_BIND_FAILED; break;
	    case ZEV_ACCEPTED: *events = *events | ZMQ_EVENT_ACCEPTED; break;
	    case ZEV_ACCEPT_FAILED: *events = *events | ZMQ_EVENT_ACCEPT_FAILED; break;
	    case ZEV_CLOSED: *events = *events | ZMQ_EVENT_CLOSED; break;
	    case ZEV_CLOSE_FAILED: *events = *events | ZMQ_EVENT_CLOSE_FAILED; break;
	    case ZEV_DISCONNECTED: *events = *events | ZMQ_EVENT_DISCONNECTED; break;
	    case ZEV_MONITOR_STOPPED: *events = *events | ZMQ_EVENT_MONITOR_STOPPED; break;
	    case ZEV_ALL: *events = *events | ZMQ_EVENT_ALL; break;
	    }
	}
	return TCL_OK;
    }

    static int get_recv_send_flag(Tcl_Interp* ip, Tcl_Obj* fl, int* flags)
    {
	int objc = 0;
	Tcl_Obj** objv = 0;
	int i = 0;
	if (Tcl_ListObjGetElements(ip, fl, &objc, &objv) != TCL_OK) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("flags not specified as list", -1));
	    return TCL_ERROR;
	}
	for(i = 0; i < objc; i++) {
	    static const char* rsflags[] = {"DONTWAIT", "NOBLOCK", "SNDMORE", NULL};
	    enum ExObjRSFlags {RSF_DONTWAIT, RSF_NOBLOCK, RSF_SNDMORE};
	    int index = -1;
	    if (Tcl_GetIndexFromObj(ip, objv[i], rsflags, "flag", 0, &index) != TCL_OK)
                return TCL_ERROR;
	    switch((enum ExObjRSFlags)index) {
	    case RSF_DONTWAIT: *flags = *flags | ZMQ_DONTWAIT; break;
	    case RSF_NOBLOCK: *flags = *flags | ZMQ_DONTWAIT; break;
	    case RSF_SNDMORE: *flags = *flags | ZMQ_SNDMORE; break;
	    }
        }
	return TCL_OK;
    }

    static Tcl_Obj* zmq_s_dump(Tcl_Interp* ip, const char* data, int size)
    {
	int is_text = 1;
	int char_nbr;
	char buffer[TCL_INTEGER_SPACE+4];
	Tcl_Obj *result;
	for (char_nbr = 0; char_nbr < size && is_text; char_nbr++)
	    if ((unsigned char) data [char_nbr] < 32
		|| (unsigned char) data [char_nbr] > 127)
		is_text = 0;

	sprintf(buffer, "[%03d] ", size);
	result = Tcl_NewStringObj(buffer, -1);
	if (is_text) {
	    Tcl_AppendToObj(result, data, size);
	} else {
	    for (char_nbr = 0; char_nbr < size; char_nbr++) {
		sprintf(buffer, "%02X", data[char_nbr]);
		Tcl_AppendToObj(result, buffer, 2);
	    }
	}
	return result;
    }

    static int cget_context_option_as_tcl_obj(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj, Tcl_Obj** result)
    {
	int name = 0;
	void* zmqp = ((ZmqContextClientData*)cd)->context;
	ZmqClientData* zmqClientData = ((ZmqContextClientData*)cd)->zmqClientData;
	*result = 0;
	if (get_context_option(ip, optObj, &name) != TCL_OK)
	    return TCL_ERROR;
	int val = zmq_ctx_get(zmqp, name);
	last_zmq_errno = zmq_errno();
	if (val < 0) {
	    *result = Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1);
	    return TCL_ERROR;
	}
	*result = Tcl_NewIntObj(val);
	return TCL_OK;
    }

    static int cget_context_option(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj)
    {
	Tcl_Obj* result = 0;
	int rt = cget_context_option_as_tcl_obj(cd, ip, optObj, &result);
	if (result)
	    Tcl_SetObjResult(ip, result);
	return rt;
    }

    static int cset_context_option_as_tcl_obj(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj, Tcl_Obj* valObj)
    {
	int name = 0;
	void* zmqp = ((ZmqContextClientData*)cd)->context;
	ZmqClientData* zmqClientData = ((ZmqContextClientData*)cd)->zmqClientData;
	int rt = 0;
	if (get_context_option(ip, optObj, &name) != TCL_OK)
	    return TCL_ERROR;
	int val = -1;
	if (Tcl_GetIntFromObj(ip, valObj, &val) != TCL_OK) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong option value, expected integer", -1));
	    return TCL_ERROR;
	}
	rt = zmq_ctx_set(zmqp, name, val);
	last_zmq_errno = zmq_errno();
	if (rt != 0) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	    return TCL_ERROR;
	}
	return TCL_OK;
    }

    int zmq_context_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"cget", "configure", "destroy", "get", "set", "term", NULL};
	enum ExObjContextMethods {EXCTXOBJ_CGET, EXCTXOBJ_CONFIGURE, EXCTXOBJ_DESTROY, EXCTXOBJ_GET,
				  EXCTXOBJ_SET, EXCTXOBJ_TERM};
	int index = -1;
	void* zmqp = ((ZmqContextClientData*)cd)->context;
	int rt = 0;
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	switch((enum ExObjContextMethods)index) {
	case EXCTXOBJ_CONFIGURE:
	{
	    if (objc == 2) {
		/* Return all options */
		int cnp = 0;
		Tcl_Obj* cresult = Tcl_NewListObj(0, NULL);
		while(conames[cnp]) {
		    if (conames_cget[cnp]) {
			Tcl_Obj* result = 0;
			Tcl_Obj* cname = Tcl_NewStringObj(conames[cnp], -1);
			Tcl_Obj* oresult = 0;
			int rt = cget_context_option_as_tcl_obj(cd, ip, cname, &result);
			if (rt != TCL_OK) {
			    if (result)
				Tcl_SetObjResult(ip, result);
			    return rt;
			}
			oresult = Tcl_NewListObj(0, NULL);
			Tcl_ListObjAppendElement(ip, oresult, cname);
			Tcl_ListObjAppendElement(ip, oresult, result);
			Tcl_ListObjAppendElement(ip, cresult, oresult);
		    }
		    cnp++;
		}
		Tcl_SetObjResult(ip, cresult);
	    }
	    else if (objc == 3) {
		/* Get specified option */
		Tcl_Obj* result = 0;
		Tcl_Obj* oresult = 0;
		int rt = cget_context_option_as_tcl_obj(cd, ip, objv[2], &result);
		if (rt != TCL_OK) {
		    if (result)
			Tcl_SetObjResult(ip, result);
		    return rt;
		}
		oresult = Tcl_NewListObj(0, NULL);
		Tcl_ListObjAppendElement(ip, oresult, objv[2]);
		Tcl_ListObjAppendElement(ip, oresult, result);
		Tcl_SetObjResult(ip, oresult);
	    }
	    else if ((objc % 2) == 0) {
		/* Set specified options */
		int i;
		for(i = 2; i < objc; i += 2)
		    if (cset_context_option_as_tcl_obj(cd, ip, objv[i], objv[i+1]) != TCL_OK)
			return TCL_ERROR;
	    }
	    else {
		Tcl_WrongNumArgs(ip, 2, objv, "?name? ?value option value ...?");
		return TCL_ERROR;
	    }
	    break;
	}
	case EXCTXOBJ_DESTROY:
	case EXCTXOBJ_TERM:
	{
	    Tcl_HashEntry* hashEntry = 0;
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    rt = zmq_ctx_destroy(zmqp);
	    last_zmq_errno = zmq_errno();
	    if (rt == 0) {
		Tcl_DecrRefCount(((ZmqContextClientData*)cd)->tcl_cmd);
		Tcl_DeleteCommand(ip, Tcl_GetStringFromObj(objv[0], 0));
	    }
	    else {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    hashEntry = Tcl_FindHashEntry(((ZmqContextClientData*)cd)->zmqClientData->contextClientData, zmqp);
	    if (hashEntry)
		Tcl_DeleteHashEntry(hashEntry);
	    break;
	}
	case EXCTXOBJ_CGET:
	case EXCTXOBJ_GET:
	{
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "name");
		return TCL_ERROR;
	    }
	    return cget_context_option(cd, ip, objv[2]);
	}
	case EXCTXOBJ_SET:
	{
	    if (objc != 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value");
		return TCL_ERROR;
	    }
	    return cset_context_option_as_tcl_obj(cd, ip, objv[2], objv[3]);
	}
        }
 	return TCL_OK;
    }

    static int cget_socket_option_as_tcl_obj(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj, Tcl_Obj** result)
    {
	int name = 0;
	void* sockp = ((ZmqSocketClientData*)cd)->socket;
	*result = 0;
	if (get_socket_option(ip, optObj, &name) != TCL_OK)
	    return TCL_ERROR;
	switch(name) {
	    /* int options */
	case ZMQ_SNDHWM:
	case ZMQ_RCVHWM:
	case ZMQ_TYPE:
	case ZMQ_LINGER:
	case ZMQ_RECONNECT_IVL:
	case ZMQ_RECONNECT_IVL_MAX:
	case ZMQ_BACKLOG:
	case ZMQ_RCVMORE:
	case ZMQ_RATE:
	case ZMQ_SNDBUF:
	case ZMQ_RCVBUF:
	case ZMQ_RECOVERY_IVL:
	case ZMQ_MULTICAST_HOPS:
	case ZMQ_RCVTIMEO:
	case ZMQ_SNDTIMEO:
	case ZMQ_TCP_KEEPALIVE:
	case ZMQ_TCP_KEEPALIVE_CNT:
	case ZMQ_TCP_KEEPALIVE_IDLE:
	case ZMQ_TCP_KEEPALIVE_INTVL:
	case ZMQ_IMMEDIATE:
	case ZMQ_IPV6:
	case ZMQ_PLAIN_SERVER:
	case ZMQ_CURVE_SERVER:
	case ZMQ_PROBE_ROUTER:
	case ZMQ_REQ_CORRELATE:
	case ZMQ_REQ_RELAXED:
	{
	    int val = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(sockp, name, &val, &len);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    *result = Tcl_NewIntObj(val);
	    break;
	}
	case ZMQ_EVENTS:
	{
	    int val = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(sockp, name, &val, &len);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    *result = set_poll_flags(ip, val);
	    break;
	}
	/* uint64_t options */
	case ZMQ_AFFINITY:
	{
	    uint64_t val = 0;
	    size_t len = sizeof(uint64_t);
	    int rt = zmq_getsockopt(sockp, name, &val, &len);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    *result = Tcl_NewWideIntObj(val);
	    break;
	}
	/* int64_t options */
	case ZMQ_MAXMSGSIZE:
	{
	    int64_t val = 0;
	    size_t len = sizeof(int64_t);
	    int rt = zmq_getsockopt(sockp, name, &val, &len);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    *result = Tcl_NewWideIntObj(val);
	    break;
	}
	/* binary options */
	case ZMQ_IDENTITY:
	{
	    const char val[256];
	    size_t len = 256;
	    int rt = zmq_getsockopt(sockp, name, (void*)val, &len);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    *result = Tcl_NewStringObj(val, len);
	    break;
	}
	case ZMQ_LAST_ENDPOINT:
	case ZMQ_PLAIN_USERNAME:
	case ZMQ_PLAIN_PASSWORD:
	case ZMQ_CURVE_PUBLICKEY:
	case ZMQ_CURVE_SECRETKEY:
	case ZMQ_CURVE_SERVERKEY:
	case ZMQ_ZAP_DOMAIN:
	{
	    const char val[256];
	    size_t len = 256;
	    int rt = zmq_getsockopt(sockp, name, (void*)val, &len);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    /* Length of string including trailing zero is returned */
	    *result = Tcl_NewStringObj(val, len-1);
	    break;
	}
	case ZMQ_MECHANISM:
	{
	    int val = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(sockp, name, &val, &len);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    switch(val) {
	    case ZMQ_NULL: *result = Tcl_NewStringObj("NULL", -1); break;
	    case ZMQ_PLAIN: *result = Tcl_NewStringObj("PLAIN", -1); break;
	    case ZMQ_CURVE: *result = Tcl_NewStringObj("CURVE", -1); break;
	    default: *result = Tcl_NewStringObj("NULL", -1); break;
	    }
	    break;
	}
	default:
	{
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("unsupported option", -1));
	    return TCL_ERROR;
	}
	}
	return TCL_OK;
    }

    static int cget_socket_option(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj)
    {
	Tcl_Obj* result = 0;
	int rt = cget_socket_option_as_tcl_obj(cd, ip, optObj, &result);
	if (result)
	    Tcl_SetObjResult(ip, result);
	return rt;
    }

    static int cset_socket_option_as_tcl_obj(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj, Tcl_Obj* valObj, Tcl_Obj* sizeObj)
    {
	void* sockp = ((ZmqSocketClientData*)cd)->socket;
	int name = -1;
	if (get_socket_option(ip, optObj, &name) != TCL_OK)
	    return TCL_ERROR;
	switch(name) {
	/* int options */
	case ZMQ_HWM:
	{
	    int val = 0;
	    int rt = 0;
	    if (Tcl_GetIntFromObj(ip, valObj, &val) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong HWM argument, expected integer", -1));
		return TCL_ERROR;
	    }
	    rt = zmq_setsockopt(sockp, ZMQ_SNDHWM, &val, sizeof val);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    rt = zmq_setsockopt(sockp, ZMQ_RCVHWM, &val, sizeof val);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case ZMQ_SNDHWM:
	case ZMQ_RCVHWM:
	case ZMQ_LINGER:
	case ZMQ_RECONNECT_IVL:
	case ZMQ_RECONNECT_IVL_MAX:
	case ZMQ_BACKLOG:
	case ZMQ_RATE:
	case ZMQ_RECOVERY_IVL:
	case ZMQ_SNDBUF:
	case ZMQ_RCVBUF:
	case ZMQ_MULTICAST_HOPS:
	case ZMQ_RCVTIMEO:
	case ZMQ_SNDTIMEO:
	case ZMQ_ROUTER_MANDATORY:
	case ZMQ_TCP_KEEPALIVE:
	case ZMQ_TCP_KEEPALIVE_CNT:
	case ZMQ_TCP_KEEPALIVE_IDLE:
	case ZMQ_TCP_KEEPALIVE_INTVL:
	case ZMQ_IMMEDIATE:
	case ZMQ_XPUB_VERBOSE:
	case ZMQ_IPV6:
	case ZMQ_PLAIN_SERVER:
	case ZMQ_CURVE_SERVER:
	case ZMQ_PROBE_ROUTER:
	case ZMQ_REQ_CORRELATE:
	case ZMQ_REQ_RELAXED:
	case ZMQ_CONFLATE:
	{
	    int val = 0;
	    int rt = 0;
	    if (Tcl_GetIntFromObj(ip, valObj, &val) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong argument, expected integer", -1));
		return TCL_ERROR;
	    }
	    rt = zmq_setsockopt(sockp, name, &val, sizeof val);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	/* uint64_t options */
	case ZMQ_AFFINITY:
	{
	    Tcl_WideInt val = 0;
	    uint64_t uval = 0;
	    int rt = 0;
	    if (Tcl_GetWideIntFromObj(ip, valObj, &val) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong argument, expected integer", -1));
		return TCL_ERROR;
	    }
	    uval = val;
	    rt = zmq_setsockopt(sockp, name, &uval, sizeof uval);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	/* int64_t options */
	case ZMQ_MAXMSGSIZE:
	{
	    Tcl_WideInt val = 0;
	    int rt = 0;
	    if (Tcl_GetWideIntFromObj(ip, valObj, &val) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong argument, expected integer", -1));
		return TCL_ERROR;
	    }
	    rt = zmq_setsockopt(sockp, name, &val, sizeof val);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	/* binary options */
	case ZMQ_IDENTITY:
	case ZMQ_SUBSCRIBE:
	case ZMQ_UNSUBSCRIBE:
	{
	    int len = 0;
	    const char* val = 0;
	    int rt = 0;
	    int size = -1;
	    val = Tcl_GetStringFromObj(valObj, &len);
	    if (sizeObj) {
		if (Tcl_GetIntFromObj(ip, sizeObj, &size) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong size argument, expected integer", -1));
		    return TCL_ERROR;
		}
	    }
	    else
		size = len;
	    rt = zmq_setsockopt(sockp, name, val, size);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case ZMQ_TCP_ACCEPT_FILTER:
	case ZMQ_PLAIN_USERNAME:
	case ZMQ_PLAIN_PASSWORD:
	case ZMQ_CURVE_PUBLICKEY:
	case ZMQ_CURVE_SECRETKEY:
	case ZMQ_CURVE_SERVERKEY:
	case ZMQ_ZAP_DOMAIN:
	{
	    int len = 0;
	    const char* val = 0;
	    int rt = 0;
	    int size = -1;
	    val = Tcl_GetStringFromObj(valObj, &len);
	    if (sizeObj) {
		if (Tcl_GetIntFromObj(ip, sizeObj, &size) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong size argument, expected integer", -1));
		    return TCL_ERROR;
		}
	    }
	    else
		size = len;
	    if (size == 0)
		rt = zmq_setsockopt(sockp, name, 0, 0);
	    else
		rt = zmq_setsockopt(sockp, name, val, size);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	default:
	{
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("unsupported option", -1));
	    return TCL_ERROR;
	}
	}
	return TCL_OK;
    }

    int zmq_socket_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"bind", "cget", "close", "configure", "connect", "destroy", "disconnect", "get",
					"getsockopt", "readable", "recv_msg", "send_msg", "dump", "recv", "send",
					"sendmore", "set", "setsockopt", "unbind", "writable", "recv_monitor_event",
					"monitor", NULL};
	enum ExObjSocketMethods {EXSOCKOBJ_BIND, EXSOCKOBJ_CGET, EXSOCKOBJ_CLOSE, EXSOCKOBJ_CONFIGURE, EXSOCKOBJ_CONNECT,
				 EXSOCKOBJ_DESTROY, EXSOCKOBJ_DISCONNECT, EXSOCKOBJ_GET, EXSOCKOBJ_GETSOCKETOPT,
				 EXSOCKOBJ_READABLE, EXSOCKOBJ_RECV, EXSOCKOBJ_SEND, EXSOCKOBJ_S_DUMP, EXSOCKOBJ_S_RECV,
				 EXSOCKOBJ_S_SEND, EXSOCKOBJ_S_SENDMORE, EXSOCKOBJ_SET, EXSOCKOBJ_SETSOCKETOPT, EXSOCKOBJ_UNBIND,
				 EXSOCKOBJ_WRITABLE, EXSOCKOBJ_RECV_MONITOR_EVENT, EXSOCKOBJ_MONITOR};
	int index = -1;
	void* sockp = ((ZmqSocketClientData*)cd)->socket;
	ZmqClientData* zmqClientData = (((ZmqSocketClientData*)cd)->zmqClientData);
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	switch((enum ExObjSocketMethods)index) {
        case EXSOCKOBJ_BIND:
        {
	    int rt = 0;
	    const char* endpoint = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "endpoint");
		return TCL_ERROR;
	    }
	    endpoint = Tcl_GetStringFromObj(objv[2], 0);
	    rt = zmq_bind(sockp, endpoint);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_CLOSE:
	case EXSOCKOBJ_DESTROY:
	{
	    Tcl_HashEntry* hashEntry = 0;
	    int rt = 0;
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    rt = zmq_close(sockp);
	    last_zmq_errno = zmq_errno();
	    if (rt == 0) {
		Tcl_DecrRefCount(((ZmqSocketClientData*)cd)->tcl_cmd);
		Tcl_DeleteCommand(ip, Tcl_GetStringFromObj(objv[0], 0));
	    }
	    else {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    hashEntry = Tcl_FindHashEntry(zmqClientData->readableCommands, sockp);
	    if (hashEntry)
		Tcl_DeleteHashEntry(hashEntry);
	    hashEntry = Tcl_FindHashEntry(zmqClientData->writableCommands, sockp);
	    if (hashEntry)
		Tcl_DeleteHashEntry(hashEntry);
	    hashEntry = Tcl_FindHashEntry(zmqClientData->socketClientData, sockp);
	    if (hashEntry)
		Tcl_DeleteHashEntry(hashEntry);
	    break;
	}
	case EXSOCKOBJ_CONFIGURE:
	{
	    if (objc == 2) {
		/* Return all options */
		int cnp = 0;
		Tcl_Obj* cresult = Tcl_NewListObj(0, NULL);
		while(sonames[cnp]) {
		    if (sonames_cget[cnp]) {
			Tcl_Obj* result = 0;
			Tcl_Obj* oresult = 0;
			Tcl_Obj* cname = Tcl_NewStringObj(sonames[cnp], -1);
			int rt = cget_socket_option_as_tcl_obj(cd, ip, cname, &result);
			/* if 2, error expected depending on configuring libzmq
			   with or without libsodium */
			if (sonames_cget[cnp] == 2) {
			    oresult = Tcl_NewListObj(0, NULL);
			    Tcl_ListObjAppendElement(ip, oresult, cname);
			    Tcl_ListObjAppendElement(ip, oresult, Tcl_NewStringObj("<no libsodium>", -1));
			    Tcl_ListObjAppendElement(ip, cresult, oresult);
			}
			else {
			    if (rt != TCL_OK) {
				if (result)
				    Tcl_SetObjResult(ip, result);
				return rt;
			    }
			    oresult = Tcl_NewListObj(0, NULL);
			    Tcl_ListObjAppendElement(ip, oresult, cname);
			    Tcl_ListObjAppendElement(ip, oresult, result);
			    Tcl_ListObjAppendElement(ip, cresult, oresult);
			}
		    }
		    cnp++;
		}
		Tcl_SetObjResult(ip, cresult);
	    }
	    else if (objc == 3) {
		/* Get specified option */
		Tcl_Obj* result = 0;
		Tcl_Obj* oresult = 0;
		int rt = cget_socket_option_as_tcl_obj(cd, ip, objv[2], &result);
		if (rt != TCL_OK) {
		    if (result)
			Tcl_SetObjResult(ip, result);
		    return rt;
		}
		oresult = Tcl_NewListObj(0, NULL);
		Tcl_ListObjAppendElement(ip, oresult, objv[2]);
		Tcl_ListObjAppendElement(ip, oresult, result);
		Tcl_SetObjResult(ip, oresult);
	    }
	    else if ((objc % 2) == 0) {
		/* Set specified options */
		int i;
		for(i = 2; i < objc; i += 2)
		    if (cset_socket_option_as_tcl_obj(cd, ip, objv[i], objv[i+1], 0) != TCL_OK)
			return TCL_ERROR;
	    }
	    else {
		Tcl_WrongNumArgs(ip, 2, objv, "?name? ?value option value ...?");
		return TCL_ERROR;
	    }
	    break;
	}
        case EXSOCKOBJ_CONNECT:
        {
	    int rt = 0;
	    const char* endpoint = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "endpoint");
		return TCL_ERROR;
	    }
	    endpoint = Tcl_GetStringFromObj(objv[2], 0);
	    rt = zmq_connect(sockp, endpoint);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
        case EXSOCKOBJ_DISCONNECT:
        {
	    int rt = 0;
	    const char* endpoint = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "endpoint");
		return TCL_ERROR;
	    }
	    endpoint = Tcl_GetStringFromObj(objv[2], 0);
	    rt = zmq_disconnect(sockp, endpoint);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_CGET:
	case EXSOCKOBJ_GET:
	case EXSOCKOBJ_GETSOCKETOPT:
	{
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "name");
		return TCL_ERROR;
	    }
	    return cget_socket_option(cd, ip, objv[2]);
	}
	case EXSOCKOBJ_READABLE:
	{
	    int len = 0;
	    ZmqClientData* zmqClientData = (((ZmqSocketClientData*)cd)->zmqClientData);
	    Tcl_HashEntry* currCommand = 0;
	    Tcl_Time waitTime = { 0, 0 };
	    if (objc < 2 || objc > 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "?command?");
		return TCL_ERROR;
	    }
	    if (objc == 2) {
		currCommand = Tcl_FindHashEntry(zmqClientData->readableCommands, sockp);
		if (currCommand) {
		    Tcl_Obj* old_command = (Tcl_Obj*)Tcl_GetHashValue(currCommand);
		    Tcl_SetObjResult(ip, old_command);
		}
	    }
	    else {
		/* If [llength $command] == 0 => delete readable event if present */
		if (Tcl_ListObjLength(ip, objv[2], &len) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("command not passed as a list", -1));
		    return TCL_ERROR;
		}
		/* If socket already present, replace the command */
		currCommand = Tcl_FindHashEntry(zmqClientData->readableCommands, sockp);
		if (currCommand) {
		    Tcl_Obj* old_command = (Tcl_Obj*)Tcl_GetHashValue(currCommand);
		    Tcl_DecrRefCount(old_command);
		    if (len) {
			/* Replace */
			Tcl_IncrRefCount(objv[2]);
			Tcl_SetHashValue(currCommand, objv[2]);
		    }
		    else {
			/* Remove */
			Tcl_DeleteHashEntry(currCommand);
		    }
		}
		else {
		    if (len) {
			/* Add */
			int newPtr = 0;
			Tcl_IncrRefCount(objv[2]);
			currCommand = Tcl_CreateHashEntry(zmqClientData->readableCommands, sockp, &newPtr);
			Tcl_SetHashValue(currCommand, objv[2]);
		    }
		}
		Tcl_WaitForEvent(&waitTime);
	    }
	    break;
	}
	case EXSOCKOBJ_RECV:
	{
	    void* msgp = 0;
	    int flags = 0;
	    int rt = 0;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "message ?flags?");
		return TCL_ERROR;
	    }
	    msgp = known_message(ip, objv[2]);
	    if (msgp == NULL) {
		return TCL_ERROR;
	    }
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    rt = zmq_recvmsg(sockp, msgp, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    break;
	}
	case EXSOCKOBJ_SEND:
	{
	    void* msgp = 0;
	    int flags = 0;
	    int rt = 0;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "message ?flags?");
		return TCL_ERROR;
	    }
	    msgp = known_message(ip, objv[2]);
	    if (msgp == NULL) {
		return TCL_ERROR;
	    }
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    rt = zmq_sendmsg(sockp, msgp, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    break;
	}
	case EXSOCKOBJ_S_DUMP:
	{
	    Tcl_Obj* result = 0;
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    result = Tcl_NewListObj(0, NULL);
	    while (1) {
		int more; /* Multipart detection */
		size_t more_size = sizeof (more);
		zmq_msg_t message;

		/* Process all parts of the message */
		zmq_msg_init (&message);
		zmq_recvmsg(sockp, &message, 0);

		/* Dump the message as text or binary */
		Tcl_ListObjAppendElement(ip, result, zmq_s_dump(ip, zmq_msg_data(&message), zmq_msg_size(&message)));

		zmq_getsockopt (sockp, ZMQ_RCVMORE, &more, &more_size);
		zmq_msg_close (&message);
		if (!more)
		    break; /* Last message part */
	    }
	    Tcl_SetObjResult(ip, result);
	    break;
	}
	case EXSOCKOBJ_S_RECV:
	{
	    zmq_msg_t msg;
	    int rt = 0;
	    int flags = 0;
	    if (objc < 2 || objc > 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "?flags?");
		return TCL_ERROR;
	    }
	    if (objc > 2 && get_recv_send_flag(ip, objv[2], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    rt = zmq_msg_init(&msg);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    rt = zmq_recvmsg(sockp, &msg, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		zmq_msg_close(&msg);
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_msg_data(&msg), zmq_msg_size(&msg)));
	    zmq_msg_close(&msg);
	    break;
	}
	case EXSOCKOBJ_S_SEND:
	{
	    int size = 0;
	    int rt = 0;
	    char* data = 0;
	    void* buffer = 0;
	    zmq_msg_t msg;
	    int flags = 0;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "data ?flags?");
		return TCL_ERROR;
	    }
	    data = Tcl_GetStringFromObj(objv[2], &size);
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    buffer = ckalloc(size);
	    memcpy(buffer, data, size);
	    rt = zmq_msg_init_data(&msg, buffer, size, zmq_ckfree, NULL);
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    rt = zmq_sendmsg(sockp, &msg, flags);
	    last_zmq_errno = zmq_errno();
	    zmq_msg_close(&msg);
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_S_SENDMORE:
	{
	    int size = 0;
	    int rt = 0;
	    char* data = 0;
	    void* buffer = 0;
	    zmq_msg_t msg;
	    int flags = ZMQ_SNDMORE;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "data ?flags?");
		return TCL_ERROR;
	    }
	    data = Tcl_GetStringFromObj(objv[2], &size);
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    buffer = ckalloc(size);
	    memcpy(buffer, data, size);
	    rt = zmq_msg_init_data(&msg, buffer, size, zmq_ckfree, NULL);
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    rt = zmq_sendmsg(sockp, &msg, ZMQ_SNDMORE);
	    last_zmq_errno = zmq_errno();
	    zmq_msg_close(&msg);
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_SET:
	case EXSOCKOBJ_SETSOCKETOPT:
	{
	    if (objc < 4 || objc > 5) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value ?size?");
		return TCL_ERROR;
	    }
	    return cset_socket_option_as_tcl_obj(cd, ip, objv[2], objv[3], objc==5?objv[4]:0);
	    break;
	}
        case EXSOCKOBJ_UNBIND:
        {
	    int rt = 0;
	    const char* endpoint = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "endpoint");
		return TCL_ERROR;
	    }
	    endpoint = Tcl_GetStringFromObj(objv[2], 0);
	    rt = zmq_unbind(sockp, endpoint);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_WRITABLE:
	{
	    int len = 0;
	    ZmqClientData* zmqClientData = (((ZmqSocketClientData*)cd)->zmqClientData);
	    Tcl_HashEntry* currCommand = 0;
	    Tcl_Time waitTime = { 0, 0 };
	    if (objc < 2 || objc > 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "?command?");
		return TCL_ERROR;
	    }
	    if (objc == 2) {
		currCommand = Tcl_FindHashEntry(zmqClientData->writableCommands, sockp);
		if (currCommand) {
		    Tcl_Obj* old_command = (Tcl_Obj*)Tcl_GetHashValue(currCommand);
		    Tcl_SetObjResult(ip, old_command);
		}
	    }
	    else {
		/* If [llength $command] == 0 => delete writable event if present */
		if (Tcl_ListObjLength(ip, objv[2], &len) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("command not passed as a list", -1));
		    return TCL_ERROR;
		}
		/* If socket already present, replace the command */
		currCommand = Tcl_FindHashEntry(zmqClientData->writableCommands, sockp);
		if (currCommand) {
		    Tcl_Obj* old_command = (Tcl_Obj*)Tcl_GetHashValue(currCommand);
		    Tcl_DecrRefCount(old_command);
		    if (len) {
			/* Replace */
			Tcl_IncrRefCount(objv[2]);
			Tcl_SetHashValue(currCommand, objv[2]);
		    }
		    else {
			/* Remove */
			Tcl_DeleteHashEntry(currCommand);
		    }
		}
		else {
		    if (len) {
			/* Add */
			int newPtr = 0;
			Tcl_IncrRefCount(objv[2]);
			currCommand = Tcl_CreateHashEntry(zmqClientData->writableCommands, sockp, &newPtr);
			Tcl_SetHashValue(currCommand, objv[2]);
		    }
		}
		Tcl_WaitForEvent(&waitTime);
	    }
	    break;
	}
	case EXSOCKOBJ_RECV_MONITOR_EVENT:
	{
	    int rt = 0;
	    zmq_msg_t msg;
	    zmq_event_t event;
	    Tcl_Obj* d;
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    zmq_msg_init (&msg);
	    rt = zmq_recvmsg (sockp, &msg, 0);
	    last_zmq_errno = zmq_errno();
	    if (rt == -1 && last_zmq_errno == ETERM) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    memcpy (&event, zmq_msg_data (&msg), sizeof (event));
	    d = Tcl_NewDictObj();
	    if (event.event & ZMQ_EVENT_CONNECTED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("CONNECTED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fd", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_CONNECT_DELAYED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("CONNECT_DELAYED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("err", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_CONNECT_RETRIED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("CONNECT_RETRIED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("interval", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_LISTENING) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("LISTENING", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fd", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_BIND_FAILED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("BIND_FAILED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("error", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_ACCEPTED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("ACCEPTED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fd", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_ACCEPT_FAILED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("ACCEPT_FAILED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("error", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_CLOSED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("CLOSED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fd", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_CLOSE_FAILED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("CLOSE_FAILED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("error", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_DISCONNECTED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("DISCONNECTED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fd", -1), Tcl_NewIntObj(event.value));
	    }
	    else if (event.event & ZMQ_EVENT_MONITOR_STOPPED) {
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("event", -1), Tcl_NewStringObj("DISCONNECTED", -1));
	    	Tcl_DictObjPut(ip, d, Tcl_NewStringObj("fd", -1), Tcl_NewIntObj(event.value));
	    }
	    Tcl_SetObjResult(ip, d);
	    break;
	}
	case EXSOCKOBJ_MONITOR:
	{
	    int rt = 0;
	    int monitor_events = 0;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "endpoint ?events?");
		return TCL_ERROR;
	    }
	    if (objc == 4) {
		if (get_monitor_flags(ip, objv[3], &monitor_events) != TCL_OK)
		    return TCL_ERROR;
	    }
	    else
		monitor_events = ZMQ_EVENT_ALL;
	    rt = zmq_socket_monitor(sockp, Tcl_GetStringFromObj(objv[2], 0), monitor_events);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
        }
 	return TCL_OK;
    }

    static int cget_message_option_as_tcl_obj(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj, Tcl_Obj** result)
    {
	void* msgp = ((ZmqMessageClientData*)cd)->message;
	int name = 0;
	*result = 0;
	if (get_message_option(ip, optObj, &name) != TCL_OK)
		return TCL_ERROR;
	switch(name) {
	case ZMQ_MORE:
	{
	    int rt = zmq_msg_get(msgp, name);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		*result = Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1);
		return TCL_ERROR;
	    }
	    *result = Tcl_NewIntObj(rt);
	    break;
	}
	default:
	{
	    *result = Tcl_NewStringObj("unsupported option", -1);
	    return TCL_ERROR;
	}
	}
	return TCL_OK;
    }

    static int cget_message_option(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj)
    {
	Tcl_Obj* result = 0;
	int rt = cget_message_option_as_tcl_obj(cd, ip, optObj, &result);
	if (result)
	    Tcl_SetObjResult(ip, result);
	return rt;
    }

    static int cset_message_option_as_tcl_obj(ClientData cd, Tcl_Interp* ip, Tcl_Obj* optObj, Tcl_Obj* valObj)
    {
	int name = 0;
	int val = 0;
	void* msgp = ((ZmqMessageClientData*)cd)->message;
	if (get_message_option(ip, optObj, &name) != TCL_OK)
	    return TCL_ERROR;
	switch(name) {
	default:
	{
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("unsupported option", -1));
	    return TCL_ERROR;
	}
	}
	return TCL_OK;
    }

    int zmq_message_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"cget", "close", "configure", "copy", "data", "destroy", "move", "size", "dump", "get",
					"set", "send", "sendmore", "recv", "more", NULL};
	enum ExObjMessageMethods {EXMSGOBJ_CGET, EXMSGOBJ_CLOSE, EXMSGOBJ_CONFIGURE, EXMSGOBJ_COPY, EXMSGOBJ_DATA,
				  EXMSGOBJ_DESTROY, EXMSGOBJ_MOVE, EXMSGOBJ_SIZE, EXMSGOBJ_SDUMP, EXMSGOBJ_GET, EXMSGOBJ_SET,
				  EXMSGOBJ_SEND, EXMSGOBJ_SENDMORE, EXMSGOBJ_RECV, EXMSGOBJ_MORE};
	int index = -1;
	void* msgp = 0;
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	msgp = ((ZmqMessageClientData*)cd)->message;
	switch((enum ExObjMessageMethods)index) {
	case EXMSGOBJ_CLOSE:
	case EXMSGOBJ_DESTROY:
	{
	    int rt = 0;
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    rt = zmq_msg_close(msgp);
	    last_zmq_errno = zmq_errno();
	    ckfree(msgp);
	    if (rt == 0) {
		Tcl_DecrRefCount(((ZmqMessageClientData*)cd)->tcl_cmd);
		Tcl_DeleteCommand(ip, Tcl_GetStringFromObj(objv[0], 0));
	    }
	    else {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXMSGOBJ_CONFIGURE:
	{
	    if (objc == 2) {
		/* Return all options */
		int cnp = 0;
		Tcl_Obj* cresult = Tcl_NewListObj(0, NULL);
		while(monames[cnp]) {
		    if (monames_cget[cnp]) {
			Tcl_Obj* result = 0;
			Tcl_Obj* oresult = 0;
			Tcl_Obj* cname = Tcl_NewStringObj(monames[cnp], -1);
			int rt = cget_message_option_as_tcl_obj(cd, ip, cname, &result);
			if (rt != TCL_OK) {
			    if (result)
				Tcl_SetObjResult(ip, result);
			    return rt;
			}
			oresult = Tcl_NewListObj(0, NULL);
			Tcl_ListObjAppendElement(ip, oresult, cname);
			Tcl_ListObjAppendElement(ip, oresult, result);
			Tcl_ListObjAppendElement(ip, cresult, oresult);
		    }
		    cnp++;
		}
		Tcl_SetObjResult(ip, cresult);
	    }
	    else if (objc == 3) {
		/* Get specified option */
		Tcl_Obj* result = 0;
		Tcl_Obj* oresult = 0;
		int rt = cget_message_option_as_tcl_obj(cd, ip, objv[2], &result);
		if (rt != TCL_OK) {
		    if (result)
			Tcl_SetObjResult(ip, result);
		    return rt;
		}
		oresult = Tcl_NewListObj(0, NULL);
		Tcl_ListObjAppendElement(ip, oresult, objv[2]);
		Tcl_ListObjAppendElement(ip, oresult, result);
		Tcl_SetObjResult(ip, oresult);
	    }
	    else if ((objc % 2) == 0) {
		/* Set specified options */
		int i;
		for(i = 2; i < objc; i += 2)
		    if (cset_message_option_as_tcl_obj(cd, ip, objv[i], objv[i+1]) != TCL_OK)
			return TCL_ERROR;
	    }
	    else {
		Tcl_WrongNumArgs(ip, 2, objv, "?name? ?value option value ...?");
		return TCL_ERROR;
	    }
	    break;
	}
        case EXMSGOBJ_COPY:
        {
	    void* dmsgp = 0;
	    int rt = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "dest_message");
		return TCL_ERROR;
	    }
	    dmsgp = known_message(ip, objv[2]);
	    if (!dmsgp) {
	        return TCL_ERROR;
	    }
	    rt = zmq_msg_copy(dmsgp, msgp);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
   	    break;
	}
        case EXMSGOBJ_DATA:
        {
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_msg_data(msgp), zmq_msg_size(msgp)));
   	    break;
	}
	case EXMSGOBJ_CGET:
	case EXMSGOBJ_GET:
	{
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "name");
		return TCL_ERROR;
	    }
	    return cget_message_option(cd, ip, objv[2]);
	}
	case EXMSGOBJ_MORE:
	{
	    int rt = 0;
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    rt = zmq_msg_more(msgp);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    break;
	}
        case EXMSGOBJ_MOVE:
        {
	    void* dmsgp = 0;
	    int rt = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "dest_message");
		return TCL_ERROR;
	    }
	    dmsgp = known_message(ip, objv[2]);
	    if (!dmsgp) {
	        return TCL_ERROR;
	    }
	    rt = zmq_msg_move(dmsgp, msgp);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
   	    break;
	}
	case EXMSGOBJ_RECV:
	{
	    void* sockp = 0;
	    int flags = 0;
	    int rt = 0;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "socket ?flags?");
		return TCL_ERROR;
	    }
	    sockp = known_socket(ip, objv[2]);
	    if (sockp == NULL) {
		return TCL_ERROR;
	    }
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    rt = zmq_msg_recv(msgp, sockp, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    break;
	}
	case EXMSGOBJ_SEND:
	{
	    void* sockp = 0;
	    int flags = 0;
	    int rt = 0;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "socket ?flags?");
		return TCL_ERROR;
	    }
	    sockp = known_socket(ip, objv[2]);
	    if (sockp == NULL) {
		return TCL_ERROR;
	    }
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    rt = zmq_msg_send(msgp, sockp, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    break;
	}
	case EXMSGOBJ_SENDMORE:
	{
	    void* sockp = 0;
	    int flags = ZMQ_SNDMORE;
	    int rt = 0;
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "socket ?flags?");
		return TCL_ERROR;
	    }
	    sockp = known_socket(ip, objv[2]);
	    if (sockp == NULL) {
		return TCL_ERROR;
	    }
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    rt = zmq_msg_send(msgp, sockp, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt < 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    break;
	}
	case EXMSGOBJ_SET:
	{
	    if (objc != 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value");
		return TCL_ERROR;
	    }
	    return cset_message_option_as_tcl_obj(cd, ip, objv[2], objv[3]);
	    break;
	}
        case EXMSGOBJ_SIZE:
        {
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, Tcl_NewIntObj(zmq_msg_size(msgp)));
   	    break;
	}
	case EXMSGOBJ_SDUMP:
	{
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    Tcl_SetObjResult(ip, zmq_s_dump(ip, zmq_msg_data(msgp), zmq_msg_size(msgp)));
	    break;
	}
	}
 	return TCL_OK;
    }

    static Tcl_Obj* unique_namespace_name(Tcl_Interp* ip, Tcl_Obj* obj, ZmqClientData* cd) {
	Tcl_Obj* fqn = 0;
	if (obj) {
	    const char* name = Tcl_GetStringFromObj(obj, 0);
	    Tcl_CmdInfo ci;
	    if (!Tcl_StringMatch(name, "::*")) {
		Tcl_Eval(ip, "namespace current");
		fqn = Tcl_GetObjResult(ip);
		fqn = Tcl_DuplicateObj(fqn);
		Tcl_IncrRefCount(fqn);
		if (!Tcl_StringMatch(Tcl_GetStringFromObj(fqn, 0), "::")) {
		    Tcl_AppendToObj(fqn, "::", -1);
		}
		Tcl_AppendToObj(fqn, name, -1);
	    } else {
		fqn = Tcl_NewStringObj(name, -1);
		Tcl_IncrRefCount(fqn);
	    }
	    if (Tcl_GetCommandInfo(ip, Tcl_GetStringFromObj(fqn, 0), &ci)) {
		Tcl_Obj* err;
		err = Tcl_NewObj();
		Tcl_AppendToObj(err, "command \"", -1);
		Tcl_AppendObjToObj(err, fqn);
		Tcl_AppendToObj(err, "\" already exists, unable to create object", -1);
		Tcl_DecrRefCount(fqn);
		Tcl_SetObjResult(ip, err);
		return 0;
	    }
	}
	else {
	    Tcl_Eval(ip, "namespace current");
	    fqn = Tcl_GetObjResult(ip);
	    fqn = Tcl_DuplicateObj(fqn);
	    Tcl_IncrRefCount(fqn);
	    if (!Tcl_StringMatch(Tcl_GetStringFromObj(fqn, 0), "::")) {
		Tcl_AppendToObj(fqn, "::", -1);
	    }
	    Tcl_AppendToObj(fqn, "zmq", -1);
	    Tcl_AppendPrintfToObj(fqn, "%d", cd->id);
	    cd->id = cd->id + 1;
	}
	return fqn;
    }

    static void zmqEventSetup(ClientData cd, int flags)
    {
	ZmqClientData* zmqClientData = (ZmqClientData*)cd;
	Tcl_Time blockTime = { 0, 0};
	Tcl_HashSearch hsr;
	Tcl_HashEntry* her = Tcl_FirstHashEntry(zmqClientData->readableCommands, &hsr);
	Tcl_HashSearch hsw;
	Tcl_HashEntry* hew = 0;
	int pme = 0;
	while(her) {
	    int events = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(Tcl_GetHashKey(zmqClientData->readableCommands, her), ZMQ_EVENTS, &events, &len);
	    if (!rt && events & ZMQ_POLLIN) {
		Tcl_SetMaxBlockTime(&blockTime);
		return;
	    }
	    her = Tcl_NextHashEntry(&hsr);
	}
	hew = Tcl_FirstHashEntry(zmqClientData->writableCommands, &hsw);
	while(hew) {
	    int events = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(Tcl_GetHashKey(zmqClientData->writableCommands, hew), ZMQ_EVENTS, &events, &len);
	    if (!rt && events & ZMQ_POLLOUT) {
		Tcl_SetMaxBlockTime(&blockTime);
		return;
	    }
	    hew = Tcl_NextHashEntry(&hsw);
	}
	if (pme) {
	    Tcl_SetMaxBlockTime(&blockTime);
	    return;
	}
	blockTime.usec = zmqClientData->block_time;
	Tcl_SetMaxBlockTime(&blockTime);
    }

    static int zmqEventProc(Tcl_Event* evp, int flags)
    {
	ZmqEvent* ztep = (ZmqEvent*)evp;
	int rt = Tcl_GlobalEvalObj(ztep->ip, ztep->cmd);
	Tcl_DecrRefCount(ztep->cmd);
	if (rt != TCL_OK)
	    Tcl_BackgroundError(ztep->ip);
	Tcl_Release(ztep->ip);
	return 1;
    }

    static void zmqEventCheck(ClientData cd, int flags)
    {
	ZmqClientData* zmqClientData = (ZmqClientData*)cd;
	Tcl_HashSearch hsr;
	Tcl_HashEntry* her = Tcl_FirstHashEntry(zmqClientData->readableCommands, &hsr);
	Tcl_HashSearch hsw;
	Tcl_HashEntry* hew = 0;
	Tcl_HashSearch hsm;
	Tcl_HashEntry* hem = 0;
	while(her) {
	    int events = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(Tcl_GetHashKey(zmqClientData->readableCommands, her), ZMQ_EVENTS, &events, &len);
	    if (!rt && events & ZMQ_POLLIN) {
		ZmqEvent* ztep = (ZmqEvent*)ckalloc(sizeof(ZmqEvent));
		ztep->event.proc = zmqEventProc;
		ztep->ip = zmqClientData->interp;
		Tcl_Preserve(ztep->ip);
		ztep->cmd = (Tcl_Obj*)Tcl_GetHashValue(her);
		Tcl_IncrRefCount(ztep->cmd);
		Tcl_QueueEvent((Tcl_Event*)ztep, TCL_QUEUE_TAIL);
	    }
	    her = Tcl_NextHashEntry(&hsr);
	}
	hew = Tcl_FirstHashEntry(zmqClientData->writableCommands, &hsw);
	while(hew) {
	    int events = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(Tcl_GetHashKey(zmqClientData->writableCommands, hew), ZMQ_EVENTS, &events, &len);
	    if (!rt && events & ZMQ_POLLOUT) {
		ZmqEvent* ztep = (ZmqEvent*)ckalloc(sizeof(ZmqEvent));
		ztep->event.proc = zmqEventProc;
		ztep->ip = zmqClientData->interp;
		Tcl_Preserve(ztep->ip);
		ztep->cmd = (Tcl_Obj*)Tcl_GetHashValue(hew);
		Tcl_IncrRefCount(ztep->cmd);
		Tcl_QueueEvent((Tcl_Event*)ztep, TCL_QUEUE_TAIL);
	    }
	    hew = Tcl_NextHashEntry(&hsw);
	}
    }
}

critcl::ccommand ::zmq::version {cd ip objc objv} {
    int major=0, minor=0, patch=0;
    char version[128];
    zmq_version(&major, &minor, &patch);
    sprintf(version, "%d.%d.%d", major, minor, patch);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(version, -1));
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::cproc ::zmq::errno {} int {
    return last_zmq_errno;
}

critcl::ccommand ::zmq::strerror {cd ip objc objv} {
    int errnum = 0;
    if (objc != 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "errnum");
	return TCL_ERROR;
    }
    if (Tcl_GetIntFromObj(ip, objv[1], &errnum) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong errnum argument, expected integer", -1));
	return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(errnum), -1));
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::max_block_time {cd ip objc objv} {
    int block_time = 0;
    ZmqClientData* zmqClientData = (ZmqClientData*)cd;
    if (objc != 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "block_time");
	return TCL_ERROR;
    }
    if (Tcl_GetIntFromObj(ip, objv[1], &block_time) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong block_time argument, expected integer", -1));
	return TCL_ERROR;
    }
    zmqClientData->block_time = block_time;
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::context {cd ip objc objv} {
    int io_threads = 1;
    int io_threads_set = 0;
    Tcl_Obj* fqn = 0;
    void* zmqp = 0;
    ZmqContextClientData* ccd = 0;
    int i = 0;
    int newPtr = 0;
    Tcl_HashEntry* hashEntry = 0;
    if (objc < 1 || objc > 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "?name? ?-io_threads io_threads?");
	return TCL_ERROR;
    }
    if (objc % 2) {
	/* No name specified */
	fqn = unique_namespace_name(ip, 0, (ZmqClientData*)cd);
	if (!fqn)
	    return TCL_ERROR;
	i = 1;
    }
    else {
	/* Name specified */
	fqn = unique_namespace_name(ip, objv[1], (ZmqClientData*)cd);
	if (!fqn)
	    return TCL_ERROR;
	i = 2;
    }
    for(; i < objc; i+=2) {
	Tcl_Obj* k = objv[i];
	Tcl_Obj* v = objv[i+1];
	static const char* params[] = {"-io_threads", NULL};
	enum ExObjParams {EXSOCKPARAM_IOTHREADS};
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, k, params, "parameter", 0, &index) != TCL_OK) {
	    Tcl_DecrRefCount(fqn);
	    return TCL_ERROR;
	}
	switch((enum ExObjParams)index) {
	case EXSOCKPARAM_IOTHREADS:
	{
	    if (Tcl_GetIntFromObj(ip, v, &io_threads) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong io_threads argument, expected integer", -1));
		Tcl_DecrRefCount(fqn);
		return TCL_ERROR;
	    }
	    io_threads_set = 1;
	    break;
	}
	}
    }
    zmqp = zmq_ctx_new();
    last_zmq_errno = zmq_errno();
    if (zmqp == NULL) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    if (io_threads_set) {
	int rt = zmq_ctx_set(zmqp, ZMQ_IO_THREADS, io_threads);
	if (rt) {
	    last_zmq_errno = zmq_errno();
	    zmq_ctx_destroy(zmqp);
	    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	    Tcl_DecrRefCount(fqn);
	    return TCL_ERROR;
	}
    }
    ccd = (ZmqContextClientData*)ckalloc(sizeof(ZmqContextClientData));
    ccd->context = zmqp;
    ccd->tcl_cmd = fqn;
    ccd->zmqClientData = cd;
    hashEntry = Tcl_CreateHashEntry(((ZmqClientData*)cd)->contextClientData, zmqp, &newPtr);
    Tcl_SetHashValue(hashEntry, ccd);
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_context_objcmd, (ClientData)ccd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    Tcl_CreateEventSource(zmqEventSetup, zmqEventCheck, cd);
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::socket {cd ip objc objv} {
    Tcl_Obj* fqn = 0;
    void* ctxp = 0;
    int stype = 0;
    int stindex = -1;
    void* sockp = 0;
    ZmqSocketClientData* scd = 0;
    int ctxidx = 2;
    int typeidx = 3;
    Tcl_HashEntry* hashEntry = 0;
    int newPtr = 0;
    static const char* stypes[] = {"PAIR", "PUB", "SUB", "REQ", "REP", "DEALER", "ROUTER", "PULL", "PUSH", "XPUB", "XSUB", "STREAM", NULL};
    enum ExObjSocketMethods {ZST_PAIR, ZST_PUB, ZST_SUB, ZST_REQ, ZST_REP, ZST_DEALER, ZST_ROUTER, ZST_PULL, ZST_PUSH, ZST_XPUB, ZST_XSUB, ZST_STREAM};
    if (objc < 3 || objc > 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "?name? context type");
	return TCL_ERROR;
    }
    if (objc == 3) {
	fqn = unique_namespace_name(ip, NULL, (ZmqClientData*)cd);
	ctxidx = 1;
	typeidx = 2;
    } else {
	fqn = unique_namespace_name(ip, objv[1], (ZmqClientData*)cd);
	if (!fqn)
	    return TCL_ERROR;
	ctxidx = 2;
	typeidx = 3;
    }
    ctxp = known_context(ip, objv[ctxidx]);
    if (!ctxp) {
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(ip, objv[typeidx], stypes, "type", 0, &stindex) != TCL_OK)
	return TCL_ERROR;
    switch((enum ExObjSocketMethods)stindex) {
    case ZST_PAIR: stype = ZMQ_PAIR; break;
    case ZST_PUB: stype = ZMQ_PUB; break;
    case ZST_SUB: stype = ZMQ_SUB; break;
    case ZST_REQ: stype = ZMQ_REQ; break;
    case ZST_REP: stype = ZMQ_REP; break;
    case ZST_DEALER: stype = ZMQ_DEALER; break;
    case ZST_ROUTER: stype = ZMQ_ROUTER; break;
    case ZST_PULL: stype = ZMQ_PULL; break;
    case ZST_PUSH: stype = ZMQ_PUSH; break;
    case ZST_XPUB: stype = ZMQ_XPUB; break;
    case ZST_XSUB: stype = ZMQ_XSUB; break;
    case ZST_STREAM: stype = ZMQ_STREAM; break;
    }
    sockp = zmq_socket(ctxp, stype);
    last_zmq_errno = zmq_errno();
    if (sockp == NULL) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    scd = (ZmqSocketClientData*)ckalloc(sizeof(ZmqSocketClientData));
    scd->context = ctxp;
    scd->socket = sockp;
    scd->tcl_cmd = fqn;
    scd->zmqClientData = cd;
    hashEntry = Tcl_CreateHashEntry(((ZmqClientData*)cd)->socketClientData, sockp, &newPtr);
    Tcl_SetHashValue(hashEntry, scd);
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_socket_objcmd, (ClientData)scd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::message {cd ip objc objv} {
    char* data = 0;
    int size = -1;
    Tcl_Obj* fqn = 0;
    int i;
    void* msgp = 0;
    int rt = 0;
    ZmqMessageClientData* mcd = 0;
    if (objc < 1) {
	Tcl_WrongNumArgs(ip, 1, objv, "?name? ?-size <size>? ?-data <data>?");
	return TCL_ERROR;
    }
    if ((objc-2) % 2) {
	/* No name specified */
	fqn = unique_namespace_name(ip, 0, (ZmqClientData*)cd);
	if (!fqn)
	    return TCL_ERROR;
	i = 1;
    }
    else {
	/* Name specified */
	fqn = unique_namespace_name(ip, objv[1], (ZmqClientData*)cd);
	if (!fqn)
	    return TCL_ERROR;
	i = 2;
    }
    for(; i < objc; i+=2) {
	Tcl_Obj* k = objv[i];
	Tcl_Obj* v = objv[i+1];
	static const char* params[] = {"-data", "-size", NULL};
	enum ExObjParams {EXMSGPARAM_DATA, EXMSGPARAM_SIZE};
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, k, params, "parameter", 0, &index) != TCL_OK) {
	    Tcl_DecrRefCount(fqn);
	    return TCL_ERROR;
	}
	switch((enum ExObjParams)index) {
	case EXMSGPARAM_DATA:
	{
	    data = Tcl_GetStringFromObj(v, &size);
	    break;
	}
	case EXMSGPARAM_SIZE:
	{
	    if (Tcl_GetIntFromObj(ip, v, &size) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong size argument, expected integer", -1));
		Tcl_DecrRefCount(fqn);
		return TCL_ERROR;
	    }
	    break;
	}
	}
    }
    msgp = ckalloc(sizeof(zmq_msg_t));
    if (data) {
	void* buffer = 0;
	if (size < 0)
	    size = strlen(data);
	buffer = ckalloc(size);
	memcpy(buffer, data, size);
	rt = zmq_msg_init_data(msgp, buffer, size, zmq_ckfree, NULL);
    }
    else if (size >= 0) {
	rt = zmq_msg_init_size(msgp, size);
    }
    else {
	rt = zmq_msg_init(msgp);
    }
    last_zmq_errno = zmq_errno();
    if (rt != 0) {
	ckfree(msgp);
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    mcd = (ZmqMessageClientData*)ckalloc(sizeof(ZmqMessageClientData));
    mcd->message = msgp;
    mcd->tcl_cmd = fqn;
    mcd->zmqClientData = cd;
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_message_objcmd, (ClientData)mcd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::poll {cd ip objc objv} {
    int slobjc = 0;
    Tcl_Obj** slobjv = 0;
    int i = 0;
    int timeout = 1; /* default in milliseconds */
    zmq_pollitem_t* sockl = 0;
    int rt = 0;
    Tcl_Obj* result = 0;
    static const char* tounit[] = {"s", "ms", NULL};
    enum ExObjTimeoutUnit {EXTO_S, EXTO_MS};
    int toindex = -1;
    if (objc < 3 || objc > 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "socket_list timeout ?timeout_unit?");
	return TCL_ERROR;
    }
    if (objc == 4 && Tcl_GetIndexFromObj(ip, objv[3], tounit, "timeout_unit", 0, &toindex) != TCL_OK)
	return TCL_ERROR;
    if (Tcl_ListObjGetElements(ip, objv[1], &slobjc, &slobjv) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("sockets_list not specified as list", -1));
	return TCL_ERROR;
    }
    for(i = 0; i < slobjc; i++) {
	int flobjc = 0;
	Tcl_Obj** flobjv = 0;
	int events = 0;
	if (Tcl_ListObjGetElements(ip, slobjv[i], &flobjc, &flobjv) != TCL_OK) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("socket not specified as list", -1));
	    return TCL_ERROR;
	}
	if (flobjc != 2) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("socket not specified as list of <socket_handle list_of_event_flags>", -1));
	    return TCL_ERROR;
	}
	if (!known_socket(ip, flobjv[0]))
	    return TCL_ERROR;
	if (get_poll_flags(ip, flobjv[1], &events) != TCL_OK)
	    return TCL_ERROR;
    }
    if (Tcl_GetIntFromObj(ip, objv[2], &timeout) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong timeout argument, expected integer", -1));
	return TCL_ERROR;
    }
    switch((enum ExObjTimeoutUnit)toindex) {
    case EXTO_S: timeout *= 1000; break;
    case EXTO_MS: break;
    }
    sockl = (zmq_pollitem_t*)ckalloc(sizeof(zmq_pollitem_t) * slobjc);
    for(i = 0; i < slobjc; i++) {
	int flobjc = 0;
	Tcl_Obj** flobjv = 0;
	int elobjc = 0;
	Tcl_Obj** elobjv = 0;
	int events = 0;
	Tcl_ListObjGetElements(ip, slobjv[i], &flobjc, &flobjv);
	Tcl_ListObjGetElements(ip, flobjv[1], &elobjc, &elobjv);
	if (get_poll_flags(ip, flobjv[1], &events) != TCL_OK)
	    return TCL_ERROR;
	sockl[i].socket = known_socket(ip, flobjv[0]);
	sockl[i].fd = 0;
	sockl[i].events = events;
	sockl[i].revents = 0;
    }
    rt = zmq_poll(sockl, slobjc, timeout);
    last_zmq_errno = zmq_errno();
    if (rt < 0) {
	ckfree((void*)sockl);
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	return TCL_ERROR;
    }
    result = Tcl_NewListObj(0, NULL);
    for(i = 0; i < slobjc; i++) {
	if (sockl[i].revents) {
	    int flobjc = 0;
	    Tcl_Obj** flobjv = 0;
	    Tcl_Obj* sresult = 0;
	    Tcl_ListObjGetElements(ip, slobjv[i], &flobjc, &flobjv);
	    sresult = Tcl_NewListObj(0, NULL);
	    Tcl_ListObjAppendElement(ip, sresult, flobjv[0]);
	    Tcl_ListObjAppendElement(ip, sresult, set_poll_flags(ip, sockl[i].revents));
	    Tcl_ListObjAppendElement(ip, result, sresult);
	}
    }
    Tcl_SetObjResult(ip, result);
    ckfree((void*)sockl);
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::device {cd ip objc objv} {
    static const char* devices[] = {"STREAMER", "FORWARDER", "QUEUE", NULL};
    enum ExObjDevices {ZDEV_STREAMER, ZDEV_FORWARDER, ZDEV_QUEUE};
    int dindex = -1;
    int dev = 0;
    void* insocket = 0;
    void* outsocket = 0;
    if (objc != 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "device_type insocket outsocket");
	return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(ip, objv[1], devices, "device", 0, &dindex) != TCL_OK) {
	return TCL_ERROR;
    }
    switch((enum ExObjDevices)dindex) {
    case ZDEV_STREAMER: dev = ZMQ_STREAMER; break;
    case ZDEV_FORWARDER: dev = ZMQ_FORWARDER; break;
    case ZDEV_QUEUE: dev = ZMQ_QUEUE; break;
    }
    insocket = known_socket(ip, objv[2]);
    if (!insocket)
	return TCL_ERROR;
    outsocket = known_socket(ip, objv[3]);
    if (!outsocket)
	return TCL_ERROR;
    zmq_device(dev, insocket, outsocket);
    last_zmq_errno = zmq_errno();
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::proxy {cd ip objc objv} {
    void* frontendsocket = 0;
    void* backendsocket = 0;
    void* capturesocket = 0;
    if (objc < 3 || objc > 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "frontend backend ?capture?");
	return TCL_ERROR;
    }
    frontendsocket = known_socket(ip, objv[1]);
    if (!frontendsocket)
	return TCL_ERROR;
    backendsocket = known_socket(ip, objv[2]);
    if (!backendsocket)
	return TCL_ERROR;
    if (objc > 3) {
	capturesocket = known_socket(ip, objv[3]);
	if (!capturesocket)
	    return TCL_ERROR;
    }
    zmq_proxy(frontendsocket, backendsocket, capturesocket);
    last_zmq_errno = zmq_errno();
    return TCL_OK;
} -clientdata zmqClientDataInitVar

critcl::ccommand ::zmq::zframe_strhex {cd ip objc objv} {
    char* data = 0;
    int size = -1;
    static char hex_char [] = "0123456789ABCDEF";
    char *hex_str = 0;
    int byte_nbr;
    if (objc != 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "string");
	return TCL_ERROR;
    }
    data = Tcl_GetStringFromObj(objv[1], &size);
    hex_str = (char*)ckalloc(size*2+1);
    for (byte_nbr = 0; byte_nbr < size; byte_nbr++) {
	hex_str [byte_nbr * 2 + 0] = hex_char [(data [byte_nbr] >> 4) & 15];
	hex_str [byte_nbr * 2 + 1] = hex_char [data [byte_nbr] & 15];
    }
    hex_str [size * 2] = 0;
    Tcl_SetObjResult(ip, Tcl_NewStringObj(hex_str, -1));
    ckfree(hex_str);
    return TCL_OK;
}

critcl::cinit {
    zmqClientDataInitVar = (ZmqClientData*)ckalloc(sizeof(ZmqClientData));
    zmqClientDataInitVar->interp = interp;
    zmqClientDataInitVar->readableCommands = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientDataInitVar->readableCommands, TCL_ONE_WORD_KEYS);
    zmqClientDataInitVar->writableCommands = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientDataInitVar->writableCommands, TCL_ONE_WORD_KEYS);
    zmqClientDataInitVar->contextClientData = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientDataInitVar->contextClientData, TCL_ONE_WORD_KEYS);
    zmqClientDataInitVar->socketClientData = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientDataInitVar->socketClientData, TCL_ONE_WORD_KEYS);
    zmqClientDataInitVar->block_time = 1000;
    zmqClientDataInitVar->id = 0;
} {
    static ZmqClientData* zmqClientDataInitVar = 0;
}



package provide zmq 4.0.1
