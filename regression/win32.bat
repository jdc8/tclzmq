set TCLSH=c:\Tcl32\bin\tclsh.exe

git clone https://github.com/zeromq/zeromq2-x.git libzmq22
git clone git://github.com/jdc8/tclzmq.git
cd tclzmq
git checkout --track origin/2.2
cd zmq_nMakefiles
nmake ZMQDIR=..\..\libzmq22 all32
cd ..
%TCLSH% build.tcl install -zmq zmq_nMakefiles -static
cd test
%TCLSH% all.tcl
cd ..
cd ..
rem rmdir /s /q libzmq22
rem rmdir /s /q tclzmq
