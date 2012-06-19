#!/bin/sh
# -*- tcl -*- \
exec tclsh "$0" ${1+"$@"}
package require Tcl 8.5
set me [file normalize [info script]]
set packages {
    zmq
}
set tclpackages {
}
proc main {} {
    global argv tcl_platform tag
    set tag {}
    if {![llength $argv]} {
	if {$tcl_platform(platform) eq "windows"} {
	    set argv gui
	} else {
	    set argv help
	}
    }
    if {[catch {
	eval _$argv
    }]} usage
    exit 0
}
proc usage {{status 1}} {
    global errorInfo
    if {[info exists errorInfo] && ($errorInfo ne {}) &&
	![string match {invalid command name "_*"*} $errorInfo]
    } {
	puts stderr $::errorInfo
	exit
    }

    global argv0
    set prefix "Usage: "
    foreach c [lsort -dict [info commands _*]] {
	set c [string range $c 1 end]
	if {[catch {
	    H${c}
	} res]} {
	    puts stderr "$prefix$argv0 $c args...\n"
	} else {
	    puts stderr "$prefix$argv0 $c $res\n"
	}
	set prefix "       "
    }
    exit $status
}
proc tag {t} {
    global tag
    set tag $t
    return
}
proc myexit {} {
    tag ok
    puts DONE
    return
}
proc log {args} {
    global tag
    set newline 1
    if {[lindex $args 0] eq "-nonewline"} {
	set newline 0
	set args [lrange $args 1 end]
    }
    if {[llength $args] == 2} {
	lassign $args chan text
	if {$chan ni {stdout stderr}} {
	    ::_puts {*}[lrange [info level 0] 1 end]
	    return
	}
    } else {
	set text [lindex $args 0]
	set chan stdout
    }
    # chan <=> tag, if not overriden
    if {[string match {Files left*} $text]} {
	set tag warn
	set text \n$text
    }
    if {$tag eq {}} { set tag $chan }
    #::_puts $tag/$text

    .t insert end-1c $text $tag
    set tag {}
    if {$newline} { 
	.t insert end-1c \n
    }

    update
    return
}
proc +x {path} {
    catch { file attributes $path -permissions u+x }
    return
}
proc grep {file pattern} {
    set lines [split [read [set chan [open $file r]]] \n]
    close $chan
    return [lsearch -all -inline -glob $lines $pattern]
}
proc version {file} {
    #puts GREP\t[join [grep $file {*package provide *}] \nGREP\t]
    set v [lindex [grep $file {*package provide *}] 0 3]
    puts "Version:  $v"
    return $v
}
proc Hhelp {} { return "\n\tPrint this help" }
proc _help {} {
    usage 0
    return
}
proc Hrecipes {} { return "\n\tList all brew commands, without details." }
proc _recipes {} {
    set r {}
    foreach c [info commands _*] {
	lappend r [string range $c 1 end]
    }
    puts [lsort -dict $r]
    return
}
proc Hdrop {} { return "?destination?\n\tUninstall all packages.\n\tdestination = path of package directory, default \[info library\]." }
proc _drop {{ldir {}}} {
    global packages tclpackages
    if {[llength [info level 0]] < 2} {
	set ldir [info library]
	set idir [file dirname [file dirname $ldir]]/include
    } else {
	set idir [file dirname $ldir]/include
    }

    foreach p $packages {
	set src     [file dirname $::me]/$p.tcl
	set version [version $src]

	file delete -force $ldir/$p$version
	puts -nonewline "Removed package:     "
	tag ok
	puts $ldir/$p$version
    }

    foreach {p file} $tclpackages {
	set src     [file dirname $::me]/$file
	set version [version $src]
	set pdir    [string map {:: _} $p]

	file delete -force $ldir/$pdir$version
	puts -nonewline "Removed package:     "
	tag ok
	puts $ldir/$pdir$version
    }
    return
}
# proc Hdoc {} { return "\n\t(Re)Generate the embedded documentation." }
# proc _doc {} {
#     cd [file dirname $::me]/doc

#     puts "Removing old documentation..."
#     file delete -force ../embedded/man
#     file delete -force ../embedded/www

#     puts "Generating man pages..."
#     exec 2>@ stderr >@ stdout dtplite        -o ../embedded/man -ext n nroff .
#     puts "Generating 1st html..."
#     exec 2>@ stderr >@ stdout dtplite -merge -o ../embedded/www html .
#     puts "Generating 2nd html, resolving cross-references..."
#     exec 2>@ stderr >@ stdout dtplite -merge -o ../embedded/www html .

