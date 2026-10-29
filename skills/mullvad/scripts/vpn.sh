#!/usr/bin/env bash
# vpn.sh — Mullvad CLI helper.
#
# Thin wrapper around `mullvad`: read the tunnel state, classify why a request was
# refused, change the exit, prove the new address from outside, and put the
# previous settings back afterwards.
#
# `auto` treats a 429 like any other refusal: it retries once from another relay
# and gives up if the limit follows, rather than rotating indefinitely.
#
# Design rules:
#   * read-only by default; only `use`, `fresh`, `rotate`, `on`, `off`,
#     `restore` and `auto` mutate VPN state
#   * every mutating command snapshots the previous constraints once, so
#     `restore` can put the machine back where it started
#   * commands print `key: value` lines (or JSON with --json) on stdout and
#     human chatter on stderr
#
# Requires: mullvad (CLI), jq, curl

set -uo pipefail

MULLVAD_BIN="${MULLVAD_BIN:-mullvad}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mullvad-vpn"
SNAP="$STATE_DIR/constraints.snapshot"
JSON=0
mkdir -p "$STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------- output ----
say()  { printf '%s\n' "$*" >&2; }
kv()   { printf '%s: %s\n' "$1" "$2"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- install ----
install_hint() {
  case "$(uname -s)" in
    Darwin) say "  macOS:      brew install --cask mullvad-vpn" ;;
    Linux)
      if   have apt-get; then say "  Deb/Ubuntu: sudo apt install mullvad-vpn   (repo: https://repository.mullvad.net/deb/stable)"
      elif have dnf;     then say "  Fedora:     sudo dnf config-manager --add-repo https://repository.mullvad.net/rpm/stable/mullvad.repo && sudo dnf install mullvad-vpn"
      elif have pacman;  then say "  Arch:       sudo pacman -S mullvad-vpn"
      else                    say "  Linux:      https://mullvad.net/download/app/linux"
      fi ;;
    *) say "  Download:   https://mullvad.net/download" ;;
  esac
  say "  Then:       mullvad account login <account-number>"
}

require_mullvad() {
  command -v "$MULLVAD_BIN" >/dev/null 2>&1 && return 0
  if [ "$MULLVAD_BIN" = "mullvad" ] && [ -x "/Applications/Mullvad VPN.app/Contents/Resources/mullvad" ]; then
    say "the CLI exists inside the app but is not on PATH:"
    say "  export PATH=\"/Applications/Mullvad VPN.app/Contents/Resources:\$PATH\""
  fi
  say "error: the Mullvad CLI ('$MULLVAD_BIN') is not installed."
  install_hint
  exit 2
}

# --------------------------------------------------------------- helpers ----
need_daemon() {
  require_mullvad
  "$MULLVAD_BIN" status >/dev/null 2>&1 \
    || die "mullvad daemon unreachable — start the Mullvad app (or the mullvad-daemon service) and retry"
}

have() { command -v "$1" >/dev/null 2>&1; }
need_tools() {
  have jq   || die "jq is required (brew install jq)"
  have curl || die "curl is required"
}

status_json() { "$MULLVAD_BIN" status -j 2>/dev/null; }

current_ips() { # stdout: "<state> <relay> <ipv4>"
  status_json | jq -r '[.state, (.details.location.hostname // "-"), (.details.location.ipv4 // "-")] | join(" ")'
}

current_ip() { status_json | jq -r '.details.location.ipv4 // empty'; }

# The daemon reports the relay immediately but the exit IP a second or two
# later. Poll instead of trusting the first read.
wait_ip() {
  local i ip
  for i in $(seq 1 20); do
    ip="$(current_ip)"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    sleep 0.5
  done
  return 1
}

wait_connected() {
  local i state
  for i in $(seq 1 40); do
    state="$(status_json | jq -r '.state // empty')"
    [ "$state" = "connected" ] && { wait_ip >/dev/null; return 0; }
    sleep 0.5
  done
  return 1
}

