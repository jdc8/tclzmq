set TCLSH=c:\Tcl32\bin\tclsh.exe

git clone git://github.com/zeromq/libzmq.git libzmq31
git clone git://github.com/jdc8/tclzmq.git
cd tclzmq
cd zmq_nMakefiles
nmake ZMQDIR=..\..\libzmq31 all32
cd ..
%TCLSH% build.tcl install -zmq zmq_nMakefiles -static
cd test
%TCLSH% all.tcl
cd ..
cd ..
rem rmdir /s /q libzmq31
rem rmdir /s /q tclzmq
