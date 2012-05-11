set TCLSH=c:\Tcl\bin\tclsh.exe

git clone https://github.com/zeromq/zeromq2-x.git libzmq22
git clone git://github.com/jdc8/tclzmq.git
cd tclzmq
git checkout --track origin/2.2
cd zmq_nMakefiles
nmake ZMQDIR=..\..\libzmq22 all64
cd ..
%TCLSH% build.tcl install -zmq zmq_nMakefiles -static
cd test
%TCLSH% all.tcl
cd ..
cd ..
rmdir /s /q libzmq22
rmdir /s /q tclzmq
