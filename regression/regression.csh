#!/bin/csh -x

if ($#argv == 1) then
    set TCLSH = `which tclsh`
else if ($#argv == 2) then
    set TCLSH = $2
else
    echo "Usage: regression.csh <version> ?<tclsh_path>?"
    exit 1
endif

set V = $1
set failed = 0

if ($V == "2.1") then
    $TCLSH cget.tcl http://download.zeromq.org/zeromq-2.1.11.tar.gz zeromq-2.1.11.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
    tar -xzf zeromq-2.1.11.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
    mv zeromq-2.1.11 libzmq$V
    if ($status) then
        set failed = 1
	goto done
    endif
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
else if ($V == "3.2") then
    $TCLSH cget.tcl http://download.zeromq.org/zeromq-3.2.3.tar.gz zeromq-3.2.3.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
    tar -xzf zeromq-3.2.3.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
    mv zeromq-3.2.3 libzmq$V
    if ($status) then
        set failed = 1
	goto done
    endif
    rm -f zeromq-3.2.3.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
else if ($V == "3.2.4") then
    $TCLSH cget.tcl http://download.zeromq.org/zeromq-3.2.4.tar.gz zeromq-3.2.4.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
    tar -xzf zeromq-3.2.4.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
    mv zeromq-3.2.4 libzmq$V
    if ($status) then
        set failed = 1
	goto done
    endif
    rm -f zeromq-3.2.4.tar.gz
    if ($status) then
        set failed = 1
	goto done
    endif
else if ($V == "4.0") then
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

setenv CXXFLAGS -fPIC
setenv CFLAGS -fPIC
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

if ($V != "4.0") then
    git checkout --track origin/$V
    if ($status) then
	set failed = 1
        goto cddone
    endif
endif

$TCLSH build.tcl install lib -zmq /tmp/libzmq$V -static
if ($status) then
    set failed = 1
    goto cddone
endif

cd test
$TCLSH all.tcl >& test.log
if ($status) then
    set failed = 1
    goto cdcddone
endif

cat test.log

$TCLSH ../regression/look_for_failed_tests.tcl test.log
if ($status) then
    set failed = 1
    goto cdcddone
endif

cdcddone:
cd ..

cddone:
cd ..

done:
rm -Rf libzmq$V /tmp/libzmq$V tclzmq$V /tmp/libzmq$V

exit $failed
