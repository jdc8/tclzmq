package require critcl 3

namespace eval ::zmq {
}

critcl::license {Jos Decoster} {LGPLv3 / BSD}
critcl::summary {A Tcl wrapper for the ZeroMQ messaging library}
critcl::description {
    zmq is a Tcl binding for the zeromq library (http://www.zeromq.org/)
    for interprocess communication.
}
critcl::subject ZeroMQ ZMQ 0MQ \u2205MQ
critcl::subject {messaging} {inter process communication} RPC
critcl::subject {message queue} {queue} broadcast communication
critcl::subject {producer - consumer} {publish - subscribe}

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
#include "pthread.h"

#ifdef _MSC_VER
    typedef __int64          int64_t;
    typedef unsigned __int64 uint64_t;
#else
#include <stdint.h>
#endif

#ifndef ZMQ_HWM
#define ZMQ_HWM 1
#endif

#define TCLZMQ_MAX_PENDING_EVENTS 1024
#define TCLZMQ_MONITOR 0x80000001

    typedef struct {
	Tcl_Interp* ip;
	Tcl_HashTable* readableCommands;
	Tcl_HashTable* writableCommands;
	Tcl_Obj* ctx_monitor_command;
	int block_time;
	int id;
    } ZmqClientData;

    typedef struct {
	void* context;
	ZmqClientData* zmqClientData;
    } ZmqContextClientData;

    typedef struct {
	void* socket;
	ZmqClientData* zmqClientData;
    } ZmqSocketClientData;

    typedef struct {
	void* message;
	ZmqClientData* zmqClientData;
    } ZmqMessageClientData;

    typedef struct {
	Tcl_Event event; /* Must be first */
	Tcl_Interp* ip;
	Tcl_Obj* cmd;
    } ZmqEvent;

    static int last_zmq_errno = 0;
    pthread_mutex_t monitor_mutex = PTHREAD_MUTEX_INITIALIZER;
    typedef struct {
	int event;
	char *data;
    } ZmqPendingMonitorEvent;
    static ZmqPendingMonitorEvent zmq_pending_monitor_events[TCLZMQ_MAX_PENDING_EVENTS];
    static int zmq_pending_monitor_events_counter = 0;

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

    static int get_context_option(Tcl_Interp* ip, Tcl_Obj* obj, int* name)
    {
	static const char* conames[] = { "IO_THREADS", "MAX_SOCKETS", "MONITOR", NULL };
	enum ExObjCOptionNames { CON_IO_THREADS, CON_MAX_SOCKETS, CON_MONITOR };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, conames, "name", 0, &index) != TCL_OK)
	    return TCL_ERROR;
	switch((enum ExObjCOptionNames)index) {
	case CON_IO_THREADS: *name = ZMQ_IO_THREADS; break;
	case CON_MAX_SOCKETS: *name = ZMQ_MAX_SOCKETS; break;
	case CON_MONITOR: *name = TCLZMQ_MONITOR; break;
	}
	return TCL_OK;
    }

    static int get_message_option(Tcl_Interp* ip, Tcl_Obj* obj, int* name)
    {
	static const char* monames[] = { "MORE", NULL };
	enum ExObjMOptionNames { MSG_MORE };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, monames, "name", 0, &index) != TCL_OK)
	    return TCL_ERROR;
	switch((enum ExObjMOptionNames)index) {
	case MSG_MORE: *name = ZMQ_MORE; break;
	}
	return TCL_OK;
    }

    static int get_socket_option(Tcl_Interp* ip, Tcl_Obj* obj, int* name)
    {
	static const char* onames[] = { "HWM", "SNDHWM", "RCVHWM", "AFFINITY", "IDENTITY", "SUBSCRIBE", "UNSUBSCRIBE",
					"RATE", "RECOVERY_IVL", "SNDBUF", "RCVBUF", "RCVMORE", "FD", "EVENTS",
					"TYPE", "LINGER", "RECONNECT_IVL", "BACKLOG", "RECONNECT_IVL_MAX",
					"MAXMSGSIZE", "MULTICAST_HOPS", "RCVTIMEO", "SNDTIMEO", "IPV4ONLY", "LAST_ENDPOINT", "FAIL_UNROUTABLE",
					"TCP_KEEPALIVE", "TCP_KEEPALIVE_CNT", "TCP_KEEPALIVE_IDLE",
					"TCP_KEEPALIVE_INTVL", "TCP_ACCEPT_FILTER", "DELAY_ATTACH_ON_CONNECT", NULL };
	enum ExObjOptionNames { ON_HWM, ON_SNDHWM, ON_RCVHWM, ON_AFFINITY, ON_IDENTITY, ON_SUBSCRIBE, ON_UNSUBSCRIBE,
				ON_RATE, ON_RECOVERY_IVL, ON_SNDBUF, ON_RCVBUF, ON_RCVMORE, ON_FD, ON_EVENTS,
				ON_TYPE, ON_LINGER, ON_RECONNECT_IVL, ON_BACKLOG, ON_RECONNECT_IVL_MAX,
				ON_MAXMSGSIZE, ON_MULTICAST_HOPS, ON_RCVTIMEO, ON_SNDTIMEO, ON_IPV4ONLY, ON_LAST_ENDPOINT,
				ON_FAIL_UNROUTABLE, ON_TCP_KEEPALIVE, ON_TCP_KEEPALIVE_CNT, ON_TCP_KEEPALIVE_IDLE,
				ON_TCP_KEEPALIVE_INTVL, ON_TCP_ACCEPT_FILTER, ON_DELAY_ATTACH_ON_CONNECT };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, onames, "name", 0, &index) != TCL_OK)
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
	case ON_IPV4ONLY: *name = ZMQ_IPV4ONLY; break;
	case ON_LAST_ENDPOINT: *name = ZMQ_LAST_ENDPOINT; break;
	case ON_FAIL_UNROUTABLE: *name = ZMQ_FAIL_UNROUTABLE; break;
	case ON_TCP_KEEPALIVE: *name = ZMQ_TCP_KEEPALIVE; break;
	case ON_TCP_KEEPALIVE_CNT: *name = ZMQ_TCP_KEEPALIVE_CNT; break;
	case ON_TCP_KEEPALIVE_IDLE: *name = ZMQ_TCP_KEEPALIVE_IDLE; break;
	case ON_TCP_KEEPALIVE_INTVL: *name = ZMQ_TCP_KEEPALIVE_INTVL; break;
	case ON_TCP_ACCEPT_FILTER: *name = ZMQ_TCP_ACCEPT_FILTER; break;
	case ON_DELAY_ATTACH_ON_CONNECT: *name = ZMQ_DELAY_ATTACH_ON_CONNECT; break;
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

    static Tcl_Obj* set_monitor_flags(Tcl_Interp* ip, int revents)
    {
	if (revents & ZMQ_EVENT_CONNECTED)
	    return Tcl_NewStringObj("CONNECTED", -1);
	if (revents & ZMQ_EVENT_CONNECT_DELAYED)
	    return Tcl_NewStringObj("CONNECT_DELAYED", -1);
	if (revents & ZMQ_EVENT_CONNECT_RETRIED)
	    return Tcl_NewStringObj("CONNECT_RETRIED", -1);
	if (revents & ZMQ_EVENT_LISTENING)
	    return Tcl_NewStringObj("LISTENING", -1);
	if (revents & ZMQ_EVENT_BIND_FAILED)
	    return Tcl_NewStringObj("BIND_FAILED", -1);
	if (revents & ZMQ_EVENT_ACCEPTED)
	    return Tcl_NewStringObj("ACCEPTED", -1);
	if (revents & ZMQ_EVENT_ACCEPT_FAILED)
	    return Tcl_NewStringObj("ACCEPT_FAILED", -1);
	if (revents & ZMQ_EVENT_CLOSED)
	    return Tcl_NewStringObj("CLOSED", -1);
	if (revents & ZMQ_EVENT_CLOSE_FAILED)
	    return Tcl_NewStringObj("CLOSE_FAILED", -1);
	if (revents & ZMQ_EVENT_DISCONNECTED)
	    return Tcl_NewStringObj("DISCONNECTED", -1);
	return Tcl_NewStringObj("UNKNOWN_MONITOR_EVENT", -1);
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

    static copy_monitor_data(char** dst, char* src)
    {
	char* data = ckalloc(strlen(src)+1);
	strcpy(data, src);
	*dst = data;
    }

    void zmq_ctx_monitor_callback(void *s, int event, zmq_event_data_t *data)
    {
	ZmqPendingMonitorEvent me;
	pthread_mutex_lock(&monitor_mutex);
	if (zmq_pending_monitor_events_counter < TCLZMQ_MAX_PENDING_EVENTS) {
	    me.event = event;
	    me.data = 0;
	    switch(event) {
	    case ZMQ_EVENT_CONNECTED:
		copy_monitor_data(&(me.data), data->connected.addr);
		break;
	    case ZMQ_EVENT_CONNECT_DELAYED:
		copy_monitor_data(&me.data, data->connect_delayed.addr);
		break;
	    case ZMQ_EVENT_CONNECT_RETRIED:
		copy_monitor_data(&me.data, data->connect_retried.addr);
		break;
	    case ZMQ_EVENT_LISTENING:
		copy_monitor_data(&me.data, data->listening.addr);
		break;
	    case ZMQ_EVENT_BIND_FAILED:
		copy_monitor_data(&me.data, data->bind_failed.addr);
		break;
	    case ZMQ_EVENT_ACCEPTED:
		copy_monitor_data(&me.data, data->accepted.addr);
		break;
	    case ZMQ_EVENT_ACCEPT_FAILED:
		copy_monitor_data(&me.data, data->accept_failed.addr);
		break;
	    case ZMQ_EVENT_CLOSED:
		copy_monitor_data(&me.data, data->closed.addr);
		break;
	    case ZMQ_EVENT_CLOSE_FAILED:
		copy_monitor_data(&me.data, data->close_failed.addr);
		break;
	    case ZMQ_EVENT_DISCONNECTED:
		copy_monitor_data(&me.data, data->disconnected.addr);
		break;
	    }
	    zmq_pending_monitor_events[zmq_pending_monitor_events_counter] = me;
	    zmq_pending_monitor_events_counter++;
	}
	Tcl_Time waitTime = { 0, 0 };
	Tcl_WaitForEvent(&waitTime);
	pthread_mutex_unlock(&monitor_mutex);
    }

    int zmq_context_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"destroy", "get", "set", "term", NULL};
	enum ExObjContextMethods {EXCTXOBJ_DESTROY, EXCTXOBJ_GET, EXCTXOBJ_SET, EXCTXOBJ_TERM};
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
	case EXCTXOBJ_DESTROY:
	case EXCTXOBJ_TERM:
	{
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    rt = zmq_term(zmqp);
	    last_zmq_errno = zmq_errno();
	    if (rt == 0) {
		Tcl_DeleteCommand(ip, Tcl_GetStringFromObj(objv[0], 0));
	    }
	    else {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXCTXOBJ_GET:
	{
	    int name = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "name");
		return TCL_ERROR;
	    }
	    if (get_context_option(ip, objv[2], &name) != TCL_OK)
                return TCL_ERROR;
	    if (name == TCLZMQ_MONITOR) {
		ZmqClientData* zmqClientData = (((ZmqSocketClientData*)cd)->zmqClientData);
		Tcl_Obj* result = 0;
		if (zmqClientData->ctx_monitor_command)
		    result = zmqClientData->ctx_monitor_command;
		else
		    result = Tcl_NewListObj(0, NULL);
		Tcl_SetObjResult(ip, result);
	    }
	    else {
		int val = zmq_ctx_get(zmqp, name);
		last_zmq_errno = zmq_errno();
		if (val < 0) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		    return TCL_ERROR;
		}
		Tcl_SetObjResult(ip, Tcl_NewIntObj(val));
	    }
	    break;
	}
	case EXCTXOBJ_SET:
	{
	    int name = 0;
	    int rt = 0;
	    if (objc != 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value");
		return TCL_ERROR;
	    }
	    if (get_context_option(ip, objv[2], &name) != TCL_OK)
                return TCL_ERROR;
	    if (name == TCLZMQ_MONITOR) {
		ZmqClientData* zmqClientData = (((ZmqSocketClientData*)cd)->zmqClientData);
		int clen = 0;
		if (Tcl_ListObjLength(ip, objv[3], &clen) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("command not passed as a list", -1));
		    return TCL_ERROR;
		}
		if (zmqClientData->ctx_monitor_command) {
		    Tcl_DecrRefCount(zmqClientData->ctx_monitor_command);
		    zmqClientData->ctx_monitor_command = 0;
		    rt = zmq_ctx_set_monitor(zmqp, 0);
		}
		if (!rt && clen) {
		    zmqClientData->ctx_monitor_command = objv[3];
		    Tcl_IncrRefCount(zmqClientData->ctx_monitor_command);
		    rt = zmq_ctx_set_monitor(zmqp, zmq_ctx_monitor_callback);
		}
	    }
	    else {
		int val = -1;
		if (Tcl_GetIntFromObj(ip, objv[3], &val) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong option value, expected integer", -1));
		    return TCL_ERROR;
		}
		rt = zmq_ctx_set(zmqp, name, val);
	    }
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

    int zmq_socket_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"bind", "close", "connect", "disconnect", "get", "getsockopt",
					"readable", "recv_msg", "send_msg", "dump", "recv", "send",
					"sendmore", "set", "setsockopt", "unbind", "writable", NULL};
	enum ExObjSocketMethods {EXSOCKOBJ_BIND, EXSOCKOBJ_CLOSE, EXSOCKOBJ_CONNECT, EXSOCKOBJ_DISCONNECT, EXSOCKOBJ_GET, EXSOCKOBJ_GETSOCKETOPT,
				 EXSOCKOBJ_READABLE, EXSOCKOBJ_RECV, EXSOCKOBJ_SEND, EXSOCKOBJ_S_DUMP, EXSOCKOBJ_S_RECV, EXSOCKOBJ_S_SEND,
				 EXSOCKOBJ_S_SENDMORE, EXSOCKOBJ_SET, EXSOCKOBJ_SETSOCKETOPT, EXSOCKOBJ_UNBIND, EXSOCKOBJ_WRITABLE};
	int index = -1;
	void* sockp = ((ZmqSocketClientData*)cd)->socket;
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
		Tcl_DeleteCommand(ip, Tcl_GetStringFromObj(objv[0], 0));
	    }
	    else {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
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
	case EXSOCKOBJ_GET:
	case EXSOCKOBJ_GETSOCKETOPT:
	{
	    int name = -1;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "name");
		return TCL_ERROR;
	    }
	    if (get_socket_option(ip, objv[2], &name) != TCL_OK)
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
	    case ZMQ_IPV4ONLY:
	    case ZMQ_TCP_KEEPALIVE:
	    case ZMQ_TCP_KEEPALIVE_CNT:
	    case ZMQ_TCP_KEEPALIVE_IDLE:
	    case ZMQ_TCP_KEEPALIVE_INTVL:
	    case ZMQ_DELAY_ATTACH_ON_CONNECT:
 	    {
		int val = 0;
		size_t len = sizeof(int);
		int rt = zmq_getsockopt(sockp, name, &val, &len);
		last_zmq_errno = zmq_errno();
		if (rt != 0) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		    return TCL_ERROR;
		}
		Tcl_SetObjResult(ip, Tcl_NewIntObj(val));
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
		Tcl_SetObjResult(ip, set_poll_flags(ip, val));
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
		Tcl_SetObjResult(ip, Tcl_NewWideIntObj(val));
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
		Tcl_SetObjResult(ip, Tcl_NewWideIntObj(val));
		break;
	    }
	    /* binary options */
            case ZMQ_IDENTITY:
            case ZMQ_LAST_ENDPOINT:
	    {
		const char val[256];
		size_t len = 256;
		int rt = zmq_getsockopt(sockp, name, (void*)val, &len);
		last_zmq_errno = zmq_errno();
		if (rt != 0) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		    return TCL_ERROR;
		}
		Tcl_SetObjResult(ip, Tcl_NewStringObj(val, len));
		break;
	    }
            default:
	    {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("unsupported option", -1));
		return TCL_ERROR;
	    }
	    }
	    break;
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
	    int name = -1;
	    if (objc < 4 || objc > 5) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value ?size?");
		return TCL_ERROR;
	    }
	    if (get_socket_option(ip, objv[2], &name) != TCL_OK)
                return TCL_ERROR;
	    switch(name) {
		/* int options */
            case ZMQ_HWM:
	    {
		int val = 0;
		int rt = 0;
		if (Tcl_GetIntFromObj(ip, objv[3], &val) != TCL_OK) {
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
	    case ZMQ_IPV4ONLY:
	    case ZMQ_FAIL_UNROUTABLE:
	    case ZMQ_TCP_KEEPALIVE:
	    case ZMQ_TCP_KEEPALIVE_CNT:
	    case ZMQ_TCP_KEEPALIVE_IDLE:
	    case ZMQ_TCP_KEEPALIVE_INTVL:
	    case ZMQ_DELAY_ATTACH_ON_CONNECT:
	    {
		int val = 0;
		int rt = 0;
		if (Tcl_GetIntFromObj(ip, objv[3], &val) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong HWM argument, expected integer", -1));
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
		int64_t val = 0;
		uint64_t uval = 0;
		int rt = 0;
		if (Tcl_GetWideIntFromObj(ip, objv[3], &val) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong HWM argument, expected integer", -1));
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
		int64_t val = 0;
		int rt = 0;
		if (Tcl_GetWideIntFromObj(ip, objv[3], &val) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong HWM argument, expected integer", -1));
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
	    case ZMQ_TCP_ACCEPT_FILTER:
	    {
		int len = 0;
		const char* val = 0;
		int rt = 0;
		int size = -1;
		val = Tcl_GetStringFromObj(objv[3], &len);
		if (objc > 4) {
		    if (Tcl_GetIntFromObj(ip, objv[4], &size) != TCL_OK) {
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
            default:
	    {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("unsupported option", -1));
		return TCL_ERROR;
	    }
	    }
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
        }
 	return TCL_OK;
    }

    int zmq_message_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"close", "copy", "data", "move", "size", "dump", "get", "set", "send", "sendmore", "recv", "more", NULL};
	enum ExObjMessageMethods {EXMSGOBJ_CLOSE, EXMSGOBJ_COPY, EXMSGOBJ_DATA, EXMSGOBJ_MOVE, EXMSGOBJ_SIZE, EXMSGOBJ_SDUMP, EXMSGOBJ_GET, EXMSGOBJ_SET, EXMSGOBJ_SEND, EXMSGOBJ_SENDMORE, EXMSGOBJ_RECV, EXMSGOBJ_MORE};
	int index = -1;
	void* msgp = 0;
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	msgp = ((ZmqSocketClientData*)cd)->socket;
	switch((enum ExObjMessageMethods)index) {
	case EXMSGOBJ_CLOSE:
	{
	    int rt = 0;
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    rt = zmq_msg_close(msgp);
	    last_zmq_errno = zmq_errno();
	    if (rt == 0) {
		Tcl_DeleteCommand(ip, Tcl_GetStringFromObj(objv[0], 0));
	    }
	    else {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
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
	case EXMSGOBJ_GET:
	{
	    int name = 0;
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "name");
		return TCL_ERROR;
	    }
	    if (get_message_option(ip, objv[2], &name) != TCL_OK)
		return TCL_ERROR;
	    switch(name) {
	    case ZMQ_MORE:
	    {
		int rt = zmq_msg_get(msgp, name);
		last_zmq_errno = zmq_errno();
		if (rt < 0) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		    return TCL_ERROR;

		}
		Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
		break;
	    }
	    default:
	    {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("unsupported option", -1));
		return TCL_ERROR;
	    }
	    }
	    break;
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
	    int name = 0;
	    int val = 0;
	    if (objc != 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value");
		return TCL_ERROR;
	    }
	    if (get_message_option(ip, objv[2], &name) != TCL_OK)
		return TCL_ERROR;
	    if (Tcl_GetIntFromObj(ip, objv[3], &val) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong option value, expected integer", -1));
		return TCL_ERROR;
	    }
	    switch(name) {
	    default:
	    {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("unsupported option", -1));
		return TCL_ERROR;
	    }
	    }
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
	pthread_mutex_lock(&monitor_mutex);
	int pme = zmq_pending_monitor_events_counter;
	pthread_mutex_unlock(&monitor_mutex);
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
	while(her) {
	    int events = 0;
	    size_t len = sizeof(int);
	    int rt = zmq_getsockopt(Tcl_GetHashKey(zmqClientData->readableCommands, her), ZMQ_EVENTS, &events, &len);
	    if (!rt && events & ZMQ_POLLIN) {
		ZmqEvent* ztep = (ZmqEvent*)ckalloc(sizeof(ZmqEvent));
		ztep->event.proc = zmqEventProc;
		ztep->ip = zmqClientData->ip;
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
		ztep->ip = zmqClientData->ip;
		Tcl_Preserve(ztep->ip);
		ztep->cmd = (Tcl_Obj*)Tcl_GetHashValue(hew);
		Tcl_IncrRefCount(ztep->cmd);
		Tcl_QueueEvent((Tcl_Event*)ztep, TCL_QUEUE_TAIL);
	    }
	    hew = Tcl_NextHashEntry(&hsw);
	}
	pthread_mutex_lock(&monitor_mutex);
	if (zmq_pending_monitor_events_counter && zmqClientData->ctx_monitor_command) {
	    int i;
	    for(i = 0; i < zmq_pending_monitor_events_counter; i++) {
		ZmqEvent* ztep = (ZmqEvent*)ckalloc(sizeof(ZmqEvent));
		Tcl_Obj* cmd = Tcl_DuplicateObj(zmqClientData->ctx_monitor_command);
		Tcl_ListObjAppendElement(zmqClientData->ip, cmd, set_monitor_flags(zmqClientData->ip, zmq_pending_monitor_events[i].event));
		if (zmq_pending_monitor_events[i].data) {
		    Tcl_ListObjAppendElement(zmqClientData->ip, cmd, Tcl_NewStringObj(zmq_pending_monitor_events[i].data, -1));
		}
		else {
		    Tcl_ListObjAppendElement(zmqClientData->ip, cmd, Tcl_NewStringObj("", -1));
		}
		ztep->event.proc = zmqEventProc;
		ztep->ip = zmqClientData->ip;
		Tcl_Preserve(ztep->ip);
		ztep->cmd = cmd;
		Tcl_IncrRefCount(ztep->cmd);
		Tcl_QueueEvent((Tcl_Event*)ztep, TCL_QUEUE_TAIL);
		ckfree(zmq_pending_monitor_events[i].data);
	    }
	}
	zmq_pending_monitor_events_counter = 0;
	pthread_mutex_unlock(&monitor_mutex);
    }
}

critcl::ccommand ::zmq::version {cd ip objc objv} -clientdata zmqClientDataInitVar {
    int major=0, minor=0, patch=0;
    char version[128];
    zmq_version(&major, &minor, &patch);
    sprintf(version, "%d.%d.%d", major, minor, patch);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(version, -1));
    return TCL_OK;
}

critcl::cproc ::zmq::errno {} int {
    return last_zmq_errno;
}

critcl::ccommand ::zmq::strerror {cd ip objc objv} -clientdata zmqClientDataInitVar {
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
}

critcl::ccommand ::zmq::max_block_time {cd ip objc objv} -clientdata zmqClientDataInitVar {
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
}

critcl::ccommand ::zmq::context {cd ip objc objv} -clientdata zmqClientDataInitVar {
    int io_threads = 1;
    int io_threads_set = 0;
    Tcl_Obj* fqn = 0;
    void* zmqp = 0;
    ZmqContextClientData* ccd = 0;
    int i = 0;
    if (objc < 1 || objc > 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "?name? ?-iothreads io_threads?");
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
    ccd->zmqClientData = cd;
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_context_objcmd, (ClientData)ccd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    Tcl_CreateEventSource(zmqEventSetup, zmqEventCheck, cd);
    return TCL_OK;
}

critcl::ccommand ::zmq::socket {cd ip objc objv} -clientdata zmqClientDataInitVar {
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
    static const char* stypes[] = {"PAIR", "PUB", "SUB", "REQ", "REP", "DEALER", "ROUTER", "PULL", "PUSH", "XPUB", "XSUB", NULL};
    enum ExObjSocketMethods {ZST_PAIR, ZST_PUB, ZST_SUB, ZST_REQ, ZST_REP, ZST_DEALER, ZST_ROUTER, ZST_PULL, ZST_PUSH, ZST_XPUB, ZST_XSUB};
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
    }
    sockp = zmq_socket(ctxp, stype);
    last_zmq_errno = zmq_errno();
    if (sockp == NULL) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    scd = (ZmqSocketClientData*)ckalloc(sizeof(ZmqSocketClientData));
    scd->socket = sockp;
    scd->zmqClientData = cd;
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_socket_objcmd, (ClientData)scd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    return TCL_OK;
}

critcl::ccommand ::zmq::message {cd ip objc objv} -clientdata zmqClientDataInitVar {
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
    msgp = ckalloc(32);
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
    mcd->zmqClientData = cd;
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_message_objcmd, (ClientData)mcd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    return TCL_OK;
}

critcl::ccommand ::zmq::poll {cd ip objc objv} -clientdata zmqClientDataInitVar {
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
}

critcl::ccommand ::zmq::device {cd ip objc objv} -clientdata zmqClientDataInitVar {
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
}

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
    zmqClientDataInitVar->ip = ip;
    zmqClientDataInitVar->readableCommands = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientDataInitVar->readableCommands, TCL_ONE_WORD_KEYS);
    zmqClientDataInitVar->writableCommands = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientDataInitVar->writableCommands, TCL_ONE_WORD_KEYS);
    zmqClientDataInitVar->ctx_monitor_command = 0;
    zmqClientDataInitVar->block_time = 1000;
    zmqClientDataInitVar->id = 0;
} {
    static ZmqClientData* zmqClientDataInitVar = 0;
}



package provide zmq 3.3.0
