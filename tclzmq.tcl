package require critcl 3

namespace eval tclzmq {}

critcl::cheaders ../libzmq/include/zmq.h -I../libzmq/include
critcl::clibraries ../libzmq/lib/libzmq.a -lstdc++ -lpthread -lm -lrt -luuid
critcl::cflags -I ../libzmq/include
critcl::debug all

# Socket options.
critcl::cdefines ZMQ_HWM ::tclzmq
critcl::cdefines ZMQ_SWAP ::tclzmq
critcl::cdefines ZMQ_AFFINITY ::tclzmq
critcl::cdefines ZMQ_IDENTITY ::tclzmq
critcl::cdefines ZMQ_SUBSCRIBE ::tclzmq
critcl::cdefines ZMQ_UNSUBSCRIBE ::tclzmq
critcl::cdefines ZMQ_RATE ::tclzmq
critcl::cdefines ZMQ_RECOVERY_IVL ::tclzmq
critcl::cdefines ZMQ_MCAST_LOOP ::tclzmq
critcl::cdefines ZMQ_SNDBUF ::tclzmq
critcl::cdefines ZMQ_RCVBUF ::tclzmq
critcl::cdefines ZMQ_RCVMORE ::tclzmq
critcl::cdefines ZMQ_FD ::tclzmq
critcl::cdefines ZMQ_EVENTS ::tclzmq
critcl::cdefines ZMQ_TYPE ::tclzmq
critcl::cdefines ZMQ_LINGER ::tclzmq
critcl::cdefines ZMQ_RECONNECT_IVL ::tclzmq
critcl::cdefines ZMQ_BACKLOG ::tclzmq
critcl::cdefines ZMQ_RECOVERY_IVL_MSEC ::tclzmq
critcl::cdefines ZMQ_RECONNECT_IVL_MAX ::tclzmq

# Send/recv options.
critcl::cdefines ZMQ_NOBLOCK ::tclzmq
critcl::cdefines ZMQ_SNDMORE ::tclzmq

critcl::cdefines ZMQ_POLLIN ::tclzmq
critcl::cdefines ZMQ_POLLOUT ::tclzmq
critcl::cdefines ZMQ_POLLERR ::tclzmq

critcl::cdefines ZMQ_STREAMER ::tclzmq
critcl::cdefines ZMQ_FORWARDER ::tclzmq
critcl::cdefines ZMQ_QUEUE ::tclzmq

