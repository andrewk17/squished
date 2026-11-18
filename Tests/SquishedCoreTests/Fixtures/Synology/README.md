Sanitized reproduction of a Synology/Linux 4.4 NAS frame-budget failure
observed on 2026-11-16 with GNU Awk 5.0.0. All application/process names
except standard kernel names, and all Docker interface IDs, are synthetic.
Numeric stat fields and network counters retain the captured layout; no
hostnames, addresses, usernames, arguments or executable paths are included.

- `net-dev.txt`: normalized `/proc/net/dev` rows with synthetic Docker IDs.
  Docker bridges were emitted despite the app excluding them from totals.
- `process-stat.txt`: `/proc/<pid>/stat` rows for twenty non-interpreter
  processes, plus PID 2 and 3 (kernel grouping). Synthetic names retain the
  original lengths, including the space-containing `media worker 01`.

The integration check runs the complete awk sampler against a temporary
filesystem with these rows, then decodes its frames and groups. Previously
the network rows exhausted the key budget and emitted one-character keys
instead of readable names. Extra virtual-interface rows exercise parity with
the Swift network filter; synthetic system metrics fill the other sections.