constraints_location() {
  "$MULLVAD_BIN" relay get 2>/dev/null | awk -F': *' '/^ +Location:/{print $2; exit}'
}

# Snapshot the current relay constraints exactly once (the first time this
# skill changes them), so `restore` returns the machine to its original state.
snapshot_once() {
  [ -s "$SNAP" ] && return 0
  "$MULLVAD_BIN" relay get >"$SNAP" 2>/dev/null || true
}

restore_from_snapshot() {
  [ -s "$SNAP" ] || die "no snapshot to restore (nothing has been changed yet)"
  local loc host city cc
  loc="$(awk -F': *' '/^ +Location:/{print $2; exit}' "$SNAP")"
  host="$(printf '%s' "$loc" | sed -n 's/.*hostname \([^,]*\).*/\1/p')"
  if [ -n "$host" ]; then
    say "restoring pinned relay $host"
    "$MULLVAD_BIN" relay set location "$host" >/dev/null 2>&1 || return 1
  else
    case "$loc" in
      any*) say "restoring location: any"; "$MULLVAD_BIN" relay set location any >/dev/null 2>&1 ;;
      country\ *) cc="${loc#country }"; cc="${cc%%,*}"
        say "restoring location: country $cc"; "$MULLVAD_BIN" relay set location "$cc" >/dev/null 2>&1 ;;
      city\ *)
        # "city fra, de" -> de fra
        city="$(printf '%s' "$loc" | sed -n 's/^city \([^,]*\), *\([a-z][a-z]\).*/\1 \2/p')"
        if [ -n "$city" ]; then
          say "restoring location: ${city#* } ${city%% *}"
          "$MULLVAD_BIN" relay set location ${city#* } ${city%% *} >/dev/null 2>&1
        fi ;;
      *) say "could not parse snapshot location: $loc"; return 1 ;;
    esac
  fi
  wait_connected || return 1
}

# Parse `mullvad relay list` into "cc|City|city" triples.
relay_cities() {
  "$MULLVAD_BIN" relay list 2>/dev/null | awk '
    /^[A-Za-z].* \([a-z][a-z]\)$/ { cc=$0; sub(/.*\(/,"",cc); sub(/\).*/,"",cc); next }
    /^\t[A-Za-z].* \([a-z][a-z][a-z]\)/ {
      line=$0
      name=line; sub(/^\t/,"",name); sub(/ \([a-z][a-z][a-z]\).*/,"",name)
      code=line; sub(/.*\(/,"",code); sub(/\).*/,"",code)
      if (cc!="") print cc "|" name "|" code
    }'
}

relay_countries() {
  "$MULLVAD_BIN" relay list 2>/dev/null | awk '/^[A-Za-z].* \([a-z][a-z]\)$/ {
    cc=$0; sub(/.*\(/,"",cc); sub(/\).*/,"",cc);
    name=$0; sub(/ \([a-z][a-z]\)$/,"",name); print cc "|" name
  }'
}

rand_from() { awk 'BEGIN{srand()} {a[NR]=$0} END{if(NR>0) print a[1+int(rand()*NR)]}'; }

