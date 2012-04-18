#!/bin/csh

if ($#argv == 1) then
    set TCLSH = `which tclsh`
    set CRITCL = `which critcl`
else if ($#argv == 3) then
    set TCLSH = $2
    set CRITCL = $3
else
    echo "Usage: regression.csh <version> ?<tclsh_path> <critcl_path>?"
    exit 1
endif

set V = $1
set failed = 0
#set TCLSH = /target/staff/decoster/tmp/tcl_tooldb/install/bin/tclsh8.6
#set CRITCL = /target/staff/decoster/tmp/tcl_tooldb/install/bin/critcl

if ($V == "2.1") then
    cget http://download.zeromq.org/zeromq-2.1.11.tar.gz -O zeromq-2.1.11.tar.gz
    tar -xzf zeromq-2.1.11.tar.gz
    mv zeromq-2.1.11 libzmq$V
    rm -f zeromq-2.1.11.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
else if ($V == "2.2") then
    git clone git://github.com/zeromq/zeromq2-x.git libzmq$V
    if ($status) then
        set failed = 1
	goto done
    endif
else if ($V == "3.1") then
    git clone git://github.com/zeromq/libzmq.git libzmq$V
    if ($status) then
        set failed = 1
	goto done
    endif
else
    echo "Unknown version '$V'"
    exit 1
endif

cd libzmq$V

./autogen.sh
if ($status) then
    set failed = 1
    goto cddone
endif

./configure --prefix=/tmp/libzmq$V
if ($status) then
    set failed = 1
    goto cddone
endif

make
if ($status) then
    set failed = 1
    goto cddone
endif

make install
if ($status) then
    set failed = 1
    goto cddone
endif

cd ..



git clone git://github.com/jdc8/tclzmq.git tclzmq$V
if ($status) then
    set failed = 1
    goto done
endif

cd tclzmq$V

if ($V != "3.1") then
    git checkout $V
    if ($status) then
	set failed = 1
        goto cddone
    endif
endif

$TCLSH build.tcl -critcl $CRITCL -zeromq /tmp/libzmq$V -static -test
if ($status) then
    set failed = 1
    goto cddone
endif

cddone:
cd ..

done:
rm -Rf libzmq$V /tmp/libzmq$V tclzmq$V /tmp/libzmq$V

exit $failed
