---
name: mullvad
description: Changes this machine's public IP through Mullvad — rotate the relay, pick a country or city, verify the new exit, and restore the previous settings. Use when a site or API blocks, geo-restricts or challenges the current address, when you need to browse from a specific country, or when the Mullvad API or WireGuard port is unreachable on the current network.
sources: community
---

# Change the public IP with Mullvad

`scripts/vpn.sh` wraps the `mullvad` CLI: it reads the tunnel state, classifies
why a request was refused, changes the exit relay, proves the new address from
outside, and can put the old settings back.

Set `SKILL_DIR` to this skill's directory (the folder holding this file), then
run the helper:

```sh
SKILL_DIR="$HOME/.config/opencode/skills/mullvad"   # adjust to where it is installed
"$SKILL_DIR/scripts/vpn.sh" installed
```

The exit changes for the whole machine, not one shell, because the daemon owns
the tunnel.

## Is Mullvad installed?

```sh
command -v mullvad          # prints the path, or nothing
mullvad --version           # e.g. mullvad-cli 2026.5
```

| Platform | Typical path |
| --- | --- |
| macOS | `/usr/local/bin/mullvad` (symlink into `Mullvad VPN.app`) |
| Linux | `/usr/bin/mullvad` |
| Windows | `C:\Program Files\Mullvad VPN\resources\mullvad.exe` |

The skill checks this for you and exits **2** when the CLI is missing:

```sh
"$SKILL_DIR/scripts/vpn.sh" installed     # exit 0 installed, 2 not installed
"$SKILL_DIR/scripts/vpn.sh" doctor        # installed + daemon + account + exit
```

If it is missing, install it:

```sh
# macOS
brew install --cask mullvad-vpn
# Debian/Ubuntu — add the repo first: https://repository.mullvad.net/deb/stable
sudo apt install mullvad-vpn
# Fedora
sudo dnf config-manager --add-repo https://repository.mullvad.net/rpm/stable/mullvad.repo
sudo dnf install mullvad-vpn
# Arch
sudo pacman -S mullvad-vpn
# Windows
winget install --id Mullvad.MullvadVPN
```

Then log in with an account number (`mullvad account login 0000000000000000`).
An expired account connects to nothing; `doctor` reports it.

## See where you are

```sh
"$SKILL_DIR/scripts/vpn.sh" state          # state, relay, exit IP, constraints
"$SKILL_DIR/scripts/vpn.sh" verify         # exit IP as the outside world sees it
"$SKILL_DIR/scripts/vpn.sh" state --json   # machine-readable
```

`verify` reads `am.i.mullvad.net/json`. `mullvad_exit_ip: true` is the proof the
traffic leaves through Mullvad; `false` means a leak or a broken tunnel — fix that
before drawing conclusions about a site.

## Classify the refusal first

```sh
"$SKILL_DIR/scripts/vpn.sh" probe https://example.com/path --json
```

| `class` | Meaning | Move |
| --- | --- | --- |
| `ok` | 2xx/3xx | Nothing to fix — the block is elsewhere |
| `bot_challenge` | Cloudflare/DataDome/PerimeterX challenge | One exit change, then re-probe |
| `cf_ip_firewall` | Cloudflare error 1020, IP-level rule | One exit change; if it follows you, it is deliberate |
| `forbidden` | Plain 403 | Often deliberate. One change, then record it |
| `geo_blocked` | 200 but "not available in your country" | `use <cc>` for the content's country |
| `legal_block` | 451 | Same as geo |
| `rate_limited` | 429 | One other relay; still 429 → give up |
| `unauthorized` | 401 | Credentials, not network |
| `server_error` | 5xx | Server-side; the exit will not change it |
| `network_error` | curl failed | Tunnel/DNS problem — check `state` and `verify` |

`probe` exits 1 on a block, so it chains into shell logic.

## Change the exit

```sh
"$SKILL_DIR/scripts/vpn.sh" rotate              # new relay, same country/city
"$SKILL_DIR/scripts/vpn.sh" fresh               # random city in the current country
"$SKILL_DIR/scripts/vpn.sh" fresh us            # random city in another country
"$SKILL_DIR/scripts/vpn.sh" use gb              # whole country
"$SKILL_DIR/scripts/vpn.sh" use nl ams          # country + city
"$SKILL_DIR/scripts/vpn.sh" use jp-tyo-wg-001   # pin one relay
"$SKILL_DIR/scripts/vpn.sh" use any             # drop the location constraint
"$SKILL_DIR/scripts/vpn.sh" relays de           # valid cities for a country
```

Every mutating command snapshots `mullvad relay get` the first time it runs,
waits for the tunnel, and prints the new relay and exit IP. `rotate` retries
three times because a reconnect can land on the same relay.

To decide whether the block is about your address at all:

```sh
"$SKILL_DIR/scripts/vpn.sh" auto https://example.com/path
```

It probes, changes the exit once (twice at most), re-probes, and reports
`action: exit_specific` or `action: still_blocked`. A 429 gets one retry from
another relay; if it follows, `auto` stops with exit 3.

## Verify and restore

```sh
"$SKILL_DIR/scripts/vpn.sh" verify         # new exit, from outside
"$SKILL_DIR/scripts/vpn.sh" restore        # replay the pre-change constraints
```

`restore` reads the snapshot taken before the first change, so the machine goes
back to the city or country it started in. Run it when you are done.

## Gotchas

- **Lockdown mode** — with `lockdown: on`, disconnecting blocks all traffic.
  `vpn.sh off` warns; never do it casually over SSH.
- **Narrow constraints** — `no matching relay` means country/city/provider/
  ownership/multihop cannot all be satisfied. Widen with
  `mullvad relay set provider any`, `set ownership any`, `set multihop off`, or
  run `mullvad relay update`.
- **Browser cache is not a block** — cookies, service workers and HSTS survive an
  exit change. Trust `probe` (fresh connection, no cookies) or a private window.
- **DNS content blocking** — `mullvad dns get`; block-ads/trackers can make a
  site look broken. `mullvad dns set default` resets it.
- **Split tunnel** — excluded apps keep the real exit. If one tool disagrees with
  `curl`, check `mullvad split-tunnel get`.
- **Mullvad API unreachable** — `mullvad api-access list`, then
  `mullvad api-access use 2` (Mullvad Bridges); `test 2` first if unsure.
- **WireGuard port blocked** (hotel, airport, restrictive ISP) — stuck at
  `Connecting`. `mullvad anti-censorship set mode udp2tcp`, reconnect, revert to
  `auto` afterwards.
- **A pin sticks** — `use <hostname>` holds one relay until `use any`, `fresh`
  or `restore`.

## Raw CLI equivalents

| Task | `vpn.sh` | `mullvad` |
| --- | --- | --- |
| Installed? | `vpn.sh installed` | `command -v mullvad` |
| State | `vpn.sh state` | `mullvad status -j` |
| Exit IP | `vpn.sh ip` | `mullvad status -j \| jq -r .details.location.ipv4` |
| Constraints | — | `mullvad relay get` |
| Set location | `vpn.sh use de fra` | `mullvad relay set location de fra` |
| New relay | `vpn.sh rotate` | `mullvad reconnect --wait` |
| Connect / disconnect | `vpn.sh on` / `vpn.sh off` | `mullvad connect --wait` / `mullvad disconnect --wait` |
| Relay list | `vpn.sh relays de` | `mullvad relay list` |

The rest of the CLI (account, DNS, tunnel, split tunnel, anti-censorship,
api-access, reset) is in `references/cli-cheatsheet.md`.