# --------------------------------------------------------------- probes -----
# Probe a URL through the current tunnel and classify the response.
# Sets P_STATUS P_CLASS P_HEADERS P_BODY_BYTES P_TITLE and P_REASON.
probe_url() {
  local url="$1" tmp="$STATE_DIR/probe.$$"
  local ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  P_STATUS="$(curl -sS -L --max-time 25 --compressed \
      -A "$ua" \
      -H 'Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8' \
      -H 'Accept-Language: en-US,en;q=0.9' \
      -D "$tmp.h" -o "$tmp.b" \
      -w '%{http_code}' "$url" 2>"$tmp.e")" || P_STATUS="000"
  P_HEADERS="$(tr -d '\r' <"$tmp.h" 2>/dev/null | sed -n 's/^\([A-Za-z0-9-]*\): .*/\1/p' | tr 'A-Z' 'a-z' | sort -u | paste -sd, -)"
  P_BODY_BYTES="$(wc -c <"$tmp.b" 2>/dev/null | tr -d ' ')"
  P_TITLE="$(tr -d '\000' <"$tmp.b" 2>/dev/null | tr '\n' ' ' | sed -n 's/.*<title[^>]*>\([^<]*\)<\/title>.*/\1/p' | cut -c1-120)"
  local body; body="$(tr -d '\000' <"$tmp.b" 2>/dev/null | tr '\n' ' ')"

  P_REASON=""
  case "$P_STATUS" in
    2*|3*) P_CLASS="ok" ;;
    000)   P_CLASS="network_error"; P_REASON="$(tr -d '\n' <"$tmp.e" 2>/dev/null | cut -c1-160)" ;;
    429)   P_CLASS="rate_limited" ;;
    451)   P_CLASS="legal_block" ;;
    407)   P_CLASS="proxy_auth" ;;
    403)
      if printf '%s' "$body" | grep -qiE 'error code: 1020'; then
        P_CLASS="cf_ip_firewall"; P_REASON="Cloudflare error 1020 — IP-level firewall rule"
      elif printf '%s' "$body" | grep -qiE 'just a moment|cf-chl|checking your browser|attention required|enable javascript and cookies'; then
        P_CLASS="bot_challenge"; P_REASON="Cloudflare/managed challenge"
      elif printf '%s' "$body" | grep -qiE 'datadome|px-captcha|captcha-delivery|perimeterx|_incapsula'; then
        P_CLASS="bot_challenge"; P_REASON="commercial bot management challenge"
      else
        P_CLASS="forbidden"; P_REASON="plain 403"
      fi ;;
    503)
      if printf '%s' "$body" | grep -qiE 'challenge|captcha|cf-chl'; then
        P_CLASS="bot_challenge"
      else
        P_CLASS="server_error"
      fi ;;
    5*) P_CLASS="server_error" ;;
    401) P_CLASS="unauthorized" ;;
    *)   P_CLASS="blocked_$P_STATUS" ;;
  esac
  # Geo hint: many services answer 200 with a "not available in your country" page.
  if [ "$P_CLASS" = "ok" ] && printf '%s' "$body" | grep -qiE 'not available in your (country|region)|geo.?block|unsupported region|wrong region'; then
    P_CLASS="geo_blocked"; P_REASON="200 but body says region unsupported"
  fi
  rm -f "$tmp" "$tmp.h" "$tmp.b" "$tmp.e"
  return 0
}

print_probe() {
  if [ "$JSON" = 1 ]; then
    jq -nc --arg s "$P_STATUS" --arg c "$P_CLASS" --arg r "$P_REASON" \
      --arg h "$P_HEADERS" --arg t "$P_TITLE" --arg b "$P_BODY_BYTES" \
      '{status:($s|tonumber? // 0), class:$c, reason:$r, title:$t, bytes:($b|tonumber? // 0), headers:($h|split(","))}'
  else
    kv status "$P_STATUS"
    kv class  "$P_CLASS"
    [ -n "$P_REASON" ] && kv reason "$P_REASON"
    [ -n "$P_TITLE" ]  && kv title  "$P_TITLE"
    kv bytes  "$P_BODY_BYTES"
  fi
}

is_blocked_class() {
  case "$1" in
    ok) return 1 ;;
    network_error) return 1 ;;     # not a target block; caller decides
    *) return 0 ;;
  esac
}

# -------------------------------------------------------------- commands ----
cmd_state() {
  need_tools; need_daemon
  local st relay ip country city loc
  st="$(status_json)"
  relay="$(jq -r '.details.location.hostname // "-"' <<<"$st")"
  ip="$(jq -r '.details.location.ipv4 // "-"' <<<"$st")"
  country="$(jq -r '.details.location.country // "-"' <<<"$st")"
  city="$(jq -r '.details.location.city // "-"' <<<"$st")"
  loc="$(constraints_location)"
  if [ "$JSON" = 1 ]; then
    jq -nc --arg s "$(jq -r .state <<<"$st")" --arg r "$relay" --arg i "$ip" \
      --arg c "$country" --arg y "$city" --arg l "$loc" \
      '{state:$s, relay:$r, exit_ip:$i, country:$c, city:$y, constraints:$l}'
  else
    kv state       "$(jq -r .state <<<"$st")"
    kv relay       "$relay"
    kv exit_ip     "$ip"
    kv location    "$country, $city"
    kv constraints "${loc:-unknown}"
  fi
}

