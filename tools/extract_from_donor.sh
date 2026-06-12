#!/bin/bash
# extract_from_donor.sh
#
# Pull credentials, library state, and book files from a logged-in
# webOS Kindle Beta install. Drives the donor TouchPad over novacom.
#
# Usage:
#     ./extract_from_donor.sh [output-dir]
#
# Output: a directory containing everything inject_to_target.sh needs:
#     token.raw private_key.raw user_name.raw device_name.raw
#     serial_number.raw drm_configuration.raw donor_nduid.txt
#     donor_books.full donor_collections.full donor_configdata.full
#     donor_annotations.full donor_readingpositions.full
#     donor_palmkindle.tar
#
# Only one TouchPad may be connected. The script reboots the donor twice
# (once to apply a temporary role patch, once to restore it cleanly).

set -euo pipefail

OUT_DIR="${1:-./donor-backup-$(date +%Y%m%d-%H%M%S)}"

if ! command -v novacom >/dev/null 2>&1; then
    echo "Error: novacom not found in PATH" >&2
    exit 1
fi

run_sh() {
    # /bin/sh on the device. -t = interactive (returns child's exit status).
    novacom -t run file:///bin/sh "$@"
}

require_one_device() {
    local list count
    list=$(novacom -l 2>&1 | grep topaz || true)
    count=$(printf '%s\n' "$list" | grep -c topaz || true)
    if [[ $count -eq 0 ]]; then
        echo "Error: no topaz device connected over novacom" >&2
        exit 1
    elif [[ $count -gt 1 ]]; then
        echo "Error: multiple devices connected; unplug all but the donor" >&2
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

apply_role_patch() {
    run_sh <<'EOF'
mkdir -p /media/internal/.kindle-keys-bak
# Only ever back up real stock files (never overwrite an existing backup
# with our own patched version on a re-run).
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
}

restore_role() {
    run_sh <<'EOF'
cp /media/internal/.kindle-keys-bak/lunasend.prv.orig \
    /usr/share/ls2/roles/prv/com.palm.lunasend.json
cp /media/internal/.kindle-keys-bak/lunasend.pub.orig \
    /usr/share/ls2/roles/pub/com.palm.lunasend.json
sync
reboot
EOF
}

# --- main ---------------------------------------------------------------

echo "===================="
echo "Donor extraction"
echo "===================="
echo
echo "Detected device:"
require_one_device
echo
echo "Donor identity:"
run_sh <<'EOF' | sed 's/^/  /'
echo "hostname: $(hostname)"
echo "nduid:    $(cat /proc/nduid)"
echo "uptime:   $(uptime | sed 's/^ *//')"
EOF

echo
read -p "This will REBOOT the donor TWICE. Continue? [y/N] " ans
[[ $ans =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

mkdir -p "$OUT_DIR"
echo "Output directory: $OUT_DIR"

echo
echo "==> 1/5  Applying temporary impersonation role patch and rebooting..."
apply_role_patch
wait_for_device

echo
echo "==> 2/5  Extracting keymanager values..."
run_sh <<'EOF'
mkdir -p /tmp/kx
for k in token private_key user_name device_name serial_number drm_configuration; do
    luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/fetchKey \
        "{\"keyname\":\"$k\"}" > /tmp/kx/$k.raw 2>&1
done
EOF

for f in token private_key user_name device_name serial_number drm_configuration; do
    novacom get file:///tmp/kx/$f.raw > "$OUT_DIR/$f.raw"
    bytes=$(wc -c < "$OUT_DIR/$f.raw" | tr -d ' ')
    echo "    $f.raw  ($bytes bytes)"
done

echo
echo "==> 3/5  Extracting Db8 kinds..."
run_sh <<'EOF'
for kind in books collections configdata annotations readingpositions; do
    luna-send -t 1 -m com.palm.app.kindle palm://com.palm.db/find \
        "{\"query\":{\"from\":\"com.palm.kindle.${kind}:1\"}}" \
        > /tmp/donor_${kind}.full 2>&1
done
EOF

for f in books collections configdata annotations readingpositions; do
    novacom get file:///tmp/donor_$f.full > "$OUT_DIR/donor_$f.full"
    bytes=$(wc -c < "$OUT_DIR/donor_$f.full" | tr -d ' ')
    echo "    donor_$f.full  ($bytes bytes)"
done

echo
echo "==> 4/5  Tarring /media/internal/.palmkindle..."
run_sh <<'EOF' >/dev/null
cd /media/internal && tar cf /tmp/palmkindle.tar .palmkindle
EOF
novacom get file:///tmp/palmkindle.tar > "$OUT_DIR/donor_palmkindle.tar"
echo "    donor_palmkindle.tar  ($(wc -c < "$OUT_DIR/donor_palmkindle.tar" | tr -d ' ') bytes)"

echo
echo "==> Reading donor NDUID..."
echo "cat /proc/nduid" | run_sh | tr -d '\r\n' > "$OUT_DIR/donor_nduid.txt"
echo "" >> "$OUT_DIR/donor_nduid.txt"
DONOR_NDUID=$(cat "$OUT_DIR/donor_nduid.txt" | tr -d '[:space:]')
echo "    donor NDUID: $DONOR_NDUID"

echo
echo "==> 5/5  Restoring lunasend role and rebooting..."
restore_role
wait_for_device

echo
echo "Verifying impersonation is now blocked..."
RESULT=$(run_sh <<'EOF'
luna-send -t 1 -m com.palm.app.kindle palm://com.palm.keymanager/fetchKey \
    '{"keyname":"x"}' 2>&1
EOF
)
if echo "$RESULT" | grep -q "Invalid permissions"; then
    echo "    OK: anonymous impersonation blocked"
else
    echo "    WARNING: impersonation appears to still work."
    echo "    Verify /usr/share/ls2/roles/prv/com.palm.lunasend.json by hand."
fi

echo
echo "===================="
echo "Donor extraction complete."
echo "===================="
echo "Output: $OUT_DIR"
echo
echo "Next: disconnect this device, connect the target, and run:"
echo "    ./inject_to_target.sh \"$OUT_DIR\""
