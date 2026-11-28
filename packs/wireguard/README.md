# The wireguard pack

WireGuard tunnels on a Linux machine. For each WireGuard interface, the pack reads its peers, and for each peer how long since it last completed a handshake, and the bytes it sent and received. A peer whose last handshake is too old is **stale**: it stopped talking, or cannot. A peer that never completed one has **never connected**.

WireGuard is silent by design. It sends nothing to a peer that isn't there, logs nothing, and keeps the interface up whatever happens on the other end. So a site link can be down for a weekend with `wg0` up, `ip link` happy and nothing in any log. The one place it shows is the peer's last handshake: a peer that is talking completes one at least every two minutes.

**It never reads a key.** The pack runs only three commands: `wg show interfaces`, `wg show all latest-handshakes` and `wg show all transfer`. None of them prints a private or a preshared key. It never runs `wg show` alone or `wg show all dump`, which do. A peer is named by its **public** key, which isn't a secret: every peer it talks to has it. Our test looks for every private and preshared key in everything the pack printed and everything Vigil wrote, and finds none.

1. **Give Vigil's account those three commands as root, and nothing else.** `wg show` needs root (WireGuard's settings are readable by root alone), and Vigil runs as the unprivileged account `vigil` on Linux. As root, run `visudo -f /etc/sudoers.d/vigil-wireguard` and add one line:

   ```text
   vigil ALL=(root) NOPASSWD: /usr/bin/wg show interfaces, /usr/bin/wg show all latest-handshakes, /usr/bin/wg show all transfer
   ```

   sudo allows exactly those commands with exactly those arguments: not `wg show` alone, not `dump`, not `private-key`, not `wg set`. Check where `wg` is (`command -v wg`) and use that path if it isn't `/usr/bin/wg`.

2. `vigil pack enable wireguard`. It runs every minute.

3. **Stale** is a last handshake older than `WG_STALE_SECONDS` (180 by default). A peer that carries traffic, or has `PersistentKeepalive` set, completes a handshake every two minutes, so 180 seconds gives it a minute's grace. A peer that is idle by nature (a laptop that connects now and then, with no keepalive) goes stale whenever it is idle: alert on the peers that should always be up.

Without the rule, the job fails and says what to add: `may not run "wg show interfaces" as root: add the sudoers rule in packs/wireguard/README.md`.

## What it needs

| | Linux |
| --- | --- |
| On the Vigil machine | `bash`, `awk`, `wg` (wireguard-tools), `sudo` and the rule above |
| WireGuard | any WireGuard the `wg` command can read, however it was set up: wg-quick, systemd-networkd, NetworkManager, by hand |

Linux only, in 1.0.0. On Windows and macOS, Vigil's service runs as LocalSystem and root, so no rule is needed there, but neither was tested: the test machines' accounts aren't administrators, and WireGuard needs one.

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `wireguard_peers` | The interfaces and their peers; how many are stale and how many never connected; each peer's last handshake and bytes sent and received, the 20 quiet longest first | minute |

**`handshake_seconds` is the reading that matters.** Bytes received keep counting only while a peer talks, and the interface is up whether a peer is there or not. A last handshake that grows past two minutes is a peer that has stopped. `-1` is a peer that has never completed one: a peer added and never connected, or one whose key or endpoint is wrong.

**The 20 quiet longest are shown first**: never-connected peers, then the peers with the oldest handshakes. On a hub with hundreds of peers, the ones in trouble are the ones you see.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `wireguard.interfaces`.

```text
+--------------------------------------------------------------------------------------------------+
| wireguard_peers   wireguard.<metric>   every 1m                                                  |
+-------------------+------------------------------------------------------------------------------+
| interfaces        | WireGuard interfaces on this machine                                         |
| peers             | their peers, all together                                                    |
| peers_stale       | of them, those whose last handshake is older than WG_STALE_SECONDS           |
| peers_never       | those that never completed a handshake                                       |
| interface_peers   | one interface's peers, tagged interface=<its name>                           |
| handshake_seconds | since a peer's last handshake (-1: never), tagged interface= and peer=<its   |
|                   | public key>, the 20 that have been quiet longest (never first)               |
| rx_bytes_count    | bytes received from that peer (a running total, since the interface came up) |
| tx_bytes_count    | bytes sent to that peer (a running total)                                    |
| ..._not_shown     | past 100 of a list (peers), how many were left out                           |
+-------------------+------------------------------------------------------------------------------+
| GOOD  peers_stale 0 for peers that should always be up (with PersistentKeepalive, they handshake |
|       every two minutes even when idle); peers_never 0.                                          |
| WATCH a peer's handshake_seconds above WG_STALE_SECONDS when it should be talking: it is down,   |
|       or something between drops its packets; peers_never above 0 for a peer just added.         |
| BAD   peers_stale for a peer that carries traffic (a site link, a server's tunnel): the tunnel   |
|       is down; interfaces lower than expected: an interface is gone.                             |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures the script's header explains; "In our tests" is what the tunnels made on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `wireguard.handshake_seconds` (by `peer`) | Below 180 for a peer that should be up | Above 180 for a peer that should be up | Above 180 for a peer that carries traffic (a site link, a server's tunnel): it is down | 183 for peer2, three minutes after it stopped; 63 for peer1, still up |
| `wireguard.peers_stale` | 0 |  | Above 0, for peers that should be up | 1, peer2 |
| `wireguard.peers_never` | 0 | Above 0 for a peer just added | Above 0 for long: a wrong key or endpoint | 1, the peer that never existed (`-1`, listed first) |
| `wireguard.interfaces`, `interface_peers` | As configured |  | Fewer: an interface is gone | 2: `wg0` with 3 peers, `wg1` with none |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-wireguard.sh`, against `compose.wireguard.yaml`: **kernel WireGuard** on Fedora 44 (Linux 7.1), wireguard-tools 1.0.20260223, in three containers, each in its own network namespace. A hub with `wg0` and three peers: peer1 (with a preshared key), peer2, and one that never connects; and `wg1` with none. peer1 and peer2 each kept the tunnel alive and pinged the hub. In the hub, an account `vigil` with exactly the sudoers rule above, and an account `other` with none. The keys were made by `wg` and written to files only.

- **The pack as `vigil`, through sudo**: two interfaces, three peers on `wg0` and none on `wg1`; the one never connected listed first, at `-1`; peer1 and peer2 each with a handshake within two minutes and bytes both ways. **As `other`**: it fails, and says which rule to add. **Then peer2 stopped**: past 180 seconds it was stale (183), peer1 not (63), and the order was the never-connected peer, peer2, peer1. **No key** in anything it printed: **10 passed, 0 failed**.
- **Through Vigil**, in the hub as `vigil`: enable (it says the rule it needs, and that no command prints a key), precheck, the job, the metrics in the backend, each peer by its public key, and **no private or preshared key anywhere Vigil wrote**, its whole root searched: **10 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-wireguard/console.txt)).
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
