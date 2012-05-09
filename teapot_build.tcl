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
    ConfigureTclZmq $d
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
	if {$config ne {}} {
	    lappend rcargs -target $config
	}
	lappend rcargs -cache [pwd]/BUILD.$p
	if {[string length $zmq]} {
	    lappend rcargs -libdir [file join $zmq lib] -includedir [file join $zmq include]
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
	if {$config ne {}} {
	    lappend rcargs -target $config
	}
	lappend rcargs -keep -debug all -cache [pwd]/BUILD.$p
	if {[string length $zmq]} {
	    lappend rcargs -libdir [file join $zmq lib] -includedir [file join $zmq include]
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
    global INSTALLPATH
    package require Tk
#    package require widget::scrolledwindow

    wm protocol . WM_DELETE_WINDOW ::_exit

    label  .l -text {Install Path: }
    entry  .e -textvariable ::INSTALLPATH
    button .i -command Install -text Install
    button .d -command Install -text Debug

#    widget::scrolledwindow .st -borderwidth 1 -relief sunken
    text   .t
#    .st setwidget .t

    .t tag configure stdout -font {Helvetica 8}
    .t tag configure stderr -background red    -font {Helvetica 12}
    .t tag configure ok     -background green  -font {Helvetica 8}
    .t tag configure warn   -background yellow -font {Helvetica 12}

    grid .l  -row 0 -column 0 -sticky new
    grid .e  -row 0 -column 1 -sticky new
    grid .i  -row 0 -column 2 -sticky new
    grid .t -row 1 -column 0 -sticky swen -columnspan 2

    grid rowconfigure . 0 -weight 0
    grid rowconfigure . 1 -weight 1

    grid columnconfigure . 0 -weight 0
    grid columnconfigure . 1 -weight 1
    grid columnconfigure . 2 -weight 0

    set INSTALLPATH [info library]

    # Redirect all output into our log window, and disable uncontrolled exit.
    rename ::puts ::_puts
    rename ::log ::puts
    rename ::exit   ::_exit
    rename ::myexit ::exit

    # And start to interact with the user.
    vwait forever
    return
}
proc Install {} {
    global INSTALLPATH NOTE
    .i configure -state disabled
    .d configure -state disabled

    set NOTE {ok DONE}
    set fail [catch {
	_install $INSTALLPATH

	puts ""
	tag  [lindex $NOTE 0]
	puts [lindex $NOTE 1]
    } e o]

    .i configure -state normal
    .d configure -state normal
    .i configure -command ::_exit -text Exit -bg green

    if {$fail} {
	# rethrow
	return {*}$o $e
    }
    return
}
proc Debug {} {
    global INSTALLPATH
    .i configure -state disabled
    .d configure -state disabled

    set fail [catch {
	_debug $INSTALLPATH

	puts ""
	tag ok
	puts DONE
    } e o]

    .i configure -state normal
    .d configure -state normal
    .d configure -command ::_exit -text Exit -bg green

    if {$fail} {
	# rethrow
	return {*}$o $e
    }
    return
}
proc Hwrap4tea {} { return "?destination?\n\tGenerate source packages with TEA-based build system wrapped around critcl.\n\tdestination = path of source package directory, default is sub-directory 'tea' of the CWD." }
proc _wrap4tea {{dst {}}} {
    global packages
    if {[llength [info level 0]] < 2} {
	set dst [file join [pwd] tea]
    }

    # Generate TEA directory hierarchies

    foreach p $packages {
	set src     [file dirname $::me]/$p.tcl
	set version [version $src]

	file delete -force [pwd]/BUILD.$p
	RunCritcl   -cache [pwd]/BUILD.$p -libdir $dst -tea $src
	file delete -force $dst/$p$version
	file rename        $dst/$p $dst/$p$version

	puts "Installed package:     $dst/$p$version"
	puts ""
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

proc ConfigureTclZmq {d} {
    dict with d {}
    puts "Configured options:"
    puts "    static = $static"
    puts "    zmq    = $zmq"
    puts "    ldir   = $ldir"
    puts "    idir   = $idir"
    puts "    config = $config"
    set pkgdir [file dirname [file normalize [info script]]]
    set fd [open [file join $pkgdir zmq_config.tcl] "w"]

    if {$zmq ne {}} {
	set lib [file join $zmq lib]
	set inc [file join $zmq include]
    } else {
	set lib $ldir
	set inc $idir
    }
    if {$::tcl_platform(platform) eq "windows"} {
        puts -nonewline $fd "critcl::clibraries "
	puts -nonewline $fd "\"[file join $lib libzmq.lib]\" "
	puts "-luuid -lws2_32 -lcomctl32 -lrpcrt4"
	if {!$static} {
	} else {
	    puts -nonewline $fd "critcl::cflags /D DLL_EXPORT"
	    puts $fd ""
	}
    } else {
	if {!$static} {
	    puts -nonewline $fd "critcl::clibraries "
	    puts -nonewline $fd "\"-L$lib\" "
	    puts $fd "-lzmq -luuid"
	} else {
	    puts -nonewline $fd "critcl::clibraries "
	    puts $fd "$lib/libzmq.a -lstdc++ -lpthread -lm -lrt -luuid"
	}
    }

#    puts $fd "critcl::debug all"
#    puts $fd "critcl::config keepsrc 1"
    close $fd
}

proc RunCritcl {args} {
    #puts [info level 0]
    if {![catch {
	package require critcl::app 3.1
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
