# Kindle for webOS — login migration between TouchPads

This document describes how to move a registered Kindle session from one HP
TouchPad ("donor") onto another TouchPad ("target") so the target can read the
donor's purchased books. It is the result of a reverse-engineering session
against Kindle Beta 0.12.50 (`com.palm.app.kindle`) on webOS 3.0.5 (topaz).

The procedure is fully reversible — nothing in the on-device installation of
the app is modified.

That said, this was an experiment/investigation. You probably don't want to do this.

## TL;DR — just run the scripts

If you don't want to read everything, the whole flow is automated in two
scripts under [`tools/`](tools/):

```sh
# Donor connected to USB, target unplugged:
./tools/extract_from_donor.sh   ./mybackup

# Unplug donor, plug in target:
./tools/inject_to_target.sh     ./mybackup
```

Each script reboots its TouchPad twice and prints what it's doing at every
step. They check that you have only one device connected, that you're not
about to wipe the donor with its own data, and they verify the post-state
when they finish. The rest of this document explains what they do and why.

## Why this is needed

You cannot log into the Kindle app on a fresh TouchPad anymore: the
`RegisterDevice` call goes to Amazon's FIRS service, which still answers but
no longer accepts new registrations from this device type
(`AQXVGOD3M416X` — "WebOS TouchPad"). Devices that registered years ago keep
working because Amazon honors the long-lived ADP token that was issued at the
time, but the registration endpoint itself is closed.

The trick is therefore: take the credentials off a working device and put them
on a fresh one. Two layers need transferring:

1. **The credentials** — stored by `plugin_kcf` in the platform Keymanager
   (`palm://com.palm.keymanager/`, backed by `/var/palm/data/keys.db`).
2. **Local library state** — stored by the JS app in Db8
   (`com.palm.kindle.*` kinds in `/var/db/main/`), plus the already-downloaded
   `.azw` files under `/media/internal/.palmkindle/`.

There is also a subtle third issue: DRM decryption is keyed off the device's
NDUID (`PDL_GetUniqueID`, which reads `/proc/nduid`). The donor's books are
encrypted for the donor's NDUID, so on the target we must make
`/proc/nduid` return the donor's value. We do this with a `mount --bind` of a
plain file containing the donor NDUID, applied late in boot so it doesn't
break `mountcrypt` (which derives the `store-cryptodb` key from the *real*
NDUID).

## Prerequisites

On the workstation:

- **novacom** + **novacomd** installed and the TouchPad's developer mode
  enabled (`Settings → System → Developer mode`, then plug in via USB).
- `python3` (any 3.x).
- A unix-y shell (Bash/Zsh).

On both TouchPads:

- Developer mode enabled, USB connected.
- Same Kindle app version (`com.palm.app.kindle` 0.12.50 / svnRevision 513361
  in our case — check `appinfo.json`).
- Same webOS device family (we only verified on `topaz` — i.e. TouchPad).

> **Hostnames help.** Set them ahead of time (`hostname YourLabel`,
> persistent in `/var/luna/preferences/sysmgr-args`) so you can tell donor
> and target apart in `novacom run` sessions when only one is plugged in.

A quick way to identify which device is currently connected if you forget:

```sh
echo "hostname; cat /proc/nduid" | novacom -t run file:///bin/sh
```

## High-level flow

```
DONOR                                    WORKSTATION                    TARGET
  │                                           │                            │
  │  1. patch lunasend role + reboot          │                            │
  │  2. extract keymanager keys               │                            │
  │  3. extract Db8 (books, configdata, …)    │                            │
  │  4. tar /media/internal/.palmkindle       │                            │
  │  5. restore role + reboot                 │                            │
  │                                           │                            │
  │ ─────────── files pulled ────────────────►│                            │
  │                                           │ ─── files pushed ──────────►│
  │                                           │                            │  6. patch lunasend role + reboot
  │                                           │                            │  7. inject keymanager keys
  │                                           │                            │  8. inject Db8 rows
  │                                           │                            │  9. untar .palmkindle
  │                                           │                            │ 10. install nduid override + upstart job
  │                                           │                            │ 11. restore role + reboot
  │                                           │                            │ 12. launch app, read
```

