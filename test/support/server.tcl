proc error_and_quit {config_file error} {
    puts "!!COULD NOT START REDIS-SERVER\n"
    puts "CONFIGURATION:"
    puts [exec cat $config_file]
    puts "\nERROR:"
    puts [string trim $error]
    exit 1
}

proc start_server {filename overrides {code undefined}} {
    set data [split [exec cat "test/assets/$filename"] "\n"]
    set config {}
    foreach line $data {
        if {[string length $line] > 0 && [string index $line 0] ne "#"} {
            set elements [split $line " "]
            set directive [lrange $elements 0 0]
            set arguments [lrange $elements 1 end]
            dict set config $directive $arguments
        }
    }
    
    # use a different directory every time a server is started
    dict set config dir [tmpdir server]
    
    # apply overrides from arguments
    foreach override $overrides {
        set directive [lrange $override 0 0]
        set arguments [lrange $override 1 end]
        dict set config $directive $arguments
    }
    
    # write new configuration to temporary file
    set config_file [tmpfile redis.conf]
    set fp [open $config_file w+]
    foreach directive [dict keys $config] {
        puts -nonewline $fp "$directive "
        puts $fp [dict get $config $directive]
    }
    close $fp

    set stdout [format "%s/%s" [dict get $config "dir"] "stdout"]
    set stderr [format "%s/%s" [dict get $config "dir"] "stderr"]
    exec ./redis-server $config_file > $stdout 2> $stderr &
    after 10
    
    # check that the server actually started
    if {[file size $stderr] > 0} {
        error_and_quit $config_file [exec cat $stderr]
    }
    
    set line [exec head -n1 $stdout]
    if {[string match {*already in use*} $line]} {
        error_and_quit $config_file $line
    }

    # find out the pid
    regexp {^\[(\d+)\]} [exec head -n1 $stdout] _ pid

    # create the client object
    set host $::host
    set port $::port
    if {[dict exists $config bind]} { set host [dict get $config bind] }
    if {[dict exists $config port]} { set port [dict get $config port] }
    set client [redis $host $port]

    # select the right db when we don't have to authenticate
    if {![dict exists $config requirepass]} {
        $client select 9
    }

    if {$code ne "undefined"} {
        # append the client to the client stack
        lappend ::clients $client
        
        # execute provided block
        catch { uplevel 1 $code } err

        # pop the client object
        set ::clients [lrange $::clients 0 end-1]
        
        # kill server and wait for the process to be totally exited
        exec kill $pid
        while 1 {
            if {[catch {exec ps -p $pid | grep redis-server} result]} {
                # non-zero exis status, process is gone
                break;
            }
            after 10
        }
        
        if {[string length $err] > 0} {
            puts "Error executing the suite, aborting..."
            puts $err
            exit 1
        }
    } else {
        dict set ret "config" $config_file
        dict set ret "pid" $pid
        dict set ret "stdout" $stdout
        dict set ret "stderr" $stderr
        dict set ret "client" $client
        set _ $ret
    }
}

proc kill_server config {
    set pid [dict get $config pid]
    exec kill $pid
}