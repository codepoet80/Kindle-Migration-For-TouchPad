#!/bin/bash
# inject_to_target.sh
#
# Install a donor's Kindle credentials + library state onto a fresh target
# TouchPad. Drives the target over novacom.
#
# Usage:
#     ./inject_to_target.sh <donor-backup-dir>
#
# Where <donor-backup-dir> is the directory produced by extract_from_donor.sh.
#
# Only one TouchPad may be connected. The script reboots the target twice
# (once to apply a temporary role patch, once to apply all data and clean up).

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <donor-backup-dir>" >&2
    exit 1
fi

IN_DIR="$1"
if [[ ! -d "$IN_DIR" ]]; then
    echo "Error: $IN_DIR is not a directory" >&2
    exit 1
fi

REQUIRED=(
    token.raw private_key.raw user_name.raw device_name.raw serial_number.raw
    donor_books.full donor_collections.full donor_configdata.full
    donor_annotations.full donor_readingpositions.full
    donor_palmkindle.tar donor_nduid.txt
)
for f in "${REQUIRED[@]}"; do
    if [[ ! -e "$IN_DIR/$f" ]]; then
        echo "Error: $IN_DIR/$f missing — was extract_from_donor.sh run?" >&2
        exit 1
    fi
done

if ! command -v novacom >/dev/null 2>&1; then
    echo "Error: novacom not found in PATH" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found in PATH" >&2
    exit 1
fi

