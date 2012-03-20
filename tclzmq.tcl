set tclzmqdir ../libzmq

###############################################################################

package require critcl 3

namespace eval ::tclzmq {
}

critcl::cheaders $tclzmqdir/include/zmq.h -I$tclzmqdir/include
critcl::clibraries $tclzmqdir/lib/libzmq.a -lstdc++ -lpthread -lm -lrt -luuid
critcl::cflags -I $tclzmqdir/include
critcl::tsources tclzmq_helper.tcl

#critcl::debug all
#critcl::config keepsrc 1

critcl::ccode {

#include "errno.h"
#include "string.h"
#include "stdint.h"
#include "zmq.h"

    typedef struct {
	Tcl_Interp* ip;
	Tcl_HashTable* readableCommands;
	Tcl_HashTable* writableCommands;
	int block_time;
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

    static void* known_context(Tcl_Interp* ip, Tcl_Obj* obj) {
	void* p = known_command(ip, obj, "context");
	if (p)
	    return ((ZmqContextClientData*)p)->context;
	return 0;
    }

    static void* known_socket(Tcl_Interp* ip, Tcl_Obj* obj) {
	void* p = known_command(ip, obj, "socket");
	if (p)
	    return ((ZmqSocketClientData*)p)->socket;
	return 0;
    }

    static void* known_message(Tcl_Interp* ip, Tcl_Obj* obj) {
	void* p = known_command(ip, obj, "message");
	if (p)
	    return ((ZmqMessageClientData*)p)->message;
	return 0;
    }

    static int get_socket_option(Tcl_Interp* ip, Tcl_Obj* obj, int* name) 
    {
	static const char* onames[] = { "HWM", "SWAP", "AFFINITY", "IDENTITY", "SUBSCRIBE", "UNSUBSCRIBE",
					"RATE", "RECOVERY_IVL", "MCAST_LOOP", "SNDBUF", "RCVBUF", "RCVMORE", "FD", "EVENTS",
					"TYPE", "LINGER", "RECONNECT_IVL", "BACKLOG", "RECOVERY_IVL_MSEC", "RECONNECT_IVL_MAX", NULL };
	enum ExObjOptionNames { ON_HWM, ON_SWAP, ON_AFFINITY, ON_IDENTITY, ON_SUBSCRIBE, ON_UNSUBSCRIBE,
				ON_RATE, ON_RECOVERY_IVL, ON_MCAST_LOOP, ON_SNDBUF, ON_RCVBUF, ON_RCVMORE, ON_FD, ON_EVENTS,
				ON_TYPE, ON_LINGER, ON_RECONNECT_IVL, ON_BACKLOG, ON_RECOVERY_IVL_MSEC, ON_RECONNECT_IVL_MAX };
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, obj, onames, "name", 0, &index) != TCL_OK)
	    return TCL_ERROR;
	switch((enum ExObjOptionNames)index) {
	case ON_HWM: *name = ZMQ_HWM; break;
	case ON_SWAP: *name = ZMQ_SWAP; break;
	case ON_AFFINITY: *name = ZMQ_AFFINITY; break;
	case ON_IDENTITY: *name = ZMQ_IDENTITY; break;
	case ON_SUBSCRIBE: *name = ZMQ_SUBSCRIBE; break;
	case ON_UNSUBSCRIBE: *name = ZMQ_UNSUBSCRIBE; break;
	case ON_RATE: *name = ZMQ_RATE; break;
	case ON_RECOVERY_IVL: *name = ZMQ_RECOVERY_IVL; break;
	case ON_MCAST_LOOP: *name = ZMQ_MCAST_LOOP; break;
	case ON_SNDBUF: *name = ZMQ_SNDBUF; break;
	case ON_RCVBUF: *name = ZMQ_RCVBUF; break;
	case ON_RCVMORE: *name = ZMQ_RCVMORE; break;
	case ON_FD: *name = ZMQ_FD; break;
	case ON_EVENTS: *name = ZMQ_EVENTS; break;
	case ON_TYPE: *name = ZMQ_TYPE; break;
	case ON_LINGER: *name = ZMQ_LINGER; break;
	case ON_RECONNECT_IVL: *name = ZMQ_RECONNECT_IVL; break;
	case ON_BACKLOG: *name = ZMQ_BACKLOG; break;
	case ON_RECOVERY_IVL_MSEC: *name = ZMQ_RECOVERY_IVL_MSEC; break;
	case ON_RECONNECT_IVL_MAX: *name = ZMQ_RECONNECT_IVL_MAX; break;
	}
	return TCL_OK;
    }

    static int get_poll_flags(Tcl_Interp* ip, Tcl_Obj* fl, int* events)
    {
	int objc = 0;
	Tcl_Obj** objv = 0;
	if (Tcl_ListObjGetElements(ip, fl, &objc, &objv) != TCL_OK) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("event flags not specified as list", -1));
	    return TCL_ERROR;
	}
	int i = 0;
	for(i = 0; i < objc; i++) {
	    static const char* eflags[] = {"POLLIN", "POLLOUT", "POLLERR", NULL};
	    enum ExObjEventFlags {ZEF_POLLIN, ZEF_POLLOUT, ZEF_POLLERR};
	    int efindex = -1;
	    Tcl_GetIndexFromObj(ip, objv[i], eflags, "event_flag", 0, &efindex);
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

    static int get_recv_send_flag(Tcl_Interp* ip, Tcl_Obj* fl, int* flags)
    {
	int objc = 0;
	Tcl_Obj** objv = 0;
	if (Tcl_ListObjGetElements(ip, fl, &objc, &objv) != TCL_OK) {
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("flags not specified as list", -1));
	    return TCL_ERROR;
	}
	int i = 0;
	for(i = 0; i < objc; i++) {
	    static const char* rsflags[] = {"NOBLOCK", "SNDMORE", NULL};
	    enum ExObjRSFlags {RSF_NOBLOCK, RSF_SNDMORE};
	    int index = -1;
	    if (Tcl_GetIndexFromObj(ip, objv[i], rsflags, "flag", 0, &index) != TCL_OK)
                return TCL_ERROR;
	    switch((enum ExObjRSFlags)index) {
	    case RSF_NOBLOCK: *flags = *flags | ZMQ_NOBLOCK; break;
	    case RSF_SNDMORE: *flags = *flags | ZMQ_SNDMORE; break;
	    }
        }
	return TCL_OK;
    }

    static void zmq_s_dump(const char* data, int size) {
	int is_text = 1;
	int char_nbr;
	for (char_nbr = 0; char_nbr < size; char_nbr++)
	    if ((unsigned char) data [char_nbr] < 32
		|| (unsigned char) data [char_nbr] > 127)
		is_text = 0;

	printf ("[%03d] ", size);
	for (char_nbr = 0; char_nbr < size; char_nbr++) {
	    if (is_text)
		printf ("%c", data [char_nbr]);
	    else
		printf ("%02X", (unsigned char) data [char_nbr]);
	}
	printf ("\n");
    }

    int zmq_context_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"term", NULL};
	enum ExObjContextMethods {EXCTXOBJ_TERM};
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	void* zmqp = ((ZmqContextClientData*)cd)->context;
	switch((enum ExObjContextMethods)index) {
	case EXCTXOBJ_TERM:
	{
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    int rt = zmq_term(zmqp);
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
        }
 	return TCL_OK;
    }

    int zmq_socket_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"bind", "close", "connect", "getsockopt", "readable",
					"recv", "send", "s_dump", "s_recv", "s_send", "s_sendmore",
					"setsockopt", "writable", NULL};
	enum ExObjSocketMethods {EXSOCKOBJ_BIND, EXSOCKOBJ_CLOSE, EXSOCKOBJ_CONNECT, EXSOCKOBJ_GETSOCKETOPT,
				 EXSOCKOBJ_READABLE, EXSOCKOBJ_RECV, EXSOCKOBJ_SEND, EXSOCKOBJ_S_DUMP, EXSOCKOBJ_S_RECV,
	                         EXSOCKOBJ_S_SEND, EXSOCKOBJ_S_SENDMORE, EXSOCKOBJ_SETSOCKETOPT, EXSOCKOBJ_WRITABLE};
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	void* sockp = ((ZmqSocketClientData*)cd)->socket;
	switch((enum ExObjSocketMethods)index) {
        case EXSOCKOBJ_BIND:
        {
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "addr");
		return TCL_ERROR;
	    }
	    const char* addr = Tcl_GetStringFromObj(objv[2], 0);
	    int rt = zmq_bind(sockp, addr);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_CLOSE:
	{
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    int rt = zmq_close(sockp);
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
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "addr");
		return TCL_ERROR;
	    }
	    const char* addr = Tcl_GetStringFromObj(objv[2], 0);
	    int rt = zmq_connect(sockp, addr);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_GETSOCKETOPT:
	{
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "name");
		return TCL_ERROR;
	    }
	    int name = -1;
	    if (get_socket_option(ip, objv[2], &name) != TCL_OK)
                return TCL_ERROR;
	    switch(name) {
		/* int options */
            case ZMQ_TYPE:
            case ZMQ_LINGER:
            case ZMQ_RECONNECT_IVL:
            case ZMQ_RECONNECT_IVL_MAX:
            case ZMQ_BACKLOG:
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
            case ZMQ_HWM:
            case ZMQ_AFFINITY:
            case ZMQ_SNDBUF:
            case ZMQ_RCVBUF:
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
            case ZMQ_RCVMORE:
            case ZMQ_SWAP:
            case ZMQ_RATE:
            case ZMQ_RECOVERY_IVL:
            case ZMQ_RECOVERY_IVL_MSEC:
            case ZMQ_MCAST_LOOP:
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
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "command");
		return TCL_ERROR;
	    }
	    // If [llength $command] == 0 => delete readable event if present
	    int len = 0;
	    if (Tcl_ListObjLength(ip, objv[2], &len) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("command not passed as a list", -1));
		return TCL_ERROR;
	    }
	    // If socket already present, replace the command
	    ZmqClientData* zmqClientData = (((ZmqSocketClientData*)cd)->zmqClientData);
	    Tcl_HashEntry* currCommand = Tcl_FindHashEntry(zmqClientData->readableCommands, sockp);
	    if (currCommand) {
		Tcl_Obj* old_command = (Tcl_Obj*)Tcl_GetHashValue(currCommand);
		Tcl_DecrRefCount(old_command);
		if (len) {
		    // Replace
		    Tcl_IncrRefCount(objv[2]);
		    Tcl_HashEntry *newPtr = 0;
		    Tcl_SetHashValue(currCommand, objv[2]);
		}
		else {
		    // Remove
		    Tcl_DeleteHashEntry(currCommand);
		}
	    }
	    else {
		if (len) {
		    // Add
		    Tcl_IncrRefCount(objv[2]);
		    int newPtr = 0;
		    currCommand = Tcl_CreateHashEntry(zmqClientData->readableCommands, sockp, &newPtr);
		    Tcl_SetHashValue(currCommand, objv[2]);
		}
	    }
	    Tcl_Time waitTime = { 0, 0 };
	    Tcl_WaitForEvent(&waitTime);
	    break;
	}
	case EXSOCKOBJ_RECV:
	{
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "message ?flags?");
		return TCL_ERROR;
	    }
	    void* msgp = known_message(ip, objv[2]);
	    if (msgp == NULL) {
		return TCL_ERROR;
	    }
	    int flags = 0;
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    int rt = zmq_recv(sockp, msgp, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt == 0 || (rt != 0 && flags & ZMQ_NOBLOCK)) {
		Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    }
	    else if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_SEND:
	{
	    if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(ip, 2, objv, "message ?flags?");
		return TCL_ERROR;
	    }
	    void* msgp = known_message(ip, objv[2]);
	    if (msgp == NULL) {
		return TCL_ERROR;
	    }
	    int flags = 0;
	    if (objc > 3 && get_recv_send_flag(ip, objv[3], &flags) != TCL_OK) {
	        return TCL_ERROR;
	    }
	    int rt = zmq_send(sockp, msgp, flags);
	    last_zmq_errno = zmq_errno();
	    if (rt == 0 || (rt != 0 && flags & ZMQ_NOBLOCK)) {
		Tcl_SetObjResult(ip, Tcl_NewIntObj(rt));
	    }
	    else if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_S_DUMP:
	{
	    puts ("----------------------------------------");
	    while (1) {
		// Process all parts of the message
		zmq_msg_t message;
		zmq_msg_init (&message);
		zmq_recv (sockp, &message, 0);

		// Dump the message as text or binary
		zmq_s_dump(zmq_msg_data(&message), zmq_msg_size(&message));

		int64_t more; // Multipart detection
		size_t more_size = sizeof (more);
		zmq_getsockopt (sockp, ZMQ_RCVMORE, &more, &more_size);
		zmq_msg_close (&message);
		if (!more)
		    break; // Last message part
	    }
	    break;
	}
	case EXSOCKOBJ_S_RECV:
	{
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    zmq_msg_t msg;
	    int rt = zmq_msg_init(&msg);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    rt = zmq_recv(sockp, &msg, 0);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
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
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "data");
		return TCL_ERROR;
	    }
	    int size = 0;
	    char* data = Tcl_GetStringFromObj(objv[2], &size);
	    void* buffer = ckalloc(size);
	    memcpy(buffer, data, size);
	    zmq_msg_t msg;
	    int rt = zmq_msg_init_data(&msg, buffer, size, zmq_ckfree, NULL);
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    rt = zmq_send(sockp, &msg, 0);
	    last_zmq_errno = zmq_errno();
	    zmq_msg_close(&msg);
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_S_SENDMORE:
	{
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "data");
		return TCL_ERROR;
	    }
	    int size = 0;
	    char* data = Tcl_GetStringFromObj(objv[2], &size);
	    void* buffer = ckalloc(size);
	    memcpy(buffer, data, size);
	    zmq_msg_t msg;
	    int rt = zmq_msg_init_data(&msg, buffer, size, zmq_ckfree, NULL);
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    rt = zmq_send(sockp, &msg, ZMQ_SNDMORE);
	    last_zmq_errno = zmq_errno();
	    zmq_msg_close(&msg);
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
	    }
	    break;
	}
	case EXSOCKOBJ_SETSOCKETOPT:
	{
	    if (objc < 4 || objc > 5) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value ?size?");
		return TCL_ERROR;
	    }
	    int name = -1;
	    if (get_socket_option(ip, objv[2], &name) != TCL_OK)
                return TCL_ERROR;
	    switch(name) {
		/* int options */
            case ZMQ_LINGER:
            case ZMQ_RECONNECT_IVL:
            case ZMQ_RECONNECT_IVL_MAX:
            case ZMQ_BACKLOG:
	    {
		int val = 0;
		if (Tcl_GetIntFromObj(ip, objv[3], &val) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong HWM argument, expected integer", -1));
		    return TCL_ERROR;
		}
		int rt = zmq_setsockopt(sockp, name, &val, sizeof val);
		last_zmq_errno = zmq_errno();
		if (rt != 0) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		    return TCL_ERROR;
		}
		break;
	    }
	    /* uint64_t options */
            case ZMQ_HWM:
            case ZMQ_AFFINITY:
            case ZMQ_SNDBUF:
            case ZMQ_RCVBUF:
	    {
		int64_t val = 0;
		if (Tcl_GetWideIntFromObj(ip, objv[3], &val) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong HWM argument, expected integer", -1));
		    return TCL_ERROR;
		}
		uint64_t uval = val;
		int rt = zmq_setsockopt(sockp, name, &uval, sizeof uval);
		last_zmq_errno = zmq_errno();
		if (rt != 0) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		    return TCL_ERROR;
		}
		break;
	    }
	    /* int64_t options */
            case ZMQ_SWAP:
            case ZMQ_RATE:
            case ZMQ_RECOVERY_IVL:
            case ZMQ_RECOVERY_IVL_MSEC:
            case ZMQ_MCAST_LOOP:
	    {
		int64_t val = 0;
		if (Tcl_GetWideIntFromObj(ip, objv[3], &val) != TCL_OK) {
		    Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong HWM argument, expected integer", -1));
		    return TCL_ERROR;
		}
		int rt = zmq_setsockopt(sockp, name, &val, sizeof val);
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
		const char* val = Tcl_GetStringFromObj(objv[3], &len);
		int rt = zmq_setsockopt(sockp, name, val, len);
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
	case EXSOCKOBJ_WRITABLE:
	{
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "command");
		return TCL_ERROR;
	    }
	    // If [llength $command] == 0 => delete writable event if present
	    int len = 0;
	    if (Tcl_ListObjLength(ip, objv[2], &len) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("command not passed as a list", -1));
		return TCL_ERROR;
	    }
	    // If socket already present, replace the command
	    ZmqClientData* zmqClientData = (((ZmqSocketClientData*)cd)->zmqClientData);
	    Tcl_HashEntry* currCommand = Tcl_FindHashEntry(zmqClientData->writableCommands, sockp);
	    if (currCommand) {
		Tcl_Obj* old_command = (Tcl_Obj*)Tcl_GetHashValue(currCommand);
		Tcl_DecrRefCount(old_command);
		if (len) {
		    // Replace
		    Tcl_IncrRefCount(objv[2]);
		    Tcl_HashEntry *newPtr = 0;
		    Tcl_SetHashValue(currCommand, objv[2]);
		}
		else {
		    // Remove
		    Tcl_DeleteHashEntry(currCommand);
		}
	    }
	    else {
		if (len) {
		    // Add
		    Tcl_IncrRefCount(objv[2]);
		    int newPtr = 0;
		    currCommand = Tcl_CreateHashEntry(zmqClientData->writableCommands, sockp, &newPtr);
		    Tcl_SetHashValue(currCommand, objv[2]);
		}
	    }
	    Tcl_Time waitTime = { 0, 0 };
	    Tcl_WaitForEvent(&waitTime);
	    break;
	}
        }
 	return TCL_OK;
    }

    int zmq_message_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"close", "copy", "data", "move", "size", "s_dump", NULL};
	enum ExObjMessageMethods {EXMSGOBJ_CLOSE, EXMSGOBJ_COPY, EXMSGOBJ_DATA, EXMSGOBJ_MOVE, EXMSGOBJ_SIZE, EXMSGOBJ_SDUMP};
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	void* msgp = ((ZmqSocketClientData*)cd)->socket;
	switch((enum ExObjMessageMethods)index) {
	case EXMSGOBJ_CLOSE:
	{
	    if (objc != 2) {
		Tcl_WrongNumArgs(ip, 2, objv, "");
		return TCL_ERROR;
	    }
	    int rt = zmq_msg_close(msgp);
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
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "dest_message");
		return TCL_ERROR;
	    }
	    void* dmsgp = known_message(ip, objv[2]);
	    if (!dmsgp) {
	        return TCL_ERROR;
	    }
	    int rt = zmq_msg_copy(dmsgp, msgp);
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
        case EXMSGOBJ_MOVE:
        {
	    if (objc != 3) {
		Tcl_WrongNumArgs(ip, 2, objv, "dest_message");
		return TCL_ERROR;
	    }
	    void* dmsgp = known_message(ip, objv[2]);
	    if (!dmsgp) {
	        return TCL_ERROR;
	    }
	    int rt = zmq_msg_move(dmsgp, msgp);
	    last_zmq_errno = zmq_errno();
	    if (rt != 0) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
		return TCL_ERROR;
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
	    zmq_s_dump(zmq_msg_data(msgp), zmq_msg_size(msgp));
	    break;
	}
	}
 	return TCL_OK;
    }

    static Tcl_Obj* unique_namespace_name(Tcl_Interp* ip, Tcl_Obj* obj) {
	const char* name = Tcl_GetStringFromObj(obj, 0);
	Tcl_Obj* fqn = 0;
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
	Tcl_CmdInfo ci;
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
	return fqn;
    }

    static void zmqEventSetup(ClientData cd, int flags)
    {
	ZmqClientData* zmqClientData = (ZmqClientData*)cd;
	Tcl_HashSearch hsr;
	Tcl_HashEntry* her = Tcl_FirstHashEntry(zmqClientData->readableCommands, &hsr);
	int n = 0;
	while(her) {
	    int events = 0;
	    int len = sizeof(int);
	    int rt = zmq_getsockopt(Tcl_GetHashKey(zmqClientData->readableCommands, her), ZMQ_EVENTS, &events, &len);
	    if (!rt && events & ZMQ_POLLIN) {
		Tcl_Time blockTime = { 0, 0 };
		Tcl_SetMaxBlockTime(&blockTime);
		return;
	    }
	    her = Tcl_NextHashEntry(&hsr);
	}
	Tcl_HashSearch hsw;
	Tcl_HashEntry* hew = Tcl_FirstHashEntry(zmqClientData->writableCommands, &hsw);
	while(hew) {
	    int events = 0;
	    int len = sizeof(int);
	    int rt = zmq_getsockopt(Tcl_GetHashKey(zmqClientData->writableCommands, hew), ZMQ_EVENTS, &events, &len);
	    if (!rt && events & ZMQ_POLLOUT) {
		Tcl_Time blockTime = { 0, 0 };
		Tcl_SetMaxBlockTime(&blockTime);
		return;
	    }
	    hew = Tcl_NextHashEntry(&hsw);
	}
	Tcl_Time blockTime = { 0, zmqClientData->block_time };
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
	while(her) {
	    int events = 0;
	    int len = sizeof(int);
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
	Tcl_HashSearch hsw;
	Tcl_HashEntry* hew = Tcl_FirstHashEntry(zmqClientData->writableCommands, &hsw);
	while(hew) {
	    int events = 0;
	    int len = sizeof(int);
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
    }
}

critcl::ccommand ::tclzmq::version {cd ip objc objv} -clientdata zmqClientData {
    int major=0, minor=0, patch=0;
    zmq_version(&major, &minor, &patch);
    char version[128];
    snprintf(version, 128, "%d.%d.%d", major, minor, patch);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(version, -1));
    return TCL_OK;
}

