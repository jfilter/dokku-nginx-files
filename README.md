# dokku-nginx-files

A Dokku plugin that exposes two host file operations as `dokku` commands, so they can be
driven over Dokku's SSH interface without a root shell:

- snippets in an app's `nginx.conf.d`, which nginx includes in the app's server block
- directories under `/var/cache/nginx` for a `proxy_cache_path`

## Install

```sh
sudo dokku plugin:install https://github.com/jfilter/dokku-nginx-files.git --name nginx-files
```

The install trigger copies a root-owned helper to `/usr/local/libexec` and adds
`/etc/sudoers.d/dokku-nginx-files`, which lets the `dokku` group run only that helper. The
helper accepts a single directory name under `/var/cache/nginx`.

## Commands

| Command | Effect |
|---|---|
| `nginx-files:snippet-set <app> <name>.conf <base64>` | Writes the snippet and reloads nginx |
| `nginx-files:snippet-get <app> <name>.conf` | Prints the snippet as base64 |
| `nginx-files:snippet-unset <app> <name>.conf` | Removes the snippet and reloads nginx |
| `nginx-files:cache-ensure <name>` | Creates the directory, group `www-data`, mode `2770` |
| `nginx-files:cache-exists <name>` | Reports whether the directory exists |

`snippet-get` and `cache-exists` exit 20 when the object does not exist. Snippet content
travels as base64 because a Dokku command takes it as a single argument.

When nginx rejects a snippet, `snippet-set` puts the previous file back, or removes the new
one, and exits non-zero; `snippet-unset` restores a removal nginx rejects. Names are limited to letters, digits, `.`, `_` and `-`, with no
leading dot, so neither command can leave its directory.

Cache directories are never removed: nothing in them is worth a root rule for deletion.

## Test

```sh
test/run.sh
```

The test runs `commands` against a temporary `DOKKU_ROOT` with `dokku` and `sudo` stubbed.