cmd_verify() {
  need_tools; need_daemon
  local out
  out="$(curl -sS --max-time 15 https://am.i.mullvad.net/json 2>/dev/null)" \
    || die "could not reach am.i.mullvad.net (tunnel down?)"
  if [ "$JSON" = 1 ]; then printf '%s\n' "$out" | jq -c '{ip, mullvad_exit_ip, country, city, organization}'; return; fi
  kv exit_ip "$(jq -r '.ip // "?"' <<<"$out")"
  kv mullvad_exit_ip "$(jq -r '.mullvad_exit_ip // false' <<<"$out")"
  kv country "$(jq -r '.country // "?"' <<<"$out")"
  kv city    "$(jq -r '.city // "?"' <<<"$out")"
  [ "$(jq -r '.mullvad_exit_ip // false' <<<"$out")" = "true" ] \
    || say "WARNING: traffic is NOT leaving through a Mullvad exit — check lockdown/DNS"
}

cmd_use() {
  # vpn use <cc|hostname> [city] [hostname]
  need_tools; need_daemon
  [ $# -ge 1 ] || die "usage: vpn use <country> [city] [hostname]  |  vpn use any"
  snapshot_once
  say "setting location: $*"
  "$MULLVAD_BIN" relay set location "$@" || die "relay set location failed (try: mullvad relay update)"
  wait_connected || die "did not reach connected state within ~20s (mullvad status -v)"
  cmd_state
}

cmd_rotate() {
  # Re-select a relay inside the current constraints. Same country, new IP.
  need_tools; need_daemon
  local before_ip before_relay ip relay tries=0
  read -r _ before_relay before_ip <<<"$(current_ips)"
  say "before: $before_relay ($before_ip)"
  while [ "$tries" -lt 3 ]; do
    tries=$((tries+1))
    "$MULLVAD_BIN" reconnect --wait >/dev/null 2>&1 || true
    wait_connected || true
    ip="$(wait_ip || true)"
    relay="$(status_json | jq -r '.details.location.hostname // "-"')"
    if [ -n "${ip:-}" ] && [ "$ip" != "$before_ip" ]; then
      kv relay "$relay"; kv exit_ip "$ip"; kv changed "true"; kv attempts "$tries"
      return 0
    fi
    say "relay unchanged ($relay), retrying ($tries/3)"
    sleep 1
  done
  kv relay "$(status_json | jq -r '.details.location.hostname // "-"')"
  kv exit_ip "${ip:--}"
  kv changed "false"
  say "reconnect kept the same relay — use 'vpn fresh' to pick a different city/host"
  return 2
}

cmd_fresh() {
  # Move to a different city (default: same country) to force a new IP block.
  need_tools; need_daemon
  local cc="${1:-}" current_cc entry city
  current_cc="$(status_json | jq -r '.details.location.country_code // empty')"
  [ -n "$current_cc" ] || current_cc="$(printf '%s' "$(constraints_location)" | sed -n 's/.*city [a-z]*, \([a-z][a-z]\).*/\1/p')"
  [ -n "$cc" ] || cc="$current_cc"
  [ -n "$cc" ] || die "could not determine current country; pass one: vpn fresh de"
  entry="$(relay_cities | awk -F'|' -v cc="$cc" '$1==cc' | rand_from)"
  [ -n "$entry" ] || die "no cities found for country '$cc' (mullvad relay list)"
  city="$(cut -d'|' -f3 <<<"$entry")"
  say "picking random city in $cc: $(cut -d'|' -f2 <<<"$entry") ($city)"
  snapshot_once
  "$MULLVAD_BIN" relay set location "$cc" "$city" >/dev/null || die "relay set location failed"
  wait_connected || die "did not reach connected state"
  cmd_state
}

cmd_auto() {
  # vpn auto <url> [attempts] — change the exit once (twice at most) and re-probe.
  # Purpose: decide whether a block is exit-specific (measurement error) or a
  # target control (record it as a limitation and move on).
  need_tools; need_daemon
  local url="${1:-}" max="${2:-2}" attempt=1 cc
  [ -n "$url" ] || die "usage: vpn auto <url> [attempts]"
  cc="$(status_json | jq -r '.details.location.country_code // empty')"

  probe_url "$url"
  say "attempt 1: $(current_ip || echo '?') -> $P_STATUS $P_CLASS"
  case "$P_CLASS" in
    ok|network_error)
      kv action "none"; print_probe; return 0 ;;
    rate_limited)
      say "rate limited — trying one other relay before giving up" ;;
  esac

  while [ "$attempt" -lt "$max" ]; do
    attempt=$((attempt+1))
    if [ "$attempt" -eq 2 ]; then
      say "attempt $attempt: rotating relay inside current location"
      cmd_rotate >/dev/null 2>&1 || cmd_fresh "$cc" >/dev/null 2>&1 || true
    else
      say "attempt $attempt: switching to another city in $cc"
      cmd_fresh "$cc" >/dev/null 2>&1 || true
    fi
    sleep 1
    probe_url "$url"
    say "attempt $attempt: $(current_ip || echo '?') -> $P_STATUS $P_CLASS"
    if ! is_blocked_class "$P_CLASS"; then
      kv action "exit_specific"; kv attempts "$attempt"; print_probe
      say "the exit was the difference — record the before/after exit"
      return 0
    fi
  done
  if [ "$P_CLASS" = "rate_limited" ]; then
    kv action "rate_limited"; kv attempts "$attempt"; print_probe
    say "still 429 from a second relay — giving up; back off and retry later"
    return 3
  fi
  kv action "still_blocked"; kv attempts "$attempt"; print_probe
  say "persistent across exits — treat as a target control, record the limitation, do not keep rotating"
  return 1
}