critcl::cproc ::tclzmq::errno {} int {
    return last_zmq_errno;
}

critcl::ccommand ::tclzmq::strerror {cd ip objc objv} -clientdata zmqClientData {
    if (objc != 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "errnum");
	return TCL_ERROR;
    }
    int errnum = 0;
    if (Tcl_GetIntFromObj(ip, objv[1], &errnum) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong errnum argument, expected integer", -1));
	return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(errnum), -1));
    return TCL_OK;
}

critcl::ccommand ::tclzmq::max_block_time {cd ip objc objv} -clientdata zmqClientData {
    if (objc != 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "block_time");
	return TCL_ERROR;
    }
    int block_time = 0;
    if (Tcl_GetIntFromObj(ip, objv[1], &block_time) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong block_time argument, expected integer", -1));
	return TCL_ERROR;
    }
    ZmqClientData* zmqClientData = (ZmqClientData*)cd;
    zmqClientData->block_time = block_time;
    return TCL_OK;
}

critcl::ccommand ::tclzmq::context {cd ip objc objv} -clientdata zmqClientData {
    if (objc != 3) {
	Tcl_WrongNumArgs(ip, 1, objv, "name io_threads");
	return TCL_ERROR;
    }
    int io_threads = 0;
    if (Tcl_GetIntFromObj(ip, objv[2], &io_threads) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong io_threads argument, expected integer", -1));
	return TCL_ERROR;
    }
    Tcl_Obj* fqn = unique_namespace_name(ip, objv[1]);
    if (!fqn)
        return TCL_ERROR;
    void* zmqp = zmq_init(io_threads);
    last_zmq_errno = zmq_errno();
    if (zmqp == NULL) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    ZmqContextClientData* ccd = (ZmqContextClientData*)ckalloc(sizeof(ZmqContextClientData));
    ccd->context = zmqp;
    ccd->zmqClientData = cd;
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_context_objcmd, (ClientData)ccd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    Tcl_CreateEventSource(zmqEventSetup, zmqEventCheck, cd);
    return TCL_OK;
}