#     return
# }
proc configure {args} {
    set zmq ""
    set static 0
    set ldir [info library]
    set idir [file dirname [file dirname $ldir]]/include
    set config ""
    set n 0
    while {[llength $args]} {
	set args [lassign $args k]
	if {[string length $k]} {
	    switch -exact -- $k {
		-zmq {
		    set args [lassign $args zmq]
		}
		-static { set static 1 }
		-dynamic { set static 0 }
		default {
		    if {$n == 0} {
			set ldir $k
			set idir [file dirname $ldir]/include
		    } elseif {$n == 1} {
			set config $k
		    }
		    incr n
		}
	    }
	}
    }
    set d [dict create zmq $zmq static $static ldir $ldir idir $idir config $config]
    return $d
}
proc Hinstall {} { return "?destination? ?config? ?-zmq <path>? ?-static? ?-dynamic?\n\tInstall all packages.\n\tdestination = path of package directory, default \[info library\].\n\tconfig = Critcl target to be used\n\t-zmq <path> = path to ZeroMQ\n\t-static = link ZeroMQ statically, default is to link dynamically\n\t-dynamic = link ZeroMQ dynamically" }
proc _install {args} {
    global packages
    set d [eval configure $args]
    dict with d {}
    # Create directories, might not exist.
    file mkdir $idir
    file mkdir $ldir

    foreach p $packages {
	set src     [file dirname $::me]/$p.tcl
	set version [version $src]

	file delete -force [pwd]/BUILD.$p

	set rcargs [list]
	lappend rcargs -with-mode [expr {$static?"static":"dynamic"}]
	if {$config ne {}} {
	    lappend rcargs -target $config
	}
	lappend rcargs -cache [pwd]/BUILD.$p
	if {[string length $zmq]} {
	    lappend rcargs -L [file join $zmq lib] -I [file join $zmq include]
	} else {
	    lappend rcargs -L $ldir
	}
	lappend rcargs -libdir $ldir -includedir $idir -pkg $src
	RunCritcl {*}$rcargs

	if {![file exists $ldir/$p]} {
	    set ::NOTE {warn {DONE, with FAILURES}}
	    break
	}

	file delete -force $ldir/$p$version
	file rename        $ldir/$p $ldir/$p$version

	puts -nonewline "Installed package:     "
	tag ok
	puts $ldir/$p$version
	puts ""
    }

    Xinstalltclpackages $ldir
    return
}
proc Hdebug {} { return "?destination? ?config? ?-zmq <path>? ?-static? ?-dynamic?\n\tInstall debug builds of all packages.\n\tdestination = path of package directory, default \[info library\].\n\tconfig = Critcl target to be used\n\t-zmq <path> = path to ZeroMQ\n\t-static = link ZeroMQ statically, default is to link dynamically\n\t-dynamic = link ZeroMQ dynamically" }
proc _debug {args} {
    global packages
    set d [eval configure $args]
    dict with d {}

    # Create directories, might not exist.
    file mkdir $idir
    file mkdir $ldir

    foreach p $packages {
	set src     [file dirname $::me]/$p.tcl
	set version [version $src]

	file delete -force [pwd]/BUILD.$p

	set rcargs [list]
	lappend rcargs -with-mode [expr {$static?"static":"dynamic"}]
	if {$config ne {}} {
	    lappend rcargs -target $config
	}
	lappend rcargs -keep -debug all -cache [pwd]/BUILD.$p
	if {[string length $zmq]} {
	    lappend rcargs -L [file join $zmq lib] -I [file join $zmq include]
	} else {
	    lappend rcargs -L $ldir
	}
	lappend rcargs -libdir $ldir -includedir $idir -pkg $src
	RunCritcl {*}$rcargs

	file delete -force $ldir/$p$version
	file rename        $ldir/$p $ldir/$p$version

	puts -nonewline "Installed package:     "
	tag ok
	puts $ldir/$p$version
    }

    Xinstalltclpackages $ldir
    return
}
proc Hgui {} { return "\n\tInstall all packages.\n\tDone from a small GUI." }
proc _gui {} {
    global INSTALLPATH ZEROMQPATH BUILDSTATIC
    package require Tk
#    package require widget::scrolledwindow

    wm protocol . WM_DELETE_WINDOW ::_exit

    label  .li -text {Install Path: }
    entry  .ei -textvariable ::INSTALLPATH
    button .bi -command [list Browse ::INSTALLPATH] -text Browse
    label  .lz -text {ZeroMQ Path: }
    entry  .ez -textvariable ::ZEROMQPATH
    button .bz -command [list Browse ::ZEROMQPATH] -text Browse
    checkbutton .bs -text "Link ZeroMQ statically" -variable BUILDSTATIC -anchor w
    button .i -command Install -text Install
    button .d -command Debug -text Debug

#    widget::scrolledwindow .st -borderwidth 1 -relief sunken
    text   .t
#    .st setwidget .t

    .t tag configure stdout -font {Helvetica 8}
    .t tag configure stderr -background red    -font {Helvetica 12}
    .t tag configure ok     -background green  -font {Helvetica 8}
    .t tag configure warn   -background yellow -font {Helvetica 12}

    grid .li .ei .bi .i -sticky nesw
    grid .lz .ez .bz .d -sticky nesw
    grid .bs - - -stick ewns
    grid .t - - - -sticky nesw

    grid rowconfigure . 0 -weight 0
    grid rowconfigure . 3 -weight 1

    grid columnconfigure . 0 -weight 0
    grid columnconfigure . 1 -weight 1
    grid columnconfigure . 2 -weight 0
    grid columnconfigure . 3 -weight 0

    set INSTALLPATH [info library]
    set ZEROMQPATH ../libzmq

    # Redirect all output into our log window, and disable uncontrolled exit.
    rename ::puts ::_puts
    rename ::log ::puts
    rename ::exit   ::_exit
    rename ::myexit ::exit

    # And start to interact with the user.
    vwait forever
    return
}
proc Browse {varnm} {
    upvar $varnm var
    set d [tk_chooseDirectory -initialdir $var -title "Choose [string trim $varnm :]"]
    if {[string length $d]} {
	set var $d
    }
}
proc Install {} {
    global INSTALLPATH ZEROMQPATH NOTE
    foreach p {.ei .ez .bi .bz .bs .i .d} {
	$p configure -state disabled
    }

    set NOTE {ok DONE}
    set fail [catch [format {
	_install $INSTALLPATH -zmq $ZEROMQPATH %s

	puts ""
	tag  [lindex $NOTE 0]
	puts [lindex $NOTE 1]
    } [expr {$::BUILDSTATIC?"-static":"-dynamic"}]] e o]

    .i configure -state normal
    .i configure -command ::_exit -text Exit -bg green

    if {$fail} {
	# rethrow
	return {*}$o $e
    }
    return
}
proc Debug {} {
    global INSTALLPATH ZEROMQPATH
    foreach p {.ei .ez .bi .bz .bs .i .d} {
	$p configure -state disabled
    }

    set fail [catch [format {
	_debug $INSTALLPATH -zmq $ZEROMQPATH %s

	puts ""
	tag ok
	puts DONE
    } [expr {$::BUILDSTATIC?"-static":"-dynamic"}]] e o]

    .d configure -state normal
    .d configure -command ::_exit -text Exit -bg green

    if {$fail} {
	# rethrow
	return {*}$o $e
    }
    return
}

