#!/usr/bin/env bash
# Container side of integration.sh. Only Dokku's dispatcher and common functions are stand-ins.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq nginx sudo curl >/dev/null 2>&1 || { echo "apt failed"; exit 1; }

useradd -m -d /home/dokku -U dokku
plugin=/var/lib/dokku/plugins/available/nginx-files
core=/var/lib/dokku/core-plugins/available
mkdir -p "$plugin" "$core/common" /home/dokku/app
cp /plugin/commands /plugin/install /plugin/cache-helper "$plugin/"
chown -R dokku:dokku /home/dokku
install -d -o www-data -g www-data -m 2770 /var/cache/nginx

cat >"$core/common/functions" <<'STUB'
dokku_log_fail() { echo "$*" >&2; exit 1; }
verify_app_name() { [[ -d "$DOKKU_ROOT/$1" ]] || dokku_log_fail "App $1 does not exist"; }
STUB
cat >/usr/local/bin/dokku <<STUB
#!/usr/bin/env bash
if [[ \$1 == nginx:reload ]]; then
  sudo -n /usr/sbin/nginx -t 2>/dev/null && sudo -n /usr/sbin/nginx -s reload
  exit
fi
exec bash $plugin/commands "\$@"
STUB
chmod +x /usr/local/bin/dokku
echo '%dokku ALL=(ALL) NOPASSWD:/usr/sbin/nginx' >/etc/sudoers.d/dokku-nginx
chmod 0440 /etc/sudoers.d/dokku-nginx

cat >/etc/nginx/sites-enabled/default <<'CONF'
server {
  listen 8080;
  include /home/dokku/app/nginx.conf.d/*.conf;
}
CONF
nginx || { echo "nginx did not start"; exit 1; }

fails=0
want() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fails=$((fails + 1)); fi; }
as_dokku() {
  sudo -u dokku env DOKKU_ROOT=/home/dokku PLUGIN_CORE_AVAILABLE_PATH="$core" DOKKU_NOT_IMPLEMENTED_EXIT=10 DOKKU_TRACE= PATH="$PATH" "$@"
}
d() { as_dokku dokku "$@"; }
b64() { printf '%s' "$1" | base64 -w0; }
get() {
  sleep 0.3
  curl -s "http://127.0.0.1:8080$1"
}
snippet() { printf 'location = /%s { return 200 "%s"; }' "$1" "$2"; }
dir=/home/dokku/app/nginx.conf.d

bash "$plugin/install"; want "install exits 0" $? 0
bash "$plugin/install"; want "install runs again" $? 0
want "helper is root-owned" "$(stat -c '%U %a' /usr/local/libexec/dokku-nginx-files-cache)" "root 755"
want "sudoers file mode" "$(stat -c '%U %a' /etc/sudoers.d/dokku-nginx-files)" "root 440"
visudo -c >/dev/null; want "sudoers stays valid" $? 0

d nginx-files:snippet-set app a.conf "$(b64 "$(snippet a one)")" >/dev/null 2>&1; want "set exits 0" $? 0
want "nginx serves the snippet" "$(get /a)" one
want "get returns the content" "$(d nginx-files:snippet-get app a.conf | base64 -d)" "$(snippet a one)"
d nginx-files:snippet-set app a.conf "$(b64 "$(snippet a two)")" >/dev/null 2>&1
want "nginx serves the update" "$(get /a)" two

d nginx-files:snippet-set app a.conf "$(b64 'location {')" >/dev/null 2>&1; want "broken update fails" $? 1
want "broken update restores the file" "$(cat "$dir/a.conf")" "$(snippet a two)"
want "nginx keeps serving" "$(get /a)" two
nginx -t >/dev/null 2>&1; want "config stays valid after a broken update" $? 0
d nginx-files:snippet-set app b.conf "$(b64 'location {')" >/dev/null 2>&1; want "broken create fails" $? 1
want "broken create leaves no file" "$([[ -e $dir/b.conf ]] && echo yes || echo no)" no

d nginx-files:snippet-set app def.conf "$(b64 'set $myvar defined;')" >/dev/null 2>&1
d nginx-files:snippet-set app use.conf "$(b64 'location = /v { return 200 $myvar; }')" >/dev/null 2>&1; want "dependent snippet is accepted" $? 0
want "dependent snippet works" "$(get /v)" defined
d nginx-files:snippet-unset app def.conf >/dev/null 2>&1; want "removal nginx rejects fails" $? 1
want "rejected removal restores the file" "$([[ -e $dir/def.conf ]] && echo yes || echo no)" yes
d nginx-files:snippet-unset app use.conf >/dev/null 2>&1; want "unset exits 0" $? 0
d nginx-files:snippet-unset app def.conf >/dev/null 2>&1; want "unset of the now free snippet exits 0" $? 0
want "unset removes it from nginx" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/v)" 404
d nginx-files:snippet-get app use.conf >/dev/null 2>&1; want "get of an absent snippet exits 20" $? 20

for i in 1 2 3 4 5 6; do
  if ((i % 2)); then content=$(snippet "p$i" ok); else content='location {'; fi
  d nginx-files:snippet-set app "p$i.conf" "$(b64 "$content")" >/dev/null 2>&1 &
done
wait
nginx -t >/dev/null 2>&1; want "parallel writes leave a valid config" $? 0
want "only the valid parallel snippets stay" "$(cd "$dir" && echo p*.conf)" "p1.conf p3.conf p5.conf"
want "no temporary files stay" "$(find "$dir" -name '.*' | wc -l)" 0

d nginx-files:cache-ensure site; want "cache-ensure exits 0" $? 0
want "cache directory group and mode" "$(stat -c '%G %a' /var/cache/nginx/site)" "www-data 2770"
chown nobody /var/cache/nginx/site
d nginx-files:cache-ensure site; want "cache-ensure runs again" $? 0
want "group write survives the owner change" "$(sudo -u www-data sh -c 'touch /var/cache/nginx/site/f && echo yes')" yes
d nginx-files:cache-exists site; want "cache-exists finds it" $? 0
d nginx-files:cache-exists missing; want "cache-exists exits 20 when absent" $? 20
d nginx-files:cache-ensure ../../../etc/evil 2>/dev/null; want "helper rejects a path" $? 2
want "nothing appears outside the cache root" "$([[ -e /etc/evil ]] && echo yes || echo no)" no
ln -s /etc /var/cache/nginx/link
d nginx-files:cache-ensure link 2>/dev/null; want "helper refuses a symbolic link" $? 2
as_dokku sudo -n /usr/bin/install -d /etc/evil 2>/dev/null; want "sudo allows nothing but the helper" $? 1
mv /etc/sudoers.d/dokku-nginx-files /root/held
d nginx-files:cache-exists site 2>/dev/null; want "a missing sudo rule is not an absent directory" $? 1
mv /root/held /etc/sudoers.d/dokku-nginx-files

if [[ $fails -ne 0 ]]; then
  echo "$fails failed"
  exit 1
fi
echo "all passed"