critcl::ccommand ::tclzmq::socket {cd ip objc objv} -clientdata zmqClientData {
    if (objc != 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "name context type");
	return TCL_ERROR;
    }
    Tcl_Obj* fqn = unique_namespace_name(ip, objv[1]);
    if (!fqn)
        return TCL_ERROR;
    void* ctxp = known_context(ip, objv[2]);
    if (!ctxp) {
	Tcl_DecrRefCount(fqn);
        return TCL_ERROR;
    }
    int stype = 0;
    static const char* stypes[] = {"PAIR", "PUB", "SUB", "REQ", "REP", "DEALER", "ROUTER", "PULL", "PUSH", "XPUB", "XSUB", NULL};
    enum ExObjSocketMethods {ZST_PAIR, ZST_PUB, ZST_SUB, ZST_REQ, ZST_REP, ZST_DEALER, ZST_ROUTER, ZST_PULL, ZST_PUSH, ZST_XPUB, ZST_XSUB};
    int stindex = -1;
    if (Tcl_GetIndexFromObj(ip, objv[3], stypes, "type", 0, &stindex) != TCL_OK)
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
    void* sockp = zmq_socket(ctxp, stype);
    last_zmq_errno = zmq_errno();
    if (sockp == NULL) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    ZmqSocketClientData* scd = (ZmqSocketClientData*)ckalloc(sizeof(ZmqSocketClientData));
    scd->socket = sockp;
    scd->zmqClientData = cd;
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_socket_objcmd, (ClientData)scd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    return TCL_OK;
}

