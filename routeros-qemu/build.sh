#!/usr/bin/env bash
# Embed routeros.sh into plugin.src.js and emit one plug-in per variant.
# The manager script travels inside the plug-in (not the resource package) so
# "仅更新脚本" can fix the backend without a re-download.
#
# Both variants come from the SAME source, so a UI change lands in both.
#
#   ./build.sh            build every variant
#   ./build.sh --force    overwrite outputs even if they were edited by hand
set -euo pipefail
cd "$(dirname "$0")"

SRC=plugin.src.js
BACKEND=routeros.sh
SNAPDIR=.snapshots
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
[ -f "$BACKEND" ] || { echo "missing $BACKEND" >&2; exit 1; }

sh -n "$BACKEND" || { echo "$BACKEND has a syntax error" >&2; exit 1; }

# base64 without line wrapping: GNU uses -w0, BSD/macOS does not wrap unless
# asked, so strip newlines either way.
B64="$(base64 < "$BACKEND" | tr -d '\n')"

mkdir -p "$SNAPDIR"
# Keep a copy of the source every build, so a clobbered hand-edit is always
# recoverable (this has bitten us once already).
cp "$SRC" "$SNAPDIR/plugin.src.js.$(date +%Y%m%d-%H%M%S)"

build_one() {
  variant="$1"
  out="$2"
  python3 - "$SRC" "$out" "$B64" "$variant" "$FORCE" <<'PY'
import sys, io, os, hashlib
src, out, b64, variant, force = sys.argv[1:6]
text = io.open(src, encoding='utf-8').read()
for token in ("'__MANAGER_B64__'", "'__VARIANT__'"):
    if token not in text:
        raise SystemExit('placeholder %s not found in %s' % (token, src))
built = text.replace("'__MANAGER_B64__'", "'" + b64 + "'") \
            .replace("'__VARIANT__'", "'" + variant + "'")

# Refuse to overwrite an output that no longer matches its recorded build:
# that means somebody edited the generated file directly and would lose it.
stamp = out + '.buildhash'
if os.path.exists(out) and not int(force):
    cur = hashlib.sha256(io.open(out, 'rb').read()).hexdigest()
    prev = io.open(stamp).read().strip() if os.path.exists(stamp) else None
    if prev is not None and cur != prev:
        raise SystemExit(
            'REFUSING to overwrite %s: it was modified after the last build.\n'
            '  Port the change into %s, or re-run with --force to discard it.'
            % (out, src))

io.open(out, 'w', encoding='utf-8').write(built)
io.open(stamp, 'w').write(hashlib.sha256(built.encode('utf-8')).hexdigest())
print('  %-8s -> %s (%d bytes)' % (variant, os.path.basename(out), os.path.getsize(out)))
PY
  node --check "$out" 2>/dev/null && echo "           js syntax ok" \
    || echo "           note: node unavailable, syntax check skipped"
}

echo "building from $SRC (backend $BACKEND, ${#B64} b64 chars)"
build_one generic "../【通用版UFI专用】RouterOS虚拟机管理(QEMU).js"
build_one zte     "../【中兴UFI后台专用】RouterOS虚拟机管理(QEMU).js"
