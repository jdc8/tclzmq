#!/bin/csh

set V = $1
set failed = 0

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

git checkout $V
if ($status) then
    set failed = 1
    goto cddone
endif

tclsh build.tcl -critcl `which critcl` -zeromq /tmp/libzmq$V -static -test
if ($status) then
    set failed = 1
    goto cddone
endif

cddone:
cd ..

done:
rm -Rf libzmq$V /tmp/libzmq$V tclzmq$V /tmp/libzmq$V

exit $failed
