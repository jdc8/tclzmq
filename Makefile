TCLSH = tclsh
CRITCL = critcl

package:
	$(CRITCL) -pkg tclzmq.tcl

install:
	$(TCLSH) make_build.tcl $(CRITCL)
	sh ./build.sh

test: package
	cd test ; $(TCLSH) all.tcl

clean:
	- rm build.sh
	- rm -Rf include
	- rm -Rf lib
