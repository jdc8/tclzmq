#! /usr/bin/env tclsh
#
# Build script for tclzmq.
#  - Lookup for critcl in current dir, parent dir on Tcl bin dir.
#    Force with -critcl option.
#  - Lookup for libzmq in parent dir.
#    Force with -libzmq option.
#  - Build and install tclzmq

package require Tcl 8.5

set pkgdir [file dirname [file normalize [info script]]]

if {$tcl_platform(platform) eq "windows"} {
    # Suffix of libraries generated by msvc or mingw
    set libsuffix {".lib" ".a" ".dll.a"}
    set searchpath {}
} else {
    set libsuffix {".so"}
    set searchpath {"/usr" "/usr/local" "/usr/local/libzmq" "/opt" "/opt/libzmq"}
}

proc main {argv} {
    global pkgdir tcl_platform

    parseopt opts $argv
    if {[info exists opts(-critcl)]} {
        set critcl [file normalize $opts(-critcl)]
    } else {
        set critcl [search_crictl]
    }
    if {[info exists opts(-zeromq)]} {
        set zeromq [file normalize $opts(-zeromq)]
    } else {
        set zeromq [search_zeromq]
    }
    set dynamic 1
    if {[info exists opts(-static)] && $opts(-static)} {
	set dynamic 0
    }
    puts "Using critcl $critcl"
    puts "Using zeromq $zeromq"
    set fd [open "$pkgdir/zmq_config.tcl" "w"]
    set lib [find_lib "$zeromq/lib/libzmq" "$zeromq/src/.libs/libzmq"]
    if {$tcl_platform(platform) eq "windows"} {
        puts $fd "critcl::clibraries \"$lib\" -luuid -lws2_32 -lcomctl32 -lrpcrt4"
	if {$dynamic} {
	    puts $fd "critcl::cflags \"-I$zeromq/include\""
	} else {
	    puts $fd "critcl::cflags /D DLL_EXPORT \"-I$zeromq/include\""
	}
    } else {
	set libdir  [file dirname $lib]
	set dlibfile [regsub "^lib" [file rootname [file tail $lib]] ""]
	set alibfile lib[regsub "^lib" [file rootname [file tail $lib]] ""].a
	if {$dynamic} {
	    puts $fd "critcl::clibraries \"-L$libdir\" -l$dlibfile -luuid"
	} else {
	    puts $fd "critcl::clibraries \"-L$libdir\" -l:$alibfile -lstdc++ -lpthread -lm -lrt -luuid"
	}
        puts $fd "critcl::cflags -I$zeromq/include -ansi -pedantic -Wall"
    }
    puts $fd "#critcl::debug all"
    puts $fd "#critcl::config keepsrc 1"
    close $fd
    cd $pkgdir
    set cmdline [list -pkg]
    if {[info exists opts(-install)]} {
        lappend cmdline -libdir $opts(-install)
    }
    lappend cmdline "zmq.tcl"
    puts "Running critcl [join $cmdline]"
    if {[catch {exec [info nameofexecutable] $critcl {*}$cmdline >@ stdout} msg]} {
	puts "Building failed"
	puts $msg
	exit 1
    } else {
	puts "Building OK"
    }
    if {[info exists opts(-test)] && $opts(-test)} {
	cd test
	set rt [catch {exec [info nameofexecutable] all.tcl >@ stdout} msg]
	cd ..
	if {$rt} {
	    puts "Test scripts failed"
	    exit 1
	}
    }
}

# Command line options parsing
proc parseopt {optsName argv} {
    upvar 1 $optsName opts
    set getarg {opt {
	upvar 1 argv argv
	if {[llength $argv] == 0} {
	    puts stderr "missing value for option $opt"
	    usage
	    exit 1
	}
	set argv [lassign $argv val]
	return $val
    }}
    while {[llength $argv] > 0} {
        set argv [lassign $argv opt]
        switch $opt {
            -critcl {
                set val [apply $getarg $opt]
                if {[file exists $val]} {
                    set opts($opt) $val
                } else {
                    puts stderr "Critcl startkit $val not found."
                    exit 1
                }
            }
            -zeromq {
                set val [apply $getarg $opt]
                if {[check_zeromq $val]} {
                    set opts($opt) $val
                } else {
                    puts stderr "Can't find a zeromq compiled package in $val."
                    exit 1
                }
            }
            -install {
                set val [apply $getarg $opt]
		if {$val eq "" || $val eq "-"} {
		    set val [file dirname [info library]]
		}
		if {[file writable $val] && 
		    [lindex [file system $val] 0] eq "native"} {
		    set opts(-install) $val
		} else {
		    puts stderr "Can't install into \"$val\""
		    exit 1
		}
            }
	    -static {
		set opts(-static) 1
	    }
	    -test {
		set opts(-test) 1
	    }
            help - -help - --help - -h {
                usage
                exit
            }
            default {
                puts stderr "unrecognized option \"$opt\""
                usage
                exit 1
            }
        }
    }
}

# Print build script options
proc usage {} {
    puts stderr "Options are:"
    puts stderr "   -critcl  <file>  path to critcl or critcl.kit."
    puts stderr "   -zeromq  <dir>   zeromq compiled package directory."
    puts stderr "   -install <dir>   directory to install tclzmq. Use \"\" or \"-\" to"
    puts stderr "                    install into Tcl library directory."
    puts stderr "   -static          link zmq statically."
    puts stderr "   -test            run the test scripts."
}

# Search for critcl.kit starkit file.
proc search_crictl {} {
    global pkgdir
    lappend dirs $pkgdir [file dirname $pkgdir] [info nameofexecutable]
    foreach dir $dirs {
        if {[file exists "$dir/critcl.kit"]} {
            return "$dir/critcl.kit"
        }
    }
    puts stderr "Can't find critcl.kit in [join $dirs ", "]."
    puts stderr "Use -critcl option."
    exit 1
}

# Search for zeromq compiled package.
proc search_zeromq {} {
    global pkgdir

    set searchpath $::searchpath
    lappend searchpath "[file dirname $pkgdir]/libzmq" \
	{*}[lsort -dictionary -decreasing \
		[glob -nocomplain -types d -directory [file dirname $pkgdir] "zeromq*"]]

    foreach dir $searchpath {
        if {[check_zeromq $dir]} {
            return $dir
        }
    }
    puts stderr "Can't find a zeromq compiled package."
    puts stderr "Use -zeromq option."
    exit 1
}

proc check_zeromq {dir} {
    if {[file exists "$dir/include/zmq.h"] &&
	[find_lib "$dir/lib/libzmq" "$dir/src/.libs/libzmq"] ne ""} {
        return 1
    } else {
        return 0
    }
}

proc find_lib {args} {
    foreach prefix $args {
	foreach suffix $::libsuffix {
	    if {[file exists $prefix$suffix]} {
		return $prefix$suffix
	    }
	}
    }
}

main $argv
