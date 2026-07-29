# LiSin — App manager (v2)

What each flatpak application is allowed to do, and control of it.

The endpoint agent (`v1/`) answers *what is on this machine*. This answers a
different question: *what may this application reach* — and lets you take it
away. Same shape, same engine bones, its own database and its own desktop entry.

## The distinction the whole thing is built on

Three readings, kept apart because the system itself keeps them apart:

- **Requested** — what the application asked for when it was built. Its author
  decided this; it can be overridden but never edited.
- **Overridden** — what this machine has said since, in
  `~/.local/share/flatpak/overrides/<id>`. Plain INI, written with
  `flatpak override --user`, **no root anywhere**.
- **Effective** — what the sandbox will get on the next launch. This is the only
  one that answers "can it read my files", and it is the one nothing else shows.

## What flatpak actually permits — measured here, not assumed

On flatpak 1.18, as an ordinary user:

- denying the network works: inside the sandbox there are then no interfaces and
  no DNS;
- **denying a directory inside an allowed one works**:
  `filesystems=/tmp/x;!/tmp/x/secret` and the secret directory does not exist from
  inside at all. That is what makes a path tree with per-node denials real rather
  than decorative;
- a full lockdown still starts: the application runs and sees one entry in its
  home instead of the contents.

## What it cannot do, and says so

- An override applies to the **next launch**, never to a running instance.
- An application allowed to talk to `org.freedesktop.Flatpak` can run anything on
  the host, outside the sandbox. Every other permission is then a formality, so
  it is reported on its own rather than as one line among forty.
- The **portals** grant access at runtime — the file you pick in a dialog is
  handed over without any override mentioning it. That is a separate store
  (`flatpak permission-list`) and it is shown separately.
- flatpak has no notion of "may run ssh". A profile for that is three grants:
  the ssh-auth socket, `~/.ssh` read-only, and the network.

## Running it

```bash
PYTHONNOUSERSITE=1 QT_QUICK_CONTROLS_STYLE=org.kde.desktop python3 v2/lisin_apps.py
```

## State of it

Read-only. The Applications section lists every installed application with what
it weighs (its own size and the runtime it shares), what it depends on, and its
permissions by category — requested against effective. Profiles and Policies are
declared and empty.