cmd_on()  { need_tools; need_daemon; "$MULLVAD_BIN" connect --wait; cmd_state; }
cmd_off() {
  need_daemon
  local lock; lock="$("$MULLVAD_BIN" lockdown-mode get 2>/dev/null | awk -F': ' '/Block traffic/{print $2}')"
  if [ "$lock" = "on" ]; then
    say "NOTE: lockdown mode is ON — all traffic will be blocked after disconnecting"
  fi
  "$MULLVAD_BIN" disconnect --wait
  kv state "$(status_json | jq -r .state)"
}

cmd_installed() {
  if command -v "$MULLVAD_BIN" >/dev/null 2>&1; then
    kv cli "$(command -v "$MULLVAD_BIN")"
    kv version "$("$MULLVAD_BIN" --version 2>/dev/null | awk '{print $2}')"
    return 0
  fi
  kv cli "not found"
  say "the Mullvad CLI ('$MULLVAD_BIN') is not installed."
  install_hint
  return 2
}

cmd_restore() {
  need_tools; need_daemon
  restore_from_snapshot || die "restore failed; current constraints: $(constraints_location)"
  say "restored from $SNAP"
  cmd_state
}

cmd_relays() {
  # vpn.sh relays [cc] — list countries, or the cities in one country
  require_mullvad
  local cc="${1:-}"
  if [ -z "$cc" ]; then relay_countries | awk -F'|' '{printf "%s (%s)\n", $2, $1}' | head -80
  else relay_cities | awk -F'|' -v cc="$cc" '$1==cc {printf "%s (%s)\n", $2, $3}'; fi
}