All transfers go through `novacom get` / `novacom put`. There is no need for
the two devices to be plugged in simultaneously.

# Part 1 — Extract from the donor

## 1.1 Why we need an LS2 role patch

`palm://com.palm.keymanager/fetchKey` is scoped per *caller service name*: a
key stored by `com.palm.app.kindle` can only be read back by something that
registers under that exact name. The LS2 hub binds service names to executable
paths via role files; `com.palm.app.kindle.json` only lets
`plugin_kcf` claim the kindle name. We can't easily run as `plugin_kcf` from
the shell, but `/usr/bin/luna-send` *also* has a role file
(`com.palm.lunasend.json`) — if we add `com.palm.app.kindle` to its
`allowedNames`, `luna-send -m com.palm.app.kindle` works.

The hub caches the role tables at startup, so the cleanest way to load a role
change is via a normal reboot.

## 1.2 Apply the role patch

```sh
novacom run file:///bin/sh <<'EOF'
mkdir -p /media/internal/.kindle-keys-bak
cp /usr/share/ls2/roles/prv/com.palm.lunasend.json /media/internal/.kindle-keys-bak/lunasend.prv.orig
cp /usr/share/ls2/roles/pub/com.palm.lunasend.json /media/internal/.kindle-keys-bak/lunasend.pub.orig

PATCH='{"role":{"exeName":"/usr/bin/luna-send","type":"privileged","allowedNames":["","com.palm.lunasend","com.palm.app.kindle"]},"permissions":[{"service":"com.palm.lunasend","inbound":["*"],"outbound":["*"]},{"service":"com.palm.app.kindle","inbound":["*"],"outbound":["*"]}]}'
echo "$PATCH" > /usr/share/ls2/roles/prv/com.palm.lunasend.json
echo "$PATCH" > /usr/share/ls2/roles/pub/com.palm.lunasend.json
sync
reboot
EOF
```

> **Backup directory**: `/media/internal/` is on a vfat partition shared with
> the host's USB drive view — it survives reboots and is easy to inspect from
> the workstation. We use it for backups throughout.

Wait for the device to come back (`novacom -l` shows it, then give it ~20s
for sysmgr to settle).

## 1.3 Pull the credentials and library state

The five secret values live in the keymanager. The library/config lives in
Db8. The `.azw` files and cover cache live on the media partition.

```sh
mkdir -p ~/kindle-migration && cd ~/kindle-migration

# All five keymanager values
novacom run file:///bin/sh <<'EOF' > /dev/null
mkdir -p /tmp/kx
for k in token private_key user_name device_name serial_number drm_configuration; do
  luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/fetchKey \
    "{\"keyname\":\"$k\"}" > /tmp/kx/$k.raw 2>&1
done
EOF
for f in token private_key user_name device_name serial_number drm_configuration; do
  novacom get file:///tmp/kx/$f.raw > $f.raw
done

# All five Db8 kinds the app uses
novacom run file:///bin/sh <<'EOF' > /dev/null
for kind in books collections configdata annotations readingpositions; do
  luna-send -t 1 -m com.palm.app.kindle palm://com.palm.db/find \
    "{\"query\":{\"from\":\"com.palm.kindle.${kind}:1\"}}" > /tmp/donor_${kind}.full 2>&1
done
EOF
for f in books collections configdata annotations readingpositions; do
  novacom get file:///tmp/donor_$f.full > donor_$f.full
done

# Tar the media files (.azw + coverCache)
echo "cd /media/internal && tar cf /tmp/palmkindle.tar .palmkindle" | novacom -t run file:///bin/sh
novacom get file:///tmp/palmkindle.tar > donor_palmkindle.tar

# Keep the NDUID for the override on the target
echo "cat /proc/nduid" | novacom -t run file:///bin/sh > donor_nduid.txt
```

Sanity check what came back:

```sh
wc -c *.raw donor_*.full donor_palmkindle.tar donor_nduid.txt
```

