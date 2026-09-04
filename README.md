# Siphon

Which app is eating your bandwidth, live in the Omarchy bar.

Every network widget on the marketplace tells you *how fast* the link is going.
None of them tell you *who is doing it*. Siphon ranks running applications by
what they are actually pushing and pulling, worst first, so the answer to "why
is my tether crawling" takes one glance instead of a terminal.

## Planned behaviour

- **Per-process upload and download rates**, attributed to a real application
  name rather than a PID, refreshed every couple of seconds.
- **Ranked panel**, heaviest app at the top, with a session total per app so a
  background sync that woke up an hour ago is still visible.
- **Bar label** showing the combined rate, download only, or the name of the
  current worst offender.
- **Threshold warning** when a single app sustains more than a configured rate,
  for metered and tethered connections.

## Status

Early scaffold. Manifest and licence only; no implementation yet.

## Attribution approach

To be decided between:

- `/proc/net/tcp` + `/proc/net/udp` inode-to-socket mapping walked against
  `/proc/*/fd`, sampled in userspace. No privileges, no dependencies, but misses
  short-lived connections between samples.
- eBPF via `bpftrace` or a small `libbpf` program on the socket send/receive
  path. Exact and cheap, but needs elevated privileges and a toolchain.

The first is the likely starting point, because a bar widget that needs root to
show a number is a bar widget nobody installs.

## Licence

MIT
