set TCLSH=c:\Tcl\bin\tclsh.exe
set ZIP="c:\Program Files\7-Zip\7z.exe"

%TCLSH% cget.tcl http://download.zeromq.org/zeromq-2.1.11.zip zeromq-2.1.11.zip
%ZIP% x -y zeromq-2.1.11.zip
git clone git://github.com/jdc8/tclzmq.git
cd tclzmq
git checkout --track origin/2.1
cd zmq_nMakefiles
nmake ZMQDIR=..\..\zeromq-2.1.11 all64
cd ..
%TCLSH% build.tcl install -zmq zmq_nMakefiles -static
cd test
%TCLSH% all.tcl
cd ..
cd ..
rmdir /s /q zeromq-2.1.11
rmdir /s /q tclzmq