The interesting one is `token.raw` — the `keydata` field is base64 of a string
in the form `{enc:…}{iv:…}{name:base64("ADPTokenEncryptionKey")}{serial:base64("2")}`.
That is Amazon's own ADP-token serialization — opaque to us, decrypted server
side, copied byte-for-byte.

`private_key.raw` is the base64 of a normal PEM `-----BEGIN RSA PRIVATE KEY-----`
block (2048-bit) used by `RequestSigner` for `X-ADP-Request-Digest`.

The other three (`user_name`, `device_name`, `serial_number`) are stored
plain. **`serial_number` equals the donor's NDUID** — Amazon's record of the
device serial is the NDUID that was live at registration time, and we'll
mirror that on the target.

## 1.4 Restore the donor's role file and reboot

```sh
novacom run file:///bin/sh <<'EOF'
cp /media/internal/.kindle-keys-bak/lunasend.prv.orig /usr/share/ls2/roles/prv/com.palm.lunasend.json
cp /media/internal/.kindle-keys-bak/lunasend.pub.orig /usr/share/ls2/roles/pub/com.palm.lunasend.json
sync
reboot
EOF
```

The donor is now back to a stock-permission state. You can verify by trying
the impersonation again post-reboot — it should return
`Invalid permissions for com.palm.app.kindle`.

# Part 2 — Inject onto the target

## 2.1 Apply the same role patch and reboot

Identical to step 1.2 above. (`novacom -l` will still show the donor's NDUID
on the target after step 2.4 finishes, so make sure you have only the target
connected here.)

## 2.2 Prepare the injection payload on the workstation

We need:

1. A JSON file mapping keyname → keydata (base64) for each of the five
   keymanager entries.
2. A series of Db8 `put` payloads. Each `put` accepts an `objects` array; we
   chunk into batches of 25 so a single `luna-send` argv stays well under
   any kernel `ARG_MAX` limits.
3. A small shell script that runs on the target and does everything in
   sequence.

```python
# extract.py — run from ~/kindle-migration
import base64, json, pathlib, re

def parse_payload(path):
    text = open(path).read()
    m = re.search(r'payload (\{.*?\})\n', text, re.DOTALL)
    return json.loads(m.group(1)) if m else None

# 1. Re-base64 the keymanager values into a clean JSON.
keys = {}
for name in ('token', 'private_key', 'user_name',
            'device_name', 'serial_number'):
    p = parse_payload(f'{name}.raw')
    if not p or not p.get('returnValue'):
        continue
    decoded = base64.b64decode(p['keydata'])
    keys[name] = base64.b64encode(decoded).decode()
pathlib.Path('keys_b64.json').write_text(json.dumps(keys, indent=2))

# 2. Flatten every Db8 row into one big list of objects.
objects = []
for kind in ('books', 'collections', 'configdata',
             'annotations', 'readingpositions'):
    p = parse_payload(f'donor_{kind}.full')
    if not p:
        continue
    for row in p.get('results', []):
        # _rev is server-generated; drop it. Keep _id and _kind.
        objects.append({k: v for k, v in row.items() if k != '_rev'})

# 3. Chunk into 25-row batches.
pathlib.Path('inject_chunks').mkdir(exist_ok=True)
for i in range(0, len(objects), 25):
    chunk = objects[i:i+25]
    pathlib.Path(f'inject_chunks/chunk_{i//25:03d}.json').write_text(
        json.dumps({'objects': chunk}, separators=(',', ':')))

print(f'wrote keys_b64.json ({len(keys)} entries)')
print(f'wrote {len(list(pathlib.Path("inject_chunks").iterdir()))} db chunks '
      f'({len(objects)} rows total)')
```

Run it:

```sh
python3 extract.py
```

Now build the on-target script:

