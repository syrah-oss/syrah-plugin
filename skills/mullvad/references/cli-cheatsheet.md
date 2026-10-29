# Mullvad CLI cheat sheet

Verified against the `mullvad` CLI (2026.5) on macOS. Re-check with
`mullvad <command> --help` — flags move between releases.

## Reading state

```sh
mullvad status                 # Connected / Connecting / Disconnected
mullvad status -v              # relay + endpoint + tunnel interface
mullvad status -j              # JSON: state, details.endpoint, details.location
mullvad status listen          # follow tunnel state changes (blocks)
mullvad relay get              # location/provider/ownership/ip-version/multihop
mullvad tunnel get             # MTU, quantum resistance, DAITA, public key, allowed IPs
mullvad account get            # account number, expiry, device name
mullvad version                # CLI + daemon version, available updates
```

`mullvad status -j` shape (connected):

```json
{"state":"connected","details":{
  "endpoint":{"address":"146.70.117.130:18078","protocol":"udp","quantum_resistant":true},
  "location":{"ipv4":"146.70.117.184","mullvad_exit_ip":true,"hostname":"de-fra-wg-102",
              "city":"Frankfurt","country":"Germany"}}}
```

The exit IP is `null` for a second or two after connecting — poll it.

## Exit location

```sh
mullvad relay set location any                 # no constraint
mullvad relay set location de                  # country
mullvad relay set location de fra              # country + city
mullvad relay set location de fra de-fra-wg-101# country + city + host
mullvad relay set location de-fra-wg-101       # pin a single relay
mullvad relay set multihop on|off
mullvad relay set entry <cc> [city] [host]     # multihop entry (only used when multihop is on)
mullvad relay set provider any|<name>...       # e.g. M247, DataPacket, 31173
mullvad relay set ownership any|owned|rented
mullvad relay set ip-version any|ipv4|ipv6
mullvad relay list                             # countries → cities → hosts, with provider
mullvad relay update                           # refresh the relay list from the API
```

Changing a constraint re-selects the relay. `mullvad reconnect --wait` re-picks
one inside the current constraints; it may land on the same relay, so compare
the exit IP before and after.

## Connection control

```sh
mullvad connect --wait
mullvad disconnect --wait
mullvad reconnect --wait
mullvad auto-connect get|set on|off
mullvad lockdown-mode get|set on|off    # off = traffic is allowed when disconnected
```

## Account

```sh
mullvad account get
mullvad account login <account-number>
mullvad account create
mullvad account logout
mullvad account redeem <voucher>
mullvad account list-devices
mullvad account revoke-device <device>
```

An expired account keeps the daemon "disconnected" no matter what you select.

## DNS, LAN, split tunnel

```sh
mullvad dns get
mullvad dns set default [--block-ads --block-trackers --block-malware \
                         --block-adult-content --block-gambling --block-social-media]
mullvad dns set custom <ip>...
mullvad dns set default                      # reset to no content blocking

mullvad lan get|set on|off                   # allow reaching the local network

mullvad split-tunnel get
mullvad split-tunnel set on|off
mullvad split-tunnel app add <path>
mullvad split-tunnel app remove <path>
mullvad split-tunnel app clear
```

Split-tunneled apps bypass the exit — if one tool disagrees with `curl` about
being blocked, this is why.

## Tunnel options

```sh
mullvad tunnel set quantum-resistant on|off
mullvad tunnel set daita on|off
mullvad tunnel set mtu <n>|any
mullvad tunnel set ipv6 on|off
mullvad tunnel set rotation-interval <hours>|any
mullvad tunnel set rotate-key              # new WireGuard key immediately
mullvad tunnel set userspace on|off
```

## When the network blocks Mullvad itself

Symptom: `Connecting` forever, or `mullvad relay update` fails.

```sh
mullvad api-access list                    # Direct / Mullvad Bridges / Encrypted DNS proxy
mullvad api-access get
mullvad api-access test 2                  # index from `list`
mullvad api-access use 2                   # Mullvad Bridges
mullvad api-access add <name> socks5 <host> <port>   # custom proxy
mullvad api-access enable|disable <index>
```

WireGuard traffic blocked but the API works (hotel, airport, some ISPs):

```sh
mullvad anti-censorship get
mullvad anti-censorship set mode auto|off|udp2tcp|shadowsocks|wireguard-port|quic|lwo
mullvad anti-censorship set udp2tcp --port any
mullvad anti-censorship set shadowsocks --port any
mullvad anti-censorship set wireguard-port --port any
```

Set a specific method, reconnect, and revert to `auto` when the restrictive
network is behind you.

## Backups, logs, reset

```sh
mullvad export-settings > mullvad-settings.json    # JSON patch of all settings
mullvad import-settings < mullvad-settings.json
mullvad log set-level info|debug|trace|off
mullvad log listen
mullvad reset-settings      # settings only, keeps login and logs
mullvad factory-reset       # settings, caches and logs — logs you out
```

`export-settings` is the clean way to save and restore a working configuration
before an experiment.

## Common errors

| Message | Cause | Fix |
| --- | --- | --- |
| `no matching relay` | constraints cannot be satisfied together (city + provider + ownership + multihop entry) | widen: `provider any`, `ownership any`, `multihop off`, or `relay update` |
| `unrecognized subcommand` | older/newer CLI than this sheet | `mullvad <cmd> --help` |
| `Connecting` never completes | UDP blocked, or API unreachable | `anti-censorship set mode udp2tcp`, `api-access use "Mullvad Bridges"` |
| daemon errors on every command | `mullvad-daemon` not running | start the app/daemon |
