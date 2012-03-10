all:
	tclsh make_build.tcl
	sh ./build.sh

clean:
	- rm build.sh
	- rm -Rf include
	- rm -Rf lib
