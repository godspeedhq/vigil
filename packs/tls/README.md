# The tls pack

TLS certificates, read the way a client meets them. For each target you list, any host and port this machine can reach, the pack makes a TLS handshake and reports the certificate it is given: the days until it expires, whether today is within its dates, whether it checks against the trusted CAs, and whether it is for the name asked for. And the handshake itself: whether it finished, and if not why (refused, no such host, unreachable, timeout, no TLS version in common, a failed handshake), how long it took, and the TLS version agreed.

An expired certificate is the most preventable outage there is, and it still takes sites down every week. Renewal is automatic until it is not: a DNS challenge that broke when the zone moved, a renewal that worked on disk while the server kept the old certificate in memory, a load balancer nobody remembered had a copy of its own, an intermediate the server stopped sending. The application's own monitoring rarely notices, because the application is fine. The clients notice: browsers refuse the site, and API clients fail with errors nobody reads until the phone rings.

**It reads what clients get.** The pack checks the certificate the server actually serves, not a file on disk. So a certificate renewed on disk that the server has not loaded is still the old one here, as it is for every client (our test shows it, before and after the reload). And it checks any server: a web site, a mail server's IMAPS or SMTPS port, an LDAPS directory, a database's TLS port, a Kubernetes API, a load balancer, a server you don't run but depend on.

**Nothing is sent but the handshake.** No request, no login: the server sees a client connect, agree TLS, and leave. It needs `openssl` on Linux and macOS, which nearly every one has, and nothing but PowerShell on Windows.

1. `vigil pack enable tls`, then in `vigil.config` set the job's `TLS_TARGETS`: the targets, separated by spaces.

   ```ini
   env = TLS_TARGETS=example.com shop.example.com mail.example.com:993 10.0.0.5:8443/app.internal
   ```

   A target is `host` (port 443), `host:port`, or either followed by `/name` to ask for a name (SNI) other than the host: `10.0.0.5:8443/app.internal` connects to 10.0.0.5 and asks for `app.internal`, as a client that resolves `app.internal` to it would. An IPv6 address goes in brackets, `[2001:db8::5]:443`. Each target is tagged `target=<as you listed it>`.