critcl::ccode {

    #include "errno.h"
    #include "zmq.h"

    static int last_zmq_errno = 0;

    static zmq_ckfree(void* p, void* h) { ckfree(p); }

    static void* known_command(Tcl_Interp* ip, Tcl_Obj* obj, const char* what) {
	Tcl_CmdInfo ci;
	if (!Tcl_GetCommandInfo(ip, Tcl_GetStringFromObj(obj, 0), &ci)) {
	    Tcl_Obj* err;
	    err = Tcl_NewObj();
	    Tcl_AppendToObj(err, what, -1);
	    Tcl_AppendToObj(err, " \"", -1);
	    Tcl_AppendObjToObj(err, obj);
	    Tcl_AppendToObj(err, "\" does not exists", -1);
	    Tcl_DecrRefCount(obj);
	    Tcl_SetObjResult(ip, err);
	    return 0;
	}
	return ci.objClientData;
    }

    static void* known_context(Tcl_Interp* ip, Tcl_Obj* obj) { return known_command(ip, obj, "context"); }
    static void* known_socket(Tcl_Interp* ip, Tcl_Obj* obj) { return known_command(ip, obj, "socket"); }
    static void* known_message(Tcl_Interp* ip, Tcl_Obj* obj) { return known_command(ip, obj, "message"); }

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
	void* zmqp = (void*)cd;
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

    int zmq_socket_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"bind", "close", "connect", "getsocktopt", "recv", "send", "setsocketopt", NULL};
	enum ExObjSocketMethods {EXSOCKOBJ_BIND, EXSOCKOBJ_CLOSE, EXSOCKOBJ_CONNECT, EXSOCKOBJ_GETSOCKETOPT,
	    EXSOCKOBJ_RECV, EXSOCKOBJ_SEND, EXSOCKOBJ_SETSOCKETOPT};
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	void* sockp = (void*)cd;
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
	    if (objc < 4 || objc > 5) {
		Tcl_WrongNumArgs(ip, 2, objv, "name value ?size?");
		return TCL_ERROR;
	    }
	    int name = 0;
	    if (Tcl_GetIntFromObj(ip, objv[2], &name) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong name argument, expected integer", -1));
		return TCL_ERROR;
	    }
	    switch(name) {
            case ZMQ_HWM:
	    {
		break;
	    }
            case ZMQ_SWAP:
	    {
		break;
	    }
            case ZMQ_AFFINITY:
	    {
		break;
	    }
            case ZMQ_IDENTITY:
	    {
		break;
	    }
            case ZMQ_SUBSCRIBE:
	    {
		break;
	    }
            case ZMQ_UNSUBSCRIBE:
	    {
		break;
	    }
            case ZMQ_RATE:
	    {
		break;
	    }
            case ZMQ_RECOVERY_IVL:
	    {
		break;
	    }
            case ZMQ_MCAST_LOOP:
	    {
		break;
	    }
            case ZMQ_SNDBUF:
	    {
		break;
	    }
            case ZMQ_RCVBUF:
	    {
		break;
	    }
            case ZMQ_RCVMORE:
	    {
		break;
	    }
            case ZMQ_FD:
	    {
		break;
	    }
            case ZMQ_EVENTS:
	    {
		break;
	    }
            case ZMQ_TYPE:
	    {
		break;
	    }
            case ZMQ_LINGER:
	    {
		break;
	    }
            case ZMQ_RECONNECT_IVL:
	    {
		break;
	    }
            case ZMQ_BACKLOG:
	    {
		break;
	    }
            case ZMQ_RECOVERY_IVL_MSEC:
	    {
		break;
	    }
            case ZMQ_RECONNECT_IVL_MAX:
	    {
		break;
	    }
   	    default:
	    {
	        Tcl_SetObjResult(ip, Tcl_NewStringObj("Unknown name", -1));
	        return TCL_ERROR;
	    }
	    }
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
	    if (rt != 0) {
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
	    int name = 0;
	    if (Tcl_GetIntFromObj(ip, objv[2], &name) != TCL_OK) {
		Tcl_SetObjResult(ip, Tcl_NewStringObj("Wrong name argument, expected integer", -1));
		return TCL_ERROR;
	    }
	    switch(name) {
            case ZMQ_HWM:
	    {
		break;
	    }
            case ZMQ_SWAP:
	    {
		break;
	    }
            case ZMQ_AFFINITY:
	    {
		break;
	    }
            case ZMQ_IDENTITY:
	    {
		break;
	    }
            case ZMQ_SUBSCRIBE:
	    {
		break;
	    }
            case ZMQ_UNSUBSCRIBE:
	    {
		break;
	    }
            case ZMQ_RATE:
	    {
		break;
	    }
            case ZMQ_RECOVERY_IVL:
	    {
		break;
	    }
            case ZMQ_MCAST_LOOP:
	    {
		break;
	    }
            case ZMQ_SNDBUF:
	    {
		break;
	    }
            case ZMQ_RCVBUF:
	    {
		break;
	    }
            case ZMQ_RCVMORE:
	    {
		break;
	    }
            case ZMQ_FD:
	    {
		break;
	    }
            case ZMQ_EVENTS:
	    {
		break;
	    }
            case ZMQ_TYPE:
	    {
		break;
	    }
            case ZMQ_LINGER:
	    {
		break;
	    }
            case ZMQ_RECONNECT_IVL:
	    {
		break;
	    }
            case ZMQ_BACKLOG:
	    {
		break;
	    }
            case ZMQ_RECOVERY_IVL_MSEC:
	    {
		break;
	    }
            case ZMQ_RECONNECT_IVL_MAX:
	    {
		break;
	    }
   	    default:
	    {
	        Tcl_SetObjResult(ip, Tcl_NewStringObj("Unknown name", -1));
	        return TCL_ERROR;
	    }
	    }
	    break;
	}
        }
 	return TCL_OK;
    }

    int zmq_message_objcmd(ClientData cd, Tcl_Interp* ip, int objc, Tcl_Obj* const objv[]) {
	static const char* methods[] = {"close", "copy", "data", "move", "size", NULL};
	enum ExObjMessageMethods {EXMSGOBJ_CLOSE, EXMSGOBJ_COPY, EXMSGOBJ_DATA, EXMSGOBJ_MOVE, EXMSGOBJ_SIZE};
	if (objc < 2) {
	    Tcl_WrongNumArgs(ip, 1, objv, "method ?argument ...?");
	    return TCL_ERROR;
	}
	int index = -1;
	if (Tcl_GetIndexFromObj(ip, objv[1], methods, "method", 0, &index) != TCL_OK)
            return TCL_ERROR;
	void* msgp = (void*)cd;
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
		ckfree(msgp);
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
}

critcl::ccommand tclzmq::version {cd ip objc objv} {
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

critcl::ccommand ::tclzmq::strerror {cd ip objc objv} {
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

critcl::ccommand ::tclzmq::context {cd ip objc objv} {
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
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_context_objcmd, (ClientData)zmqp, NULL);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    return TCL_OK;
}

critcl::ccommand ::tclzmq::socket {cd ip objc objv} {
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
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_socket_objcmd, (ClientData)sockp, NULL);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    return TCL_OK;
}

critcl::ccommand ::tclzmq::message {cd ip objc objv} {
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
	    data = Tcl_GetStringFromObj(v, 0);
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
	Tcl_SetObjResult(ip, Tcl_NewStringObj(zmq_strerror(last_zmq_errno), -1));
	Tcl_DecrRefCount(fqn);
	return TCL_ERROR;
    }
    Tcl_CreateObjCommand(ip, Tcl_GetStringFromObj(fqn, 0), zmq_message_objcmd, (ClientData)msgp, NULL);
    Tcl_SetObjResult(ip, fqn);
    Tcl_DecrRefCount(fqn);
    return TCL_OK;
}

package provide tclzmq 0.1