```sh
DONOR_NDUID=$(cat donor_nduid.txt | tr -d '[:space:]')

cat > apply_donor.sh <<EOF
#!/bin/sh
set -e

echo "=== untar .palmkindle ==="
cd /media/internal
tar xf /tmp/palmkindle.tar

echo "=== inject keymanager values ==="
EOF

python3 - <<PY >> apply_donor.sh
import json
keys = json.load(open('keys_b64.json'))
for name, b64 in keys.items():
    payload = {
        'keyname': name, 'keydata': b64, 'type': 'BLOB',
        'nohide': True, 'shared': True, 'noexport': False,
        'backup': False, 'cloud': False,
    }
    # Remove any old row first so we don't trip uniqueness, then store.
    print(f'luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/remove '
          f"'{{\"keyname\":\"{name}\"}}' >/dev/null 2>&1 || true")
    print(f"luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/store "
          f"'{json.dumps(payload, separators=(',', ':'))}' "
          "| grep -oE 'returnValue\":[a-z]*' | head -1")
PY

cat >> apply_donor.sh <<EOF

echo "=== inject Db8 rows ==="
for f in /tmp/chunk_*.json; do
  luna-send -t 1 -m com.palm.app.kindle palm://com.palm.db/put "\$(cat \$f)" \
    | grep -oE 'returnValue":[a-z]*|errorText":"[^"]*' | head -1
done

echo "=== install NDUID override ==="
mkdir -p /var/lib/kindle-migrate
printf '${DONOR_NDUID}\n' > /var/lib/kindle-migrate/nduid

cat > /etc/event.d/kindle-nduid-override <<'JOB'
description "Bind-mount /proc/nduid (host + kindle jail) with donor NDUID"

# Fires AFTER mountcrypt (which decrypts /var/db using the *real* NDUID),
# so it must not run earlier than this event.
start on started LunaSysMgr

script
    if [ -f /var/lib/kindle-migrate/nduid ]; then
        mount --bind /var/lib/kindle-migrate/nduid /proc/nduid
        if [ -e /var/palm/jail/com.palm.app.kindle/proc/nduid ]; then
            mount --bind /var/lib/kindle-migrate/nduid \\
                /var/palm/jail/com.palm.app.kindle/proc/nduid
        fi
    fi
end script
JOB

echo "=== restore lunasend role ==="
cp /media/internal/.kindle-keys-bak/lunasend.prv.orig /usr/share/ls2/roles/prv/com.palm.lunasend.json
cp /media/internal/.kindle-keys-bak/lunasend.pub.orig /usr/share/ls2/roles/pub/com.palm.lunasend.json

sync
reboot
EOF
chmod +x apply_donor.sh
```

## 2.3 Push everything to the target

```sh
novacom put file:///tmp/palmkindle.tar < donor_palmkindle.tar
for f in inject_chunks/chunk_*.json; do
  novacom put file:///tmp/$(basename $f) < $f
done
novacom put file:///tmp/apply_donor.sh < apply_donor.sh
```

## 2.4 Run the injection script

```sh
echo "/bin/sh /tmp/apply_donor.sh" | novacom -t run file:///bin/sh
```

You'll see roughly: untar, five `returnValue:true` from keymanager stores,
~21 `returnValue:true` from Db8 puts, then the device reboots. Wait for it.

## 2.5 Verify and launch

```sh
novacom run file:///bin/sh <<'EOF'
echo "=== nduid override active? ==="
mount | grep nduid     # expect two lines (host + jail)
cat /proc/nduid        # expect donor NDUID

echo "=== launch kindle ==="
luna-send -t 1 -P palm://com.palm.applicationManager/launch '{"id":"com.palm.app.kindle"}'
EOF
```

The card should open straight into the library list (no login prompt), the
archived books from the donor should appear, and tapping a downloaded book
should let you read it. Tapping an archived book triggers a fresh download
from Amazon's `cde-ta-g7g.amazon.com` endpoint, which still works.

# How it works (short version, for posterity)