2. **For certificates from a private CA** (an internal CA, a Kubernetes cluster's, a Caddy or Traefik local CA), give the job the CA's certificate, in PEM:

   ```ini
   env = TLS_CACERT=/etc/ssl/private/internal-ca.pem
   ```

   On Windows, `TLS_CACERT=C:\certs\internal-ca.pem` (PEM or DER), or trust the CA in Windows itself, which the job uses as it is.

3. Each target has `TLS_TIMEOUT` seconds (10 by default) to answer and finish. The job runs every 15 minutes, which is plenty for certificates measured in days; `max_runtime = 10m` covers fifty targets that all time out.

**A target that does not answer is a reading**, `up 0` with why, and the run succeeds: alert on it in your backend. So is a certificate that fails a check. A run fails only when `openssl` is missing, or `TLS_CACERT` names a file that cannot be read.

**What it does not do (1.0.0):** STARTTLS, where a service starts in plain text and turns to TLS (SMTP on 25 and 587, IMAP on 143, PostgreSQL, LDAP on 389); revocation (OCSP and CRLs); and which TLS versions and ciphers a server will accept besides the one agreed.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `bash`, `openssl` (OpenSSL 1.1 or later), `awk`, `date` (every Linux has them; GNU `date` for `handshake_ms`, or `perl`) | the same: macOS has them all, with LibreSSL's `openssl` and `perl` | Nothing: PowerShell 5.1 or later |
| The targets | any service that speaks TLS from its first byte | | |
| Access | network access to each target, as a client would have | | |

**On macOS 12 and earlier**, the system's `openssl` is LibreSSL 2.8, which does not speak TLS 1.3. A server that offers only TLS 1.3 reads `up 0 reason=no_common_version` there. Put a newer `openssl` first on the `PATH` Vigil runs with (`brew install openssl@3`), or check those targets from another machine. macOS 13 and later have LibreSSL 3, which speaks TLS 1.3.

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `tls_certs` | For each target: the handshake (finished or why not, how long, the TLS version); its certificate's days to expiry, dates, trust, name, issuer and subject. In all: the targets, those failing a check, and the days until the first certificate expires | 15 minutes |

**Trusted and the name are two checks.** `cert_trusted` is the chain: does it lead to a CA this machine trusts (or `TLS_CACERT`)? `cert_name_ok` is the name: is the certificate for the name asked for, among its subject alternative names, a wildcard taking one label (`*.example.com` takes `a.example.com`, not `a.b.example.com` or `example.com`)? A certificate can pass one and fail the other, and the fix is different: a chain is fixed on the server (send the intermediate), a name by a new certificate.

**The reason is each platform's own words.** Linux and macOS say what OpenSSL says (`certificate_has_expired`, `self-signed_certificate`, `unable_to_verify_the_first_certificate`, the last one a server that does not send its intermediate). Windows says what Windows says (`NotTimeValid`, `UntrustedRoot`, `PartialChain`). The metric names and tags are the same everywhere.

**`handshake_ms` is from connecting to the end of the handshake.** On Linux and macOS it includes starting `openssl`, a few milliseconds. A handshake that takes much longer than its habit is a server, or a network, under strain.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `tls.targets`.

```text
+--------------------------------------------------------------------------------------------------+
| tls_certs   tls.<metric>   every 15m                                                             |
+-------------------+------------------------------------------------------------------------------+
| targets           | the targets in TLS_TARGETS                                                   |
| targets_failed    | of those, how many failed a check: the handshake, the dates, trust or the    |
|                   | name                                                                         |
| soonest_days      | days until the first of their certificates expires (below 0: one has         |
|                   | expired); none when no target answered                                       |
| up                | 1 when the handshake finished, else 0; tagged target=<as listed> and         |
|                   | reason=<ok, refused, no_such_host, unreachable, timeout, no_common_version,  |
|                   | handshake_failed>; the rest only when it finished. no_common_version: the    |
|                   | server and this openssl share no TLS version (the LibreSSL of macOS 12 and   |
|                   | earlier has no TLS 1.3)                                                      |
| handshake_ms      | the time to connect and finish the handshake (with the start of openssl      |
|                   | itself, a few ms)                                                            |
| cert_expires_days | days until the certificate expires (below 0: expired)                        |
| cert_valid        | 1 when today is within its dates, else 0                                     |
| cert_trusted      | 1 when its chain checks against the trusted CAs (or TLS_CACERT), else 0,     |
|                   | tagged reason=<openssl's words, or ok>                                       |
| cert_name_ok      | 1 when it is for the name asked for (its subject alternative names,          |
|                   | wildcards as clients take them), else 0                                      |
| cert_info         | always 1, tagged issuer=<its CN>, subject=<its CN> and protocol=<the TLS     |
|                   | version agreed>                                                              |
| ..._not_shown     | past 100 of a list (targets), how many were left out                         |
+-------------------+------------------------------------------------------------------------------+
| GOOD  up 1; cert_expires_days above 30; cert_valid, cert_trusted and cert_name_ok 1;             |
|       targets_failed 0.                                                                          |
| WATCH cert_expires_days below 30: automatic renewal (Let's Encrypt, 30 days ahead) should have   |
|       happened, so it is not working; handshake_ms well above its usual.                         |
| BAD   cert_expires_days below 7; cert_valid 0 (expired, or not yet valid); cert_trusted 0        |
|       (reason says why: clients that check, all browsers, refuse it now); cert_name_ok 0 (served |
|       for the wrong name); up 0 (reason says why).                                               |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures the script's header explains; "In our tests" is what the targets made on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `tls.up` (by `target`) | 1 |  | 0: nothing answers TLS there; `reason` says why | `refused` (nothing listening), `no_such_host`, `timeout` (a port that took the connection and never answered), `handshake_failed` (plain HTTP, no TLS), `no_common_version` (TLS 1.3 only, met by macOS 12's LibreSSL) |
| `tls.cert_expires_days` (by `target`) | Above 30 | Below 30: automatic renewal (Let's Encrypt, 30 days ahead) should have happened, so it is not working | Below 7 | 5.00 for the certificate made for 5 days; 365.00, then 90.00 once nginx reloaded the renewed one |
| `tls.soonest_days` | Above 30 | Below 30 | Below 7 | -637.69: the expired certificate, the soonest of all |
| `tls.cert_valid` (by `target`) | 1 |  | 0: expired, or not valid yet (a clock that is wrong, here or on the server that issued it) | 0 for the expired certificate and for the one valid from 2099 |
| `tls.cert_trusted` (by `target`) | 1 |  | 0: clients that check (every browser) refuse it; `reason` says why | 0 for the expired, the not-yet-valid, the self-signed, and the one whose intermediate the server did not send (`unable_to_verify_the_first_certificate`; Windows: `PartialChain`) |
| `tls.cert_name_ok` (by `target`) | 1 |  | 0: the server sends a certificate for another name | 0 for the one made for `other.test`, and for `a.b.apps.test` against `*.apps.test` |
| `tls.targets_failed` | 0 |  | Above 0: one alert for any of the above | 10 of 15 (11 on the Mac, with its TLS 1.3 limit) |
| `tls.handshake_ms` (by `target`) | Its habit | Several times its habit |  | 16 to 28 ms on Fedora; 51 to 366 ms on Windows, through two SSH tunnels |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-tls.sh`, against `compose.tls.yaml`: **nginx 1.30.8** serving, from a CA the run made, a certificate for each kind of trouble, chosen by the name asked for: one good for a year; one that expires in 5 days; one expired (2025); one not valid until 2099; one self-signed; one for another name; one from an intermediate, served without it; and a wildcard, `*.apps.test`. Then TLS 1.3 only and TLS 1.2 only on ports of their own; a port that is not TLS (plain HTTP); a port that takes the connection and never answers; a port nothing listens on; and a host that does not exist. Fifteen targets, ten of them failing a check on purpose.

- **On Fedora** (Fedora 44, bash 5.3, OpenSSL 3.5.9): the job against all fifteen, each reading checked: the good one trusted through the CA, a year left, its issuer and subject, its handshake timed; the 5-day one; the expired one the soonest of all; each failing for its own reason, by OpenSSL's words; the wildcard taking one label and not two; TLS 1.3 and 1.2 each agreed; each target that does not answer, with why; without the CA, the good one not trusted; no targets, none counted. Then a renewal: a new certificate for 90 days on disk, still the old one before nginx reloaded, the new one after. **18 passed, 0 failed**; then `service-packs.sh` through Vigil (enable, what it asks for, precheck, the job, every target counted, the failing ones counted, the metrics in the backend by target): **9 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-tls/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator, against the same fifteen through SSH tunnels: every target's reading under Windows PowerShell 5.1 and PowerShell 7, both agreeing TLS 1.3 where the server offered it: **42 passed, 0 failed**; the same metric names, targets and tags as the Linux script, under both shells; through Vigil, **8 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-tls-windows/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own LibreSSL 2.8.3, awk and perl), the same fifteen: each as on Fedora, but the TLS 1.3-only server, which LibreSSL 2.8 cannot reach (`no_common_version`): **21 passed, 0 failed**; through Vigil, **9 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-tls-macos/console.txt)).

**What the run taught the pack:**

- **`openssl s_client` has no time limit for connecting.** A port that takes the connection and never answers would hold the job until Vigil stopped it, with nothing reported for any target. Each handshake now has `TLS_TIMEOUT` seconds, and reads `up 0 reason=timeout` past them.
- **A server that leaves out its intermediate is "unable to verify the first certificate"** to OpenSSL, and `PartialChain` to Windows. Browsers sometimes hide it by fetching the intermediate themselves, so a site can look fine in one and fail in every API client.
- **macOS 12's own `openssl` is LibreSSL 2.8, with no TLS 1.3**: a server that offers only 1.3 failed there as `handshake_failed`, which hid why. It reads `no_common_version` now.
- **Windows' reason was the same word for every chain**, `RemoteCertificateChainErrors`, until the job built the chain itself to read Windows' own words for it: `NotTimeValid`, `UntrustedRoot`, `PartialChain`.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