critcl::ccommand ::tclzmq::message {cd ip objc objv} -clientdata zmqClientData {
    if (objc < 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "name ?-size <size>? ?-data <data>?");
	return TCL_ERROR;
    }
    Tcl_Obj* fqn = unique_namespace_name(ip, objv[1]);
    if (!fqn)
        return TCL_ERROR;
    char* data = 0;
    int size = -1;
    if ((objc-2) % 2) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("invalid number of arguments", -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    int i;
    for(i = 2; i < objc; i+=2) {
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
    void* msgp = ckalloc(32);
    int rt = 0;
    if (data) {
	if (size < 0)
	    size = strlen(data);
	void* buffer = ckalloc(size);
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
    ZmqMessageClientData* mcd = (ZmqMessageClientData*)ckalloc(sizeof(ZmqMessageClientData));
    mcd->message = msgp;
    mcd->zmqClientData = cd;
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_message_objcmd, (ClientData)mcd, zmq_free_client_data);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    return TCL_OK;
}

critcl::ccommand ::tclzmq::poll {cd ip objc objv} -clientdata zmqClientData {
    if (objc != 3) {
	Tcl_WrongNumArgs(ip, 1, objv, "socket_list timeout");
	return TCL_ERROR;
    }
    int slobjc = 0;
    Tcl_Obj** slobjv = 0;
    if (Tcl_ListObjGetElements(ip, objv[1], &slobjc, &slobjv) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("sockets_list not specified as list", -1));
	return TCL_ERROR;
    }
    int i = 0;
    for(i = 0; i < slobjc; i++) {
	int flobjc = 0;
	Tcl_Obj** flobjv = 0;
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
	int events = 0;
	if (get_poll_flags(ip, flobjv[1], &events) != TCL_OK)
	    return TCL_ERROR;
    }
    int timeout = 0;
    if (Tcl_GetIntFromObj(ip, objv[2], &timeout) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong timeout argument, expected integer", -1));
	return TCL_ERROR;
    }
    zmq_pollitem_t* sockl = (zmq_pollitem_t*)ckalloc(sizeof(zmq_pollitem_t) * slobjc);
    for(i = 0; i < slobjc; i++) {
	int flobjc = 0;
	Tcl_Obj** flobjv = 0;
	Tcl_ListObjGetElements(ip, slobjv[i], &flobjc, &flobjv);
	int elobjc = 0;
	Tcl_Obj** elobjv = 0;
	Tcl_ListObjGetElements(ip, flobjv[1], &elobjc, &elobjv);
	int events = 0;
	if (get_poll_flags(ip, flobjv[1], &events) != TCL_OK)
	    return TCL_ERROR;
	sockl[i].socket = known_socket(ip, flobjv[0]);
	sockl[i].fd = 0;
	sockl[i].events = events;
	sockl[i].revents = 0;
    }
    int rt = zmq_poll(sockl, slobjc, timeout);
    last_zmq_errno = zmq_errno();
    if (rt < 0) {
	ckfree((void*)sockl);
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	return TCL_ERROR;
    }
    Tcl_Obj* result = Tcl_NewListObj(0, NULL);
    for(i = 0; i < slobjc; i++) {
	if (sockl[i].revents) {
	    int flobjc = 0;
	    Tcl_Obj** flobjv = 0;
	    Tcl_ListObjGetElements(ip, slobjv[i], &flobjc, &flobjv);
	    Tcl_Obj* sresult = Tcl_NewListObj(0, NULL);
	    Tcl_ListObjAppendElement(ip, sresult, flobjv[0]);
	    Tcl_ListObjAppendElement(ip, sresult, set_poll_flags(ip, sockl[i].revents));
	    Tcl_ListObjAppendElement(ip, result, sresult);
	}
    }
    Tcl_SetObjResult(ip, result);
    ckfree((void*)sockl);
    return TCL_OK;
}

