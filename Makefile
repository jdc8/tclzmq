TCLSH = tclsh
CRITCL = critcl
ZMQDIR = ../libzmq

package:
	$(TCLSH) make_build.tcl package $(CRITCL) $(ZMQDIR)
	sh ./build.sh

install:
	$(TCLSH) make_build.tcl install $(CRITCL) $(ZMQDIR)
	sh ./build.sh

test: install
	cd test ; $(TCLSH) all.tcl -verbose t

clean:
	- rm build.sh
	- rm -Rf include
	- rm -Rf lib
