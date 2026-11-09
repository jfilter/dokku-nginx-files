#!/usr/bin/env bash
# Runs the commands file against a temporary DOKKU_ROOT with dokku and sudo stubbed.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap '/bin/rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/core/common" "$work/root/app" "$work/cache"
sed "s#^readonly ROOT=.*#readonly ROOT=$work/cache#" "$here/cache-helper" >"$work/helper"
export WORK="$work" DOKKU_ROOT="$work/root" PLUGIN_CORE_AVAILABLE_PATH="$work/core" DOKKU_NOT_IMPLEMENTED_EXIT=10 LOG="$work/log"
export PATH="$work/bin:$PATH" DOKKU_TRACE=""

cat >"$work/core/common/functions" <<'STUB'
dokku_log_fail() { echo "$*" >&2; exit 1; }
verify_app_name() { [[ -d "$DOKKU_ROOT/$1" ]] || dokku_log_fail "App $1 does not exist"; }
STUB
cat >"$work/bin/dokku" <<'STUB'
#!/usr/bin/env bash
echo "dokku $*" >>"$LOG"
[[ ! -e "$DOKKU_ROOT/reject" ]]
STUB
cat >"$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
[[ ! -e "$WORK/deny" ]] || exit 1
shift 2
exec bash "$WORK/helper" "$@"
STUB
cat >"$work/bin/install" <<'STUB'
#!/usr/bin/env bash
echo "install $*" >>"$LOG"
/bin/mkdir -p "${@: -1}"
STUB
cat >"$work/bin/flock" <<'STUB'
#!/usr/bin/env bash
echo "flock $*" >>"$LOG"
STUB
cat >"$work/bin/base64" <<'STUB'
#!/usr/bin/env bash
if [[ ${1:-} == "-w0" ]]; then /usr/bin/base64 <"$2" | tr -d '\n'; exit; fi
if [[ ${1:-} == "-d" ]]; then exec /usr/bin/base64 -D; fi
exec /usr/bin/base64 "$@"
STUB
command -v /usr/bin/base64 >/dev/null || exit 1
[[ $(uname) == Darwin ]] || /bin/rm -f "$work/bin/base64"
chmod +x "$work/bin/"*

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
want() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
run() { bash "$here/commands" "$@"; }

b64() { printf '%s' "$1" | /usr/bin/base64 | tr -d '\n'; }
file="$DOKKU_ROOT/app/nginx.conf.d/a.conf"

run nginx-files:snippet-set app a.conf "$(b64 'one;')"; want "set exits 0" $? 0
want "set writes the content" "$(cat "$file")" "one;"
want "set reloads nginx" "$(tail -1 "$LOG")" "dokku nginx:reload"
want "get returns base64" "$(run nginx-files:snippet-get app a.conf)" "$(b64 'one;')"

touch "$DOKKU_ROOT/reject"
run nginx-files:snippet-set app a.conf "$(b64 'broken')" 2>/dev/null; want "rejected update fails" $? 1
want "rejected update restores" "$(cat "$file")" "one;"
run nginx-files:snippet-set app b.conf "$(b64 'broken')" 2>/dev/null; want "rejected create fails" $? 1
run nginx-files:snippet-unset app a.conf 2>/dev/null; want "rejected removal fails" $? 1
want "rejected removal restores" "$(cat "$file")" "one;"
want "rejected create leaves no file" "$(find "$DOKKU_ROOT/app/nginx.conf.d" -mindepth 1 -exec basename {} \;)" "a.conf"
/bin/rm -f "$DOKKU_ROOT/reject"

run nginx-files:snippet-get app b.conf >/dev/null 2>&1; want "get of an absent snippet exits 20" $? 20
for name in ../evil.conf .hidden.conf a.txt 'a b.conf' a/b.conf; do
  run nginx-files:snippet-set app "$name" "$(b64 x)" 2>/dev/null; want "rejects name $name" $? 1
done
run nginx-files:snippet-set nope a.conf "$(b64 x)" 2>/dev/null; want "rejects an unknown app" $? 1
run nginx-files:snippet-unset app a.conf; want "unset exits 0" $? 0
want "unset removes the file" "$([[ -e $file ]] && echo yes || echo no)" no
log_lines=$(wc -l <"$LOG")
run nginx-files:snippet-unset app a.conf; want "unset of an absent snippet exits 0" $? 0
want "unset of an absent snippet does not reload" "$(tail -n +$((log_lines + 1)) "$LOG" | grep -c nginx:reload)" 0

run nginx-files:cache-ensure site; want "cache-ensure exits 0" $? 0
want "cache-ensure sets group and mode" "$(tail -1 "$LOG")" "install -d -g www-data -m 2770 $work/cache/site"
run nginx-files:cache-exists site; want "cache-exists finds a directory" $? 0
run nginx-files:cache-exists missing; want "cache-exists exits 20 when absent" $? 20
touch "$work/deny"
run nginx-files:cache-exists site; want "a sudo failure is not an absent directory" $? 1
/bin/rm -f "$work/deny"
ln -s /etc "$work/cache/link"
run nginx-files:cache-ensure link 2>/dev/null; want "refuses a symbolic link" $? 2
for name in .. ../etc a/b .hidden 'a b'; do
  run nginx-files:cache-ensure "$name" 2>/dev/null; want "rejects cache name $name" $? 2
done
want "snippet changes take the lock" "$(grep -c '^flock 9' "$LOG")" 6
run nginx-files:cache-ensure 2>/dev/null; want "rejects a missing argument" $? 1
run some:other 2>/dev/null; want "leaves other commands to dokku" $? 10
if [[ $fails -ne 0 ]]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
