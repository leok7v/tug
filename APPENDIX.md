# Appendix

## Toybox `pending/` command coverage (estimates)

Reference for deciding which **toybox pending commands** to enable. These live in
[`toys/pending/`](https://github.com/landley/toybox/tree/master/toys/pending) and
are unfinished to varying degrees; the numbers below are rough completeness
estimates (0.0–1.0) versus their GNU/util-linux/busybox equivalents — approximate,
based on the development state of the pending directory, not a line-by-line diff.

To enable one in our rootfs, add it to `PENDING` in the `rootfs` Makefile target
(mkroot expands `be2csv $PENDING SH ROUTE` into the toybox config). We currently
enable `VI` (and mkroot's default `SH ROUTE`). Anything ANSI-based (e.g. `vi`)
needs no terminfo; the host terminal renders it.

| Tool        | Est. coverage |
|-------------|--------------:|
| arp         | 0.7 |
| arping      | 0.8 |
| awk         | 0.5 |
| bc          | 0.8 |
| bootchartd  | 0.6 |
| brctl       | 0.8 |
| chsh        | 0.9 |
| crond       | 0.7 |
| crontab     | 0.8 |
| csplit      | 0.7 |
| dhcp        | 0.6 |
| dhcp6       | 0.4 |
| dhcpd       | 0.5 |
| diff        | 0.7 |
| dumpleases  | 0.8 |
| expr        | 0.9 |
| fdisk       | 0.6 |
| fsck        | 0.4 |
| getfattr    | 0.8 |
| getty       | 0.8 |
| git         | 0.1 |
| groupadd    | 0.9 |
| groupdel    | 0.9 |
| hexdump     | 0.8 |
| init        | 0.6 |
| ip          | 0.7 |
| ipcrm       | 0.9 |
| ipcs        | 0.9 |
| klogd       | 0.8 |
| last        | 0.8 |
| lsof        | 0.5 |
| man         | 0.6 |
| mdev        | 0.7 |
| modprobe    | 0.6 |
| more        | 0.8 |
| route       | 0.8 |
| sh          | 0.6 |
| strace      | 0.3 |
| stty        | 0.8 |
| sulogin     | 0.9 |
| syslogd     | 0.8 |
| tcpsvd      | 0.7 |
| telnet      | 0.8 |
| telnetd     | 0.7 |
| tftp        | 0.8 |
| tftpd       | 0.8 |
| tr          | 0.9 |
| traceroute  | 0.7 |
| useradd     | 0.8 |
| userdel     | 0.9 |
| vi          | 0.5 |
| xzcat       | 0.8 |

Notes:
- `dhcp` (0.6) would let the guest auto-configure networking from slirp's DHCP
  instead of the static `10.0.2.15` we set in `tug-init`.
- `awk` (0.5) and `bc` (0.8) are the in-guest scripting gaps until python/node land.
- `sh` (0.6) is the toybox shell we replaced with bash for line editing.
- `vi` (0.5) is enabled — usable for light edits but rough (see README/notes).