critcl::ccommand ::tclzmq::device {cd ip objc objv} -clientdata zmqClientData {
    if (objc != 4) {
	Tcl_WrongNumArgs(ip, 1, objv, "device_type insocket outsocket");
	return TCL_ERROR;
    }
    static const char* devices[] = {"STREAMER", "FORWARDER", "QUEUE", NULL};
    enum ExObjDevices {ZDEV_STREAMER, ZDEV_FORWARDER, ZDEV_QUEUE};
    int dindex = -1;
    int dev = 0;
    if (Tcl_GetIndexFromObj(ip, objv[1], devices, "device", 0, &dindex) != TCL_OK) {
	return TCL_ERROR;
    }
    switch((enum ExObjDevices)dindex) {
    case ZDEV_STREAMER: dev = ZMQ_STREAMER; break;
    case ZDEV_FORWARDER: dev = ZMQ_FORWARDER; break;
    case ZDEV_QUEUE: dev = ZMQ_QUEUE; break;
    }
    void* insocket = known_socket(ip, objv[2]);
    if (!insocket)
	return TCL_ERROR;
    void* outsocket = known_socket(ip, objv[3]);
    if (!outsocket)
	return TCL_ERROR;
    zmq_device(dev, insocket, outsocket);
    last_zmq_errno = zmq_errno();
    return TCL_OK;
}

critcl::cinit {
    ZmqClientData* zmqClientData = (ZmqClientData*)ckalloc(sizeof(ZmqClientData));
    zmqClientData->ip = ip;
    zmqClientData->readableCommands = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientData->readableCommands, TCL_ONE_WORD_KEYS);
    zmqClientData->writableCommands = (struct Tcl_HashTable*)ckalloc(sizeof(struct Tcl_HashTable));
    Tcl_InitHashTable(zmqClientData->writableCommands, TCL_ONE_WORD_KEYS);
    zmqClientData->block_time = 1000;
} {}



package provide tclzmq 0.1