| Layer | What it is | Where it lives | Who owns it | Notes |
|---|---|---|---|---|
| `token` | Amazon ADP token | `palm://com.palm.keymanager/`, blob stored in `/var/palm/data/keys.db` | `com.palm.app.kindle` | Opaque blob in Amazon's `{enc:…}{iv:…}{name:…}{serial:…}` format. Goes verbatim in the `X-ADP-Authentication-Token` header. |
| `private_key` | 2048-bit RSA, PEM | same | same | Used by `AmazonDevice::Authentication::RequestSigner` to fill `X-ADP-Request-Digest`. |
| `user_name` / `device_name` | UTF-8 strings | same | same | Read by Settings.js for the "Registered to …" line. |
| `serial_number` | hex string | same | same | Set to NDUID at first registration; Amazon's records key off this. |
| Library state | Db8 rows | `/var/db/main/` (encrypted partition `store-cryptodb`) | `com.palm.app.kindle` | `com.palm.kindle.{books,collections,configdata,annotations,readingpositions}:1` |
| Book files | `.azw`, covers | `/media/internal/.palmkindle/` | filesystem | Encrypted at rest with a PID derived from the NDUID. |
| NDUID | hex string | `/proc/nduid` (also `/dev/nduid`), kernel module | platform | Read by `PDL_GetUniqueID()`. |

Key things we learned the hard way:

1. **The `lunasend` role file** (`/usr/share/ls2/roles/{prv,pub}/com.palm.lunasend.json`)
   is the one that controls which service names `luna-send` may register.
   Editing `com.palm.app.kindle.json` did nothing because the LS2 hub picks the
   first role file that matches the executable, and `/usr/bin/luna-send` is
   claimed by lunasend's role file first.

2. **The LS2 hub doesn't reload roles on SIGHUP.** Bouncing it manually is
   risky (it briefly takes down every other service); a clean `reboot` is
   the most reliable way to pick up role-file changes.

3. **`/var/db` is normally `store-cryptodb`**, an encrypted dm-crypt volume
   unlocked at boot by `/usr/bin/mountcrypt`. The decryption key is derived
   from the device's real NDUID. So a fresh `/proc/nduid` override that fires
   *before* `mountcrypt` (e.g. `start on stopped bootmisc`) silently breaks
   the mount, and the system falls back to writing Db8 to plain `/var`, where
   BDB never successfully commits — so all your kind registrations and rows
   vanish on the next reboot. Our upstart job uses `start on started LunaSysMgr`
   so it fires *after* mountcrypt has done its work.

4. **The kindle app runs in a "hybrid jail"** with its own `/proc` mount
   (`/var/palm/jail/com.palm.app.kindle/proc`). DRM decryption happens inside
   that jail, so the NDUID override has to be applied to **both** the host
   `/proc/nduid` and the jail's `/proc/nduid`. Missing the jail bind was the
   cause of the initial "You are not authorized to open this book" error.

5. **Amazon's `SyncArchiveMetadata` endpoint at `todo-ta-g7g.amazon.com`
   returns HTTP 400** for both donor and target — but `plugin_kcf` only
   crashes on the response when the local library is empty
   (the `DoArchivedItems` path). The donor never takes that path because its
   `gotArchivedItems=true` row makes the JS choose `WhisperSyncLibrary`
   instead, which gracefully handles the same 400 and proceeds to the
   `getItems` call. Migrating the donor's library state seeds
   `gotArchivedItems=true`, which is what keeps us out of the crash path.

6. **Book DOWNLOADS at `cde-ta-g7g.amazon.com` still work** — that endpoint
   accepts the ADP-signed request and serves the encrypted `.azw`. Only
   the metadata-sync endpoint behaves badly. So *new* purchases that you
   make later on amazon.com (or via the Browse Store link) and that already
   appear in the migrated `com.palm.kindle.books:1` list re-download fine.
   *Newly purchased* books that aren't in the imported list won't appear
   automatically because the sync endpoint that would discover them is broken.

# What we changed on the target

Just these, for reverting cleanly:

- `/etc/event.d/kindle-nduid-override` — new upstart job (delete to revert).
- `/var/lib/kindle-migrate/nduid` — text file containing donor NDUID (delete).
- `/var/palm/data/keys.db` — five `keytable` rows added for owner
  `com.palm.app.kindle`. Remove with:
  ```sh
  for k in token private_key user_name device_name serial_number; do
    luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/remove \
      "{\"keyname\":\"$k\"}"
  done
  ```
  (Requires the lunasend role patch again. Or just `sqlite3 /var/palm/data/keys.db
  "DELETE FROM keytable WHERE ownerID='com.palm.app.kindle';"` after stopping
  the keymanager service.)
