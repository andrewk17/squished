import Foundation

public enum SSHCommand {
    public static func validAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.utf8.count <= 253 && !alias.hasPrefix("-")
            && alias.range(of: "\\A[A-Za-z0-9._@%+:-]+\\z", options: .regularExpression) != nil
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public enum ValidationError: Error, LocalizedError {
        case invalidAlias
        public var errorDescription: String? {
            "Invalid SSH alias"
        }
    }

    public static func arguments(alias: String, interval: TimeInterval) throws -> [String] {
        guard validAlias(alias) else {
            throw ValidationError.invalidAlias
        }

        return [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=2", "-o",
            "ServerAliveCountMax=2", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "RequestTTY=no", "-o",
            "LogLevel=ERROR", "--", alias, "sh -c " + quote(RemoteSampler.script(interval: interval)),
        ]
    }
}

public enum RemoteSampler {
    /// `awkCommand` is a trusted executable selection for local compatibility tests.
    public static func script(interval: TimeInterval, awkCommand: String = "awk") -> String {
        let interval = FleetFormat.decimal(max(0.1, min(60, interval.isFinite ? interval : 2)), digits: 2)
        return "LC_ALL=C; export LC_ALL\n" + awkCommand + " -v interval=" + interval + " " + SSHCommand.quote(program)
            + " &\n" + #"""
                pid=$!
                exec 3<&0
                cat <&3 >/dev/null 2>&1 &
                watch=$!
                exec 3<&-
                trap 'kill "$pid" "$watch" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT
                trap 'exit 0' HUP INT TERM
                wait "$watch"
                """#
        // `cat` runs in the background so `wait` can be interrupted: a shell defers
        // traps until a foreground child returns, so a foreground `cat` kept a killed
        // shell (and the SSH session) alive until stdin closed. The explicit fd 3
        // redirect is needed because POSIX sh gives background jobs /dev/null as stdin.
    }

    public static let program = #"""
        function emit(line) {
            print line
            wireBytes += length(line) + 1
        }

        function readone(file, value) {
            value = ""
            getline value < file
            close(file)
            return value
        }

        function command(cmd, value) {
            value = ""
            cmd | getline value
            close(cmd)
            return value
        }

        function emitfile(file, line) {
            while ((getline line < file) > 0) emit(line)
            close(file)
        }

        BEGIN {
            os = command("uname -s")
            kernel = command("uname -r")
            host = command("hostname")
            hz = command("getconf CLK_TCK") + 0
            if (hz <= 0) hz = 100
            pagesize = command("getconf PAGESIZE") + 0
            if (pagesize <= 0) pagesize = 4096
            pretty = "Linux"
            while ((getline line < "/etc/os-release") > 0) {
                if (line ~ /^PRETTY_NAME=/) {
                    sub(/^PRETTY_NAME=/, "", line)
                    gsub(/^"|"$/, "", line)
                    pretty = line
                }
            }
            close("/etc/os-release")
            cpus = 0
            while ((getline line < "/proc/stat") > 0) {
                if (line ~ /^cpu[0-9]+ /) cpus++
                if (line ~ /^btime /) { split(line, boot, " "); bootTime = boot[2] + 0 }
            }
            close("/proc/stat")
            hasPSI = system("test -r /proc/pressure/memory") == 0
            seq = 0
            previousTime = 0
            while (1) {
                seq++
                wireBytes = 0
                emit("@@FLEET 1 " seq)
                if (seq == 1) {
                    emit("#info")
                    emit("os " os)
                    emit("kernel " kernel)
                    emit("pretty " pretty)
                    emit("hostname " host)
                    emit("cpus " cpus)
                    emit("clk_tck " hz)
                    emit("pagesize " pagesize)
                }
                if (os != "Linux") {
                    emit("@@END " seq)
                    fflush()
                    exit
                }
                emit("#cpu")
                while ((getline line < "/proc/stat") > 0) {
                    if (line ~ /^cpu /) {
                        emit(line)
                        break
                    }
                }
                close("/proc/stat")
                emit("#mem")
                while ((getline line < "/proc/meminfo") > 0) {
                    if (line ~ /^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SReclaimable|Shmem|SwapTotal|SwapFree):/) {
                        gsub(/[ \t]+/, " ", line)
                        emit(line)
                    }
                }
                close("/proc/meminfo")
                emit("#psi")
                # Missing PSI is normal; busybox awk treats missing files as fatal.
                if (hasPSI) emitfile("/proc/pressure/memory")
                emit("#load")
                emitfile("/proc/loadavg")
                emit("#uptime")
                up = readone("/proc/uptime")
                emit(up)
                split(up, u, " ")
                now = u[1] + 0
                emit("#df")
                cmd = "df -Pkl 2>/dev/null || df -Pk 2>/dev/null"
                split("", diskMount); split("", diskRow); split("", diskTotal)
                hasLargeDisk = 0
                while ((cmd | getline line) > 0) {
                    split(line, d, " ")
                    if (d[1] !~ /^\/dev\// || d[1] ~ /^\/dev\/loop/ || d[6] !~ /^\//) continue
                    if (d[6] ~ /^\/(boot|snap|run)(\/|$)/ || d[6] ~ /^\/var\/lib\/docker(\/|$)/) continue
                    source = d[1]; mount = d[6]
                    if (source in diskMount && (length(diskMount[source]) < length(mount) || (length(diskMount[source]) == length(mount) && diskMount[source] <= mount))) continue
                    diskMount[source] = mount
                    diskTotal[source] = d[3] + d[4]
                    diskRow[source] = d[1] " " d[2] " " d[3] " " d[4] " " d[5] " " mount
                }
                close(cmd)
                # Filter here too: pseudo mounts and btrfs duplicates must not
                # consume the small wire budget before Swift sees the frame.
                for (source in diskTotal) if (diskTotal[source] >= 4194304) hasLargeDisk = 1
                for (rank = 1; rank <= 6; rank++) {
                    winner = ""
                    for (source in diskMount) {
                        if (hasLargeDisk && diskTotal[source] < 4194304) continue
                        if (winner == "" || diskMount[source] == "/" || (diskMount[winner] != "/" && diskMount[source] < diskMount[winner])) winner = source
                    }
                    if (winner == "") break
                    emit(diskRow[winner])
                    delete diskMount[winner]
                }
                emit("#net")
                while ((getline line < "/proc/net/dev") > 0) {
                    if (line !~ /:/) continue
                    name = line
                    sub(/:.*/, "", name)
                    gsub(/^[ \t]+|[ \t]+$/, "", name)
                    # Match NetworkInterface.includes before budgeting the frame:
                    # Docker/tunnel rows on a NAS otherwise squeeze group keys to one byte.
                    if (name ~ /^(lo|docker|veth|br-|virbr|vnet|tun|tap|wg|zt|utun|awdl|llw|bridge|ap|gif|stf|anpi|ipsec)/ || readone("/sys/class/net/" name "/tun_flags") != "") continue
                    # Remove padding without changing counter precision in awk doubles.
                    gsub(/[ \t]+/, " ", line)
                    sub(/^ /, "", line)
                    emit(line)
                }
                close("/proc/net/dev")
                split("", gcpu)
                split("", grss)
                split("", gn)
                split("", gstart)
                split("", seen)
                split("", pcpu)
                split("", prss)
                split("", pname)
                cmd = "ls /proc"
                while ((cmd | getline pid) > 0) {
                    if (pid !~ /^[0-9]+$/) continue
                    line = readone("/proc/" pid "/stat")
                    if (line == "" || line !~ /\)/) continue
                    rest = line
                    sub(/^.*\) /, "", rest)
                    n = split(rest, f, " ")
                    if (n < 22) continue
                    opening = index(line, "(")
                    name = substr(line, opening + 1, length(line) - length(rest) - opening - 2)
                    gsub(/[\t\r\n]/, " ", name)
                    ticks = f[12] + f[13]
                    start = f[20]
                    rss = f[22] * pagesize / 1024
                    if (!(pid in starts) || starts[pid] != start) {
                        key = name
                        kind = "p"
                        if (pid == 2 || f[2] == 2) key = "[kernel]"
                        else if (name ~ /^(MainThread|node-MainThread|node|bun|deno|npx|python[^ ]*|ruby|java|perl|php|sh|bash|zsh)$/ || name ~ /^(qemu-system-|emulator)/) {
                            args = command("tr '\\0' ' ' < /proc/" pid "/cmdline 2>/dev/null")
                            argc = split(args, argv, " ")
                            if (name == "MainThread" || name == "node-MainThread") {
                                executable = argv[1]
                                sub(/^.*\//, "", executable)
                                if (executable == "node") name = "node"
                            }
                            if (name ~ /^(qemu-system-|emulator)/) {
                                for (a = 2; a < argc; a++) if (argv[a] == "-avd") { key = argv[a+1]; kind = "e"; break }
                            } else if (name != "MainThread" && name != "node-MainThread") {
                                script = ""
                                for (a = 2; a <= argc; a++) {
                                    if (argv[a] == "-c" || argv[a] == "-e") break
                                    if (argv[a] == "-m") { script = argv[a+1]; break }
                                    if (argv[a] ~ /^-/) continue
                                    script = argv[a]
                                    sub(/^.*\//, "", script)
                                    sub(/\.(mjs|cjs|js|py|rb|sh|jar)$/, "", script)
                                    sub(/@[^@]*$/, "", script)
                                    break
                                }
                                if (script != "") { key = name ":" script; kind = "i" }
                            }
                        }
                        gsub(/[\t\r\n]/, " ", key)
                        keys[pid] = kind " " substr(key, 1, 48)
                    }
                    rate = 0
                    if (previousTime > 0 && now > previousTime && (pid in old) && starts[pid] == start && ticks >= old[pid])
                        rate = int((ticks - old[pid]) * 1000 / (hz * (now - previousTime)) + 0.5)
                    key = keys[pid]
                    pcpu[pid] = rate; prss[pid] = rss; pname[pid] = name
                    gcpu[key] += rate
                    grss[key] += rss
                    gn[key]++
                    # Only emulator groups need a wall-clock start on the wire.
                    if (substr(key, 1, 2) == "e " && bootTime > 0 && start > 0) {
                        started = int(bootTime + start / hz)
                        if (!(key in gstart) || started < gstart[key]) gstart[key] = started
                    }
                    old[pid] = ticks
                    starts[pid] = start
                    seen[pid] = 1
                }
                close(cmd)
                for (pid in old) if (!(pid in seen)) { delete old[pid]; delete starts[pid]; delete keys[pid] }
                split("", selected)
                split("", wanted)
                for (metric = 1; metric <= 2; metric++) {
                    split("", topkeys)
                    split("", topscores)
                    # Keep a bounded sorted top eight in one group pass. Most
                    # groups fail the eighth-place cutoff without any shifting.
                    for (key in gn) {
                        value = metric == 1 ? gcpu[key] : grss[key]
                        if (topkeys[8] != "" && (value < topscores[8] || (value == topscores[8] && key > topkeys[8]))) continue
                        rank = 8
                        while (rank > 1 && (topkeys[rank - 1] == "" || value > topscores[rank - 1] || (value == topscores[rank - 1] && key < topkeys[rank - 1]))) {
                            topkeys[rank] = topkeys[rank - 1]
                            topscores[rank] = topscores[rank - 1]
                            rank--
                        }
                        topkeys[rank] = key
                        topscores[rank] = value
                    }
                    for (rank = 1; rank <= 8; rank++) {
                        winner = topkeys[rank]
                        if (winner == "") break
                        selected[winner] = 1
                        if (rank <= 3) wanted[winner] = metric
                    }
                }
                count = 0
                fixed = 0
                for (key in selected) {
                    count++
                    # Numeric fields, kind plus space, newline. Reserve the end marker.
                    fixed += length(sprintf("%.0f %.0f %d ", gcpu[key], grss[key], gn[key])) + 3
                    if (key in gstart) fixed += length(sprintf("%.0f\t", gstart[key]))
                }
                # Stable device identities must not depend on ranking or on the
                # shortened keys in #groups. A missing completion marker means
                # this bounded presence list cannot be used to end sessions.
                emit("#devices")
                deviceBytes = 0; deviceComplete = 1
                for (key in gn) if (substr(key, 1, 2) == "e ") {
                    row = sprintf("%.0f %.0f %.0f %s", key in gstart ? gstart[key] : 0, gcpu[key], grss[key], substr(key, 3))
                    if (deviceBytes + length(row) + 1 > 384 || wireBytes + length(row) + fixed + count + length("@@END " seq) + 30 >= 2048) {
                        deviceComplete = 0
                        continue
                    }
                    emit(row)
                    deviceBytes += length(row) + 1
                }
                if (deviceComplete) emit("complete")
                emit("#groups")
                keyBudget = count ? int((2047 - wireBytes - length("@@END " seq) - 1 - fixed - 650) / count) : 48
                if (keyBudget > 48) keyBudget = 48
                if (keyBudget < 1) keyBudget = 1
                for (key in selected) {
                    wireKey = substr(key, 1, keyBudget + 2)
                    if (key in gstart) wireKey = "e " sprintf("%.0f\t", gstart[key]) substr(key, 3, keyBudget)
                    emit(sprintf("%.0f %.0f %d %s", gcpu[key], grss[key], gn[key], wireKey))
                }
                emit("#members")
                split("", sent)
                split("", head)
                split("", nextpid)
                # Bucket wanted members once. Linked PID lists avoid concatenating
                # large strings and rescanning every process for every group/rank.
                for (pid in seen) {
                    key = keys[pid]
                    if (key in wanted) {
                        nextpid[pid] = head[key]
                        head[key] = pid
                    }
                }
                # Round-robin: every selected group gets a first member before a
                # group gets a second. Up to five per group, within the wire cap.
                for (rank = 1; rank <= 5; rank++) for (key in wanted) {
                    winner = ""; score = -1
                    for (pid = head[key]; pid != ""; pid = nextpid[pid]) if (!(pid in sent)) {
                        value = wanted[key] == 1 ? pcpu[pid] : prss[pid]
                        if (value > score || (value == score && pid + 0 < winner + 0)) { winner = pid; score = value }
                    }
                    if (winner == "") continue
                    sent[winner] = 1
                    row = sprintf("%s\t%s %.0f %.0f %s", substr(key, 1, keyBudget + 2), winner, pcpu[winner], prss[winner], substr(pname[winner], 1, 24))
                    if (wireBytes + length(row) + length("@@END " seq) + 2 < 2048) emit(row)
                }
                previousTime = now
                emit("@@END " seq)
                fflush()
                system("sleep " interval)
            }
        }
        """#
}