proc Xinstalltclpackages {ldir} {
    global tclpackages

    foreach {p file} $tclpackages {
	set src     [file dirname $::me]/$file
	set version [version $src]
	set pdir    [string map {:: _} $p]

	file mkdir $ldir/$pdir
	file copy $src $ldir/$pdir
	Xindex $p $version $file $ldir/$pdir

	file delete -force $ldir/$pdir$version
	file rename        $ldir/$pdir $ldir/$pdir$version

	puts -nonewline "Installed Tcl package:     "
	tag ok
	puts $ldir/$pdir$version
    }
    return
}

proc Xindex {name version pfile dstdir} {
    set    c [open $dstdir/pkgIndex.tcl w]
    puts  $c "package ifneeded $name $version \[list ::apply {{dir} {\n\tsource \$dir/$pfile\n}} \$dir\]"
    close $c
    return
}

proc RunCritcl {args} {
    #puts [info level 0]
    if {![catch {
	package require critcl::app 3.0
    }]} {
	#puts "......... [package ifneeded critcl::app [package present critcl::app]]"
	critcl::app::main $args
	return
    } else {
	foreach cmd {
	    critcl3 critcl3.kit critcl3.tcl critcl3.exe
	    critcl critcl.kit critcl.tcl critcl.exe
	} {
	    # Locate the candidate.
	    set cmd [auto_execok $cmd]
	    # Ignore applications which were not found.
	    if {![llength $cmd]} continue

	    # Proper native path needed, especially on windows. On
	    # windows this also works (best) with a starpack for
	    # critcl, instead of a starkit.

	    set cmd [file nativename [lindex [auto_execok $cmd] 0]]

	    # Ignore applications which are too old to support
	    # -v|--version, or are too old as per their returned
	    # version.
	    set v ?????
	    if {[catch {
		set v [eval [list exec $cmd --version]]
	    }] || ([package vcompare $v 3.0] < 0)} {
		puts "v=$v"
		continue
	    }

	    # Perform the requested action.
	    set cmd [list exec 2>@ stderr >@ stdout $cmd {*}$args]
	    #puts "......... $cmd"
	    eval $cmd
	    return
	}
    }

    puts "Unable to find a usable critcl 3 application (package). Stop."
    ::exit 1
}

main