- `/var/db/main/*` — 520+ Db8 rows in `com.palm.kindle.*` kinds. Use
  `palm://com.palm.db/del` with the impersonation patch, or `palm-uninstall
  com.palm.app.kindle && palm-install` to wipe and reinstall the app.
- `/media/internal/.palmkindle/` — donor's `.azw` files and cover cache.
  Safe to delete from the host file manager.
- `/media/internal/.kindle-keys-bak/` — backup of the original
  `com.palm.lunasend.json` (and on the donor, our own `com.palm.app.kindle.json`
  backups). Safe to delete once you're confident things work.

The roles under `/usr/share/ls2/roles/` and `/var/palm/ls2/roles/` are restored
to their stock contents by the apply script. (You can verify with `diff` against
fresh installs.)

# Known caveats

- **`novacom -l` reports the donor's NDUID for the target after migration.**
  novacomd reads `/proc/nduid` at the bind-mount point too. This is cosmetic;
  USB enumeration still works fine. If two donor-cloned TouchPads were
  connected simultaneously, novacom would consider them the same device — use
  hostnames or unplug-one-at-a-time when you need to be sure.
- **Whispersync of new purchases is broken.** Anything the donor already saw
  is in `com.palm.kindle.books:1`. New purchases made *after* the migration
  cutoff won't appear automatically. Workarounds:
  - On the donor (while it still works), launch the app once after buying so
    its `books` kind picks up the new item, then re-run the extract.
  - Or insert a row into the target's `com.palm.kindle.books:1` by hand
    matching the ASIN — the download path will fetch it.
- **The connectivity check is wrong.** `palm://com.palm.connectionmanager/`
  reports `isInternetConnectionAvailable:false` on a healthy network because
  the upstream probe URL is dead. The kindle JS ignores this once it has
  `registered=true` + a populated library, but if you ever clear
  `gotArchivedItems`, the app falls back to the `SyncArchiveMetadata` path
  and crashes plugin_kcf on the response.
- **The bind-mount is per-boot.** The upstart job re-establishes it at every
  boot triggered by `started LunaSysMgr`. If you ever stop LunaSysMgr without
  rebooting (developers occasionally do this), the override drops off until
  the next boot.

# Files in this repo's `extracted/` directory

These are the actual artifacts captured during the working migration on
2026-06-11. They're a useful reference for what the data should look like,
but they're tied to one specific donor — re-extract from your own donor.

| File | Contents |
|---|---|
| `keys.json` | The five decoded keymanager values (token still wrapped in Amazon's format). |
| `keys_b64.json` | Same, re-base64'd for `palm://com.palm.keymanager/store`. |
| `token.raw`, `private_key.raw`, … | Raw `luna-send` responses, including stderr. |
| `nduid.txt` | Donor NDUID. |
| `configdata.raw` | First successful Db8 dump (configdata only, 15 rows). |
| `donor_books.full`, `donor_configdata.full`, … | Later, full dumps of every Db8 kind. |
| `donor_palmkindle.tar` | Tarball of `/media/internal/.palmkindle/` from the donor (12 MB). |
| `inject_chunks/chunk_*.json` | Pre-chunked Db8 `put` payloads. |
| `apply_donor.sh` | The on-target injection script that was actually run. |
| `setup_db.sh`, `inject_keys.sh` | Earlier iterations of the same idea; kept for reference. |
| `patch_plan.json`, `KindlePluginUtil.patched` | An *abandoned* approach: ARM trampoline that patches `KindleDRMInfoProvider::getDeviceSerialNumber` to return a hardcoded NDUID. The bind-mount approach turned out to be cleaner, but if you ever can't override `/proc/nduid` (e.g. on a more locked-down platform), the patched binary is here as Plan B. |

Happy reading.
