# Siphon

Which application is eating your bandwidth, live in the Omarchy bar.

Every other network widget tells you *how fast* the link is going. Siphon tells
you *who is doing it*. Applications are ranked by what is moving right now, so
the top row answers "why is this crawling" the moment you open the panel.

## What it does

- **Per-application download and upload rates**, attributed to a real process
  name, refreshed every couple of seconds.
- **Ranked by current rate, not session total**, so an overnight backup that
  has gone quiet does not sit on top of the video call that is actually
  saturating the link.
- **Session totals per application**, kept after the connections close, so an
  app that woke up, moved 400 MB and went back to sleep is still visible.
- **Bar label** showing the combined rate, download only, or the name of the
  current worst offender. It holds a fixed width, so the widget does not
  resize and shunt its neighbours along the bar every time the rate crosses a
  digit or a unit.
- **A warning** when one application sustains more than a rate you choose,
  which is the number that matters on a tethered or metered connection.

## What it cannot measure, and says so

The kernel keeps byte counters for TCP sockets. It keeps none for UDP, and
QUIC (HTTP/3) rides on UDP. A browser streaming video over QUIC moves real
bytes that cannot be charged to it.

Siphon does not paper over that. It compares what the interfaces counted
against what it could attribute, and shows the difference in its own row,
naming the applications currently holding UDP sockets:

```
Not attributable
  ↓ 12.4 kB/s   ↑ 1.20 kB/s
  QUIC from spotify, brave, packet headers, and other users.
```

That row also absorbs packet framing, which the interface counts and a socket
does not, and connections owned by other users, which are not this session's
to read. Guessing a number for any of it would be worse than leaving it named
and unmeasured.

Loopback is excluded throughout. A local dev server moving 900 MB between two
processes on one machine is not network traffic, and counting it would put
whatever you are building at the top of the list every time.

## What it needs

Nothing elevated. Per-socket counters come from the kernel's socket
diagnostics, which report a process's own sockets to that process's owner.
Sockets belonging to other users show up without a name and are left out
rather than guessed at.

Three read-only commands per tick, and nothing else:

```bash
ss -tinpH          # TCP sockets, their owners, and their byte counters
ss -unpH           # UDP sockets and their owners, for the unmeasured note
cat /proc/net/dev  # what the interfaces themselves counted
```

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Text beside the icon | `total` | `none`, `total`, `down`, or `top-app`. Vertical bars stay icon-only. |
| Sample interval | 2s | How often the socket table is re-read. |
| Warn above | off | Notify when one app sustains more than this many Mbps. |

## Keys and clicks

- **Middle-click the bar icon**, or press `r` in the panel, to reset the
  session totals.
- **Escape** closes the panel.

## Tests

```bash
node test/model.test.js    # 36 tests, no compositor
node test/wiring.test.js   # cross-file checks: QML parses, bindings resolve
node test/live.js 5        # drives the model against this machine's sockets
```

`model.test.js` covers the parsing and accounting rules. `wiring.test.js`
covers what only breaks when two files disagree: QML that stopped parsing, a
renamed Model function the panel still calls, a setting offered in the manifest
that no code reads.

## Licence

MIT