cmd_doctor() {
  need_tools
  require_mullvad
  kv cli_version "$("$MULLVAD_BIN" --version 2>/dev/null | awk '{print $2}')"
  if ! "$MULLVAD_BIN" status >/dev/null 2>&1; then kv daemon "unreachable"; return 1; fi
  kv daemon "ok"
  kv state "$(status_json | jq -r .state)"
  kv exit_ip "$(current_ip || echo '-')"
  kv relay "$(status_json | jq -r '.details.location.hostname // "-"')"
  kv constraints "$(constraints_location)"
  local acct exp; acct="$("$MULLVAD_BIN" account get 2>/dev/null)"
  kv account "$(printf '%s' "$acct" | awk -F': +' '/Mullvad account/{print $2}')"
  exp="$(printf '%s' "$acct" | awk -F': +' '/Expires at/{print $2}')"
  kv account_expires "$exp"
  kv api_access "$("$MULLVAD_BIN" api-access get 2>/dev/null | tail -1)"
  kv lockdown "$("$MULLVAD_BIN" lockdown-mode get 2>/dev/null | awk -F': ' '{print $2}')"
  kv anti_censorship "$("$MULLVAD_BIN" anti-censorship get 2>/dev/null | head -1 | sed 's/^mode: *//')"
  local exp_epoch
  exp_epoch="$(date -j -f '%Y-%m-%d' "${exp%% *}" +%s 2>/dev/null || date -d "${exp%% *}" +%s 2>/dev/null || true)"
  if [ -n "$exp_epoch" ]; then
    if [ "$exp_epoch" -lt "$(date +%s)" ]; then
      kv account_valid "false"; say "account expired — nothing will connect until it is topped up"
    else kv account_valid "true"; fi
  fi
}

usage() {
  cat <<'EOF'
vpn.sh — change this machine's Mullvad exit location, then prove it

  vpn.sh state [--json]              VPN state, relay, exit IP, constraints
  vpn.sh verify [--json]             confirm exit IP via am.i.mullvad.net
  vpn.sh ip                          print current exit IPv4
  vpn.sh relays [cc]                 list countries, or cities in a country
  vpn.sh installed                   is the Mullvad CLI installed? exit 2 if not
  vpn.sh doctor                      install/daemon/account/API/lockdown health check

  vpn.sh use <cc> [city] [host]      set location (e.g. use de, use us nyc, use jp-tyo-wg-001)
  vpn.sh use any                     drop location constraint
  vpn.sh rotate                      re-pick a relay inside current constraints
  vpn.sh fresh [cc]                  jump to a random city (default: current country)
  vpn.sh auto <url> [attempts]       change exit once and re-probe: exit-specific or a real block?
  vpn.sh on | off                    connect / disconnect
  vpn.sh restore                     put back the constraints from before the first change

  vpn.sh probe <url>                 classify a response: ok / bot_challenge / rate_limited / ...
  --json is accepted by state, verify, probe, auto and doctor
EOF
}

# ------------------------------------------------------------------ main ----
main() {
  local cmd="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) JSON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) if [ -z "$cmd" ]; then cmd="$1"; else args+=("$1"); fi; shift ;;
    esac
  done
  case "${cmd:-state}" in
    state)   cmd_state ;;
    status)  need_daemon; status_json | jq . ;;
    ip)      need_daemon; ip="$(wait_ip || true)"; printf '%s\n' "${ip:--}" ;;
    verify)  cmd_verify ;;
    installed) cmd_installed ;;
    relays)  cmd_relays ${args[@]+"${args[@]}"} ;;
    doctor)  cmd_doctor ;;
    use)     cmd_use ${args[@]+"${args[@]}"} ;;
    rotate)  cmd_rotate ;;
    fresh)   cmd_fresh ${args[@]+"${args[@]}"} ;;
    auto)    cmd_auto ${args[@]+"${args[@]}"} ;;
    on)      cmd_on ;;
    off)     cmd_off ;;
    restore) cmd_restore ;;
    probe)   need_tools; [ -n "${args[0]:-}" ] || die "usage: vpn probe <url>"; probe_url "${args[0]}"; print_probe; is_blocked_class "$P_CLASS" && exit 1 || exit 0 ;;
    *)       usage; exit 1 ;;
  esac
}

main "$@"