DONOR_NDUID=$(tr -d '[:space:]' < "$IN_DIR/donor_nduid.txt")
if [[ ! "$DONOR_NDUID" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: donor NDUID in $IN_DIR/donor_nduid.txt is malformed: '$DONOR_NDUID'" >&2
    exit 1
fi

run_sh() { novacom -t run file:///bin/sh "$@"; }

require_one_device() {
    local list count
    list=$(novacom -l 2>&1 | grep topaz || true)
    count=$(printf '%s\n' "$list" | grep -c topaz || true)
    if [[ $count -eq 0 ]]; then
        echo "Error: no topaz device connected" >&2
        exit 1
    elif [[ $count -gt 1 ]]; then
        echo "Error: multiple devices connected; unplug all but the target" >&2
        printf '%s\n' "$list" >&2
        exit 1
    fi
    printf '%s\n' "$list"
}

wait_for_device() {
    local elapsed=0 max=${1:-300}
    printf "Waiting for device to return"
    until novacom -l 2>&1 | grep -q topaz; do
        if (( elapsed >= max )); then
            echo
            echo "Error: device did not come back after ${max}s" >&2
            exit 1
        fi
        printf .
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo " back"
    echo "Giving sysmgr 25s to settle..."
    sleep 25
}

# --- main ---------------------------------------------------------------

echo "===================="
echo "Target injection"
echo "===================="
echo
echo "Detected device:"
require_one_device
echo
echo "Target identity:"
run_sh <<'EOF' | sed 's/^/  /'
echo "hostname: $(hostname)"
echo "nduid:    $(cat /proc/nduid)"
echo "uptime:   $(uptime | sed 's/^ *//')"
EOF

TARGET_NDUID=$(echo "cat /proc/nduid" | run_sh | tr -d '[:space:]')
if [[ "$TARGET_NDUID" == "$DONOR_NDUID" ]]; then
    echo
    echo "Error: the connected device's NDUID equals the donor's NDUID."
    echo "       Either you connected the donor by mistake, or you already" >&2
    echo "       ran inject_to_target.sh on this device and the previous" >&2
    echo "       /proc/nduid override is still active (try a reboot)." >&2
    echo "       donor:  $DONOR_NDUID" >&2
    echo "       device: $TARGET_NDUID" >&2
    exit 1
fi

echo
echo "  donor NDUID (will be installed as override): $DONOR_NDUID"
echo "  target NDUID (real hardware ID):             $TARGET_NDUID"
echo
read -p "This will REBOOT the target TWICE and inject 500+ Db8 rows. Continue? [y/N] " ans
[[ $ans =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

WORK_DIR="$IN_DIR/work"
mkdir -p "$WORK_DIR/chunks"

echo
echo "==> 1/6  Building injection payloads locally..."

python3 - "$IN_DIR" "$WORK_DIR" <<'PYEOF'
import base64, json, pathlib, re, sys

in_dir = pathlib.Path(sys.argv[1])
work   = pathlib.Path(sys.argv[2])

def parse(path):
    text = path.read_text(errors='replace')
    m = re.search(r'payload (\{.*?\})\n', text, re.DOTALL)
    return json.loads(m.group(1)) if m else None

# 1. Re-base64 the keymanager values into a clean JSON.
keys = {}
for name in ['token', 'private_key', 'user_name',
             'device_name', 'serial_number']:
    p = parse(in_dir / f'{name}.raw')
    if not p or not p.get('returnValue'):
        print(f'  warn: {name} could not be parsed (extract may have failed)')
        continue
    decoded = base64.b64decode(p['keydata'])
    keys[name] = base64.b64encode(decoded).decode()
(work / 'keys_b64.json').write_text(json.dumps(keys, indent=2))
print(f'    {len(keys)} keymanager values')

# 2. Flatten every Db8 row into one big list of objects.
objects = []
for kind in ['books', 'collections', 'configdata',
             'annotations', 'readingpositions']:
    p = parse(in_dir / f'donor_{kind}.full')
    if not p:
        continue
    for row in p.get('results', []):
        # _rev is server-generated; drop it. Keep _id and _kind.
        objects.append({k: v for k, v in row.items() if k != '_rev'})

# 3. Chunk into 25-row batches (luna-send argv stays well under any limit).
for old in (work / 'chunks').glob('chunk_*.json'):
    old.unlink()
chunks = 0
for i in range(0, len(objects), 25):
    chunk = objects[i:i+25]
    (work / 'chunks' / f'chunk_{i//25:03d}.json').write_text(
        json.dumps({'objects': chunk}, separators=(',', ':')))
    chunks += 1
print(f'    {len(objects)} Db8 rows in {chunks} chunks')
PYEOF

# --- generate the apply script (runs on the target) ----------------------

cat > "$WORK_DIR/apply_donor.sh" <<EOF
#!/bin/sh
set -e

echo "=== untar .palmkindle ==="
cd /media/internal
tar xf /tmp/palmkindle.tar

echo "=== inject keymanager values ==="
EOF

python3 - "$WORK_DIR/keys_b64.json" "$WORK_DIR/apply_donor.sh" <<'PYEOF'
import json, sys
keys = json.load(open(sys.argv[1]))
out  = open(sys.argv[2], 'a')
for name, b64 in keys.items():
    payload = {
        'keyname': name, 'keydata': b64, 'type': 'BLOB',
        'nohide': True, 'shared': True, 'noexport': False,
        'backup': False, 'cloud': False,
    }
    out.write(f"echo '-- {name}'\n")
    # Remove any old row first so we don't trip uniqueness.
    out.write(f"luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/remove ")
    out.write(f"'{{\"keyname\":\"{name}\"}}' >/dev/null 2>&1 || true\n")
    out.write(f"luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/store ")
    out.write(f"'{json.dumps(payload, separators=(',', ':'))}' ")
    out.write("| grep -oE 'returnValue\":[a-z]*' | head -1\n")
PYEOF

cat >> "$WORK_DIR/apply_donor.sh" <<EOF

echo "=== inject Db8 rows ==="
for f in /tmp/chunk_*.json; do
    echo "-- \$(basename \$f)"
    luna-send -t 1 -m com.palm.app.kindle palm://com.palm.db/put "\$(cat \$f)" \\
        | grep -oE 'returnValue":[a-z]*|errorText":"[^"]*' | head -1
done

echo "=== install NDUID override (donor: ${DONOR_NDUID}) ==="
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
cp /media/internal/.kindle-keys-bak/lunasend.prv.orig \\
    /usr/share/ls2/roles/prv/com.palm.lunasend.json
cp /media/internal/.kindle-keys-bak/lunasend.pub.orig \\
    /usr/share/ls2/roles/pub/com.palm.lunasend.json

sync
echo "=== rebooting ==="
reboot
EOF
chmod +x "$WORK_DIR/apply_donor.sh"

# --- 2/6 patch role on target and reboot ---------------------------------

echo
echo "==> 2/6  Applying temporary impersonation role patch and rebooting..."
run_sh <<'EOF'
mkdir -p /media/internal/.kindle-keys-bak
if [ ! -e /media/internal/.kindle-keys-bak/lunasend.prv.orig ]; then
    cp /usr/share/ls2/roles/prv/com.palm.lunasend.json \
        /media/internal/.kindle-keys-bak/lunasend.prv.orig
    cp /usr/share/ls2/roles/pub/com.palm.lunasend.json \
        /media/internal/.kindle-keys-bak/lunasend.pub.orig
fi
PATCH='{"role":{"exeName":"/usr/bin/luna-send","type":"privileged","allowedNames":["","com.palm.lunasend","com.palm.app.kindle"]},"permissions":[{"service":"com.palm.lunasend","inbound":["*"],"outbound":["*"]},{"service":"com.palm.app.kindle","inbound":["*"],"outbound":["*"]}]}'
echo "$PATCH" > /usr/share/ls2/roles/prv/com.palm.lunasend.json
echo "$PATCH" > /usr/share/ls2/roles/pub/com.palm.lunasend.json
sync
reboot
EOF

wait_for_device

# --- 3/6 push files ------------------------------------------------------

echo
echo "==> 3/6  Pushing tar of .palmkindle..."
novacom put file:///tmp/palmkindle.tar < "$IN_DIR/donor_palmkindle.tar"

echo "==> 4/6  Pushing Db8 chunks..."
chunk_count=0
for f in "$WORK_DIR"/chunks/chunk_*.json; do
    base=$(basename "$f")
    novacom put file:///tmp/$base < "$f"
    chunk_count=$((chunk_count + 1))
done
echo "    pushed $chunk_count chunks"

echo "==> 5/6  Pushing apply script..."
novacom put file:///tmp/apply_donor.sh < "$WORK_DIR/apply_donor.sh"

# --- 6/6 run the apply script -------------------------------------------

echo
echo "==> 6/6  Running apply script on target (this will reboot one more time)..."
echo "/bin/sh /tmp/apply_donor.sh" | run_sh

wait_for_device

# --- final verification --------------------------------------------------

echo
echo "==> Verifying installed state..."
run_sh <<'EOF' | sed 's/^/    /'
echo "/proc/nduid:        $(cat /proc/nduid)"
echo "jail /proc/nduid:   $(cat /var/palm/jail/com.palm.app.kindle/proc/nduid 2>/dev/null || echo '(jail not mounted yet)')"
echo "nduid mounts:"
mount | grep nduid | sed 's/^/    /'
echo "keymanager rows for com.palm.app.kindle:"
sqlite3 /var/palm/data/keys.db \
    "SELECT id||' '||keyID||' ('||length(data)||' bytes)' FROM keytable WHERE ownerID='com.palm.app.kindle';" \
    2>&1 | sed 's/^/    /'
echo "books in /media/internal/.palmkindle:"
ls /media/internal/.palmkindle/*.azw 2>/dev/null | wc -l | sed 's/^/    .azw files: /'
RESULT=$(luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/fetchKey \
    '{"keyname":"x"}' 2>&1)
if echo "$RESULT" | grep -q "Invalid permissions"; then
    echo "lunasend role: restored (impersonation blocked)"
else
    echo "WARNING: lunasend role may not be restored"
fi
EOF

echo
echo "===================="
echo "Target injection complete."
echo "===================="
echo
echo "Launch the Kindle app on the device. The library should populate from"
echo "the donor and downloaded books should open without DRM errors."
echo
echo "    Launch from here with:"
echo "        echo 'luna-send -P palm://com.palm.applicationManager/launch \\"
echo "                  \"{\\\"id\\\":\\\"com.palm.app.kindle\\\"}\"' | novacom -t run file:///bin/sh"
echo
echo "(novacom will report this device with the donor's NDUID from now on —"
echo " /proc/nduid is bind-mounted system-wide. Cosmetic only.)"
