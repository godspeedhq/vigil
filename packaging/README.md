# Packages

Vigil installs from a package manager as well as from its install script: a `.deb` and an `.rpm` since 0.5.0, and Homebrew and Scoop since 0.5.1. This page says what each one does and shows it working. **Every console capture here is real output from a real machine**: the Fedora 44, macOS and Windows 11 test machines, or a CI run, as each says.

| | Install with | Since | The program | Your configuration, scripts, state and logs |
| --- | --- | --- | --- | --- |
| 🍥 Debian, Ubuntu | `sudo apt install ./vigil_<version>-1_all.deb` | 0.5.0 | `/usr/lib/vigil` | `/opt/vigil` |
| 🎩 Fedora, RHEL, Rocky, Alma | `sudo dnf install ./vigil-<version>-1.noarch.rpm` | 0.5.0 | `/usr/lib/vigil` | `/opt/vigil` |
| 🍺 Homebrew, macOS and Linux | `brew install godspeedhq/vigil/vigil` | 0.5.1 | `$(brew --prefix)/opt/vigil` | `$(brew --prefix)/var/vigil` |
| 🥄 Scoop, Windows | `scoop install vigil`, from the bucket `godspeedhq/scoop-vigil` | 0.5.1 | `~\scoop\apps\vigil\current` | `~\scoop\persist\vigil` |
| ⚓ MacPorts, macOS | `sudo port install vigil`, once the port is in the ports tree | not yet | `/opt/local/libexec/vigil` | `/opt/local/var/vigil` |

In every case:

- **The package manager owns the program.** `vigil self update`, `vigil uninstall` and `vigil service install` refuse and name the package manager's own command instead.
- **Your work is yours.** Installing writes a starting configuration only when there is none; updating and removing leave your configuration, scripts, state and logs alone.
- **Updating takes no extra step.** The service restarts on the new version, or the running supervisor reloads itself.

`vigil about` says which one installed it. The `PACKAGED` file beside the program tells Vigil, as [the specification](https://godspeedhq.github.io/vigil/spec/18/) describes.

## 🍥🎩 `.deb` and `.rpm`

Both are on each release, beside the archives, and listed in the signed `SHA256SUMS`. They are tested in CI on Debian 13, Ubuntu 24.04, Fedora 43 and 44, and Rocky Linux 9: install, run, upgrade, remove and reinstall, under systemd. The definition is in [`packaging/linux`](https://github.com/godspeedhq/vigil/tree/main/packaging/linux).

The package creates the `vigil` account, writes a starting configuration, and installs the `vigil` systemd service as `/usr/lib/systemd/system/vigil.service`, which runs as that account.

⚠️ The packages are not GPG-signed yet, so `dnf` says `skipped OpenPGP checks`. Check the file against the signed `SHA256SUMS` first:

```
grep noarch.rpm SHA256SUMS | sha256sum -c
```

### A fresh install

Fedora 44, 0.5.0:

```
$ sudo dnf install ./vigil-0.5.0-1.noarch.rpm
Package      Arch   Version         Repository        Size
Installing:
 vigil       noarch 0:0.5.0-1       @commandline   1.1 MiB
Installing dependencies:
 hostname    x86_64 0:3.25-4.fc44   fedora        41.3 KiB
 liblastlog2 x86_64 0:2.41.6-1.fc44 updates       41.6 KiB
 openssl     x86_64 1:3.5.9-1.fc44  updates        1.9 MiB
 procps-ng   x86_64 0:4.0.6-1.fc44  fedora         1.1 MiB
 util-linux  x86_64 0:2.41.6-1.fc44 updates        3.5 MiB
...
[8/8] Installing vigil-0:0.5.0-1.noarch 100% | 511.2 KiB/s |   1.0 MiB |  00m02s
>>> Running %post scriptlet: vigil-0:0.5.0-1.noarch
>>> Finished %post scriptlet: vigil-0:0.5.0-1.noarch
>>> Scriptlet output:
>>> wrote /opt/vigil/config/vigil.config
>>> on: base_cpu
>>> on: base_memory
>>> on: base_disk
>>> on: base_network
>>> on: base_load
>>> on: base_services
>>>
>>> Vigil is installed. Start it with: sudo systemctl enable --now vigil
>>> Its configuration is /opt/vigil/config/vigil.config: sudo vigil config edits it.
>>>
Warning: skipped OpenPGP checks for 1 package from repository: @commandline
Complete!
```

🎩 Fedora and RHEL leave a newly installed service off until you turn it on, as they do for every package:

```
$ sudo systemctl enable --now vigil
Created symlink '/etc/systemd/system/multi-user.target.wants/vigil.service' → '/usr/lib/systemd/system/vigil.service'.
$ vigil status
service: active, pid 414 (systemd, system mode)

Vigil fedora-test at 2026-11-07T01:31:36Z

WAITING
  base_cpu: next 2026-11-07T01:32:00Z
  base_memory: next 2026-11-07T01:32:00Z
  base_disk: next 2026-11-07T01:35:00Z
  base_network: next 2026-11-07T01:32:00Z
  base_load: next 2026-11-07T01:32:00Z
  base_services: next 2026-11-07T01:32:00Z

LAST RUN
  base_cpu: succeeded
  base_memory: succeeded
  base_network: succeeded
  base_load: succeeded
  base_services: succeeded
```

🍥 Debian and Ubuntu start what they install: the `.deb` runs `vigil precheck` as the `vigil` account and, when it passes, starts the service straight away.

`vigil about` says who owns the program:

```
$ vigil about
Vigil 0.5.0
...
Installed   /opt/vigil
Program     /usr/lib/vigil, by dnf
Platform    Linux, bash 5.3.9
```

### Switching from the install script

Install the package over it. The package finds the install script's service, **leaves it running**, and says how to switch. This is the Fedora 44 test machine, which ran 0.4.0 as a system service:

```
$ sudo dnf install ./vigil-0.5.0-1.noarch.rpm
...
[3/3] Installing vigil-0:0.5.0-1.noarch 100% | 757.1 KiB/s |   1.0 MiB |  00m01s
>>> Running %post scriptlet: vigil-0:0.5.0-1.noarch
>>> Finished %post scriptlet: vigil-0:0.5.0-1.noarch
>>> Scriptlet output:
>>>
>>> Vigil was installed here before by its install script, whose service still runs it.
>>> Your configuration, scripts and packs are already in place; to switch to the package:
>>>   sudo /opt/vigil/app/vigil service remove
>>>   sudo rm -rf /opt/vigil/app /opt/vigil/vendor /usr/local/bin/vigil /etc/sudoers.d/vigil
>>>   sudo systemctl enable --now vigil
>>>
Complete!
$ sudo /opt/vigil/app/vigil service remove
removed /etc/systemd/system/vigil.service; running workers continue
$ sudo rm -rf /opt/vigil/app /opt/vigil/vendor /usr/local/bin/vigil /etc/sudoers.d/vigil
$ sudo systemctl enable --now vigil
Created symlink '/etc/systemd/system/multi-user.target.wants/vigil.service' → '/usr/lib/systemd/system/vigil.service'.
$ vigil version
Vigil 0.5.0
$ vigil status
service: active, pid 1320019 (systemd, system mode)

Vigil fedora at 2026-11-07T00:54:47Z
...
LAST RUN
  base_cpu: succeeded
  base_memory: succeeded
  base_disk: succeeded
  base_network: succeeded
  base_load: succeeded
  base_services: succeeded
```

### Updating, with the service running

Install the newer package the same way. The service stops, the program is replaced, and the service starts again on the new version; jobs that are running carry on to their end. The Fedora 44 test machine, 0.5.0 to 0.5.1, from Vigil's own log:

```
2026-11-07T09:53:01Z INFO supervisor job base_services: run 20261107T095301Z-1320019-6038 started
2026-11-07T09:53:11Z INFO supervisor supervisor stopped; running workers continue
2026-11-07T09:53:19Z INFO supervisor configuration loaded
2026-11-07T09:53:19Z INFO supervisor supervisor started, pid 2229670
```

```
$ rpm -q vigil
vigil-0.5.1-1.noarch
$ vigil status
service: active, pid 2229670 (systemd, system mode)

Vigil fedora at 2026-11-07T09:53:49Z
...
LAST RUN
  base_cpu: succeeded
  base_memory: succeeded
  base_disk: succeeded
  base_network: succeeded
  base_load: succeeded
  base_services: succeeded
```

### What Vigil leaves to the package

0.5.0 on the Fedora test machine, as root:

```
$ sudo vigil self update
vigil: Vigil was installed by dnf: update it with sudo dnf install ./vigil-<version>-1.noarch.rpm, from https://github.com/godspeedhq/vigil/releases

$ sudo vigil uninstall
vigil: Vigil was installed by dnf: remove it with that, which stops the service and keeps /opt/vigil

$ sudo vigil service install
vigil: the vigil package installed this service: start it with sudo systemctl enable --now vigil

$ sudo vigil service remove
vigil: the vigil package installed this service: stop it with sudo systemctl disable --now vigil, or remove the package
```

And 0.5.1, without sudo:

```
$ vigil service install
vigil: the vigil package installed this service: start it with sudo systemctl enable --now vigil
$ vigil service remove
vigil: the vigil package installed this service: stop it with sudo systemctl disable --now vigil, or remove the package
```

### Removing

```
$ sudo dnf remove vigil
...
>>> Running %postun scriptlet: vigil-0:0.5.0-1.noarch
>>> Finished %postun scriptlet: vigil-0:0.5.0-1.noarch
>>> Scriptlet output:
>>> Vigil was removed; its configuration, scripts and logs are kept in /opt/vigil
Complete!
```

Reinstalling picks up where you left off. On Debian and Ubuntu, `sudo apt purge vigil` removes `/opt/vigil` as well.

## 🍺 Homebrew

```sh
brew install godspeedhq/vigil/vigil
brew services start vigil      # runs it now and at every login
```

The formula is made from [`packaging/homebrew/vigil.rb.in`](https://github.com/godspeedhq/vigil/blob/main/packaging/homebrew/vigil.rb.in) and published in the tap [`godspeedhq/homebrew-vigil`](https://github.com/godspeedhq/homebrew-vigil). It has no dependencies and nothing to build: it puts the scripts in place and writes a starting configuration, so it installs in seconds, even where Homebrew has no bottles for the macOS version.

- `brew services start vigil` runs the supervisor as a LaunchAgent on macOS, or a systemd user unit on Linux. `vigil status` and `vigil restart` find it.
- `brew upgrade vigil` updates it in place: the running supervisor notices the new version and reloads itself, keeping the same process.
- `brew uninstall vigil` removes the program and keeps `$(brew --prefix)/var/vigil`.
- ⚠️ `brew services stop vigil` ends running jobs as well as the supervisor: Homebrew stops the whole process group.

### On an Intel Mac

Homebrew's installer refuses Intel Macs (`Homebrew on macOS is only supported on Apple Silicon processors!`), but Homebrew itself still runs on them, as a [Tier 3](https://docs.brew.sh/Support-Tiers) configuration, until September 2027. With Apple's Command Line Tools in place (`xcode-select --install`), clone it into your home folder, which needs no sudo, and add it to your shell profile so new terminals find `brew`:

```sh
git clone https://github.com/Homebrew/brew ~/homebrew
echo 'eval "$(~/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(~/homebrew/bin/brew shellenv)"
brew install godspeedhq/vigil/vigil
```

[`intel-mac.sh`](https://github.com/godspeedhq/vigil/blob/main/packaging/homebrew/intel-mac.sh) does the first three for you, on the latest Homebrew release, and checks the Mac first. It has nothing to do with Vigil: it is for anyone with an Intel Mac, new or second-hand, who wants Homebrew. Run it as yourself, not with sudo:

```sh
curl -fsSL https://raw.githubusercontent.com/godspeedhq/vigil/main/packaging/homebrew/intel-mac.sh | bash
```

`--uninstall` takes it all away again: it lists what it will remove, with every formula and cask installed through it, and asks first. It stops anything `brew services` runs, then removes `~/homebrew`, Homebrew's caches, logs and settings, and its line in your shell profile, leaving the rest of the profile as it was:

```
$ curl -fsSL https://raw.githubusercontent.com/godspeedhq/vigil/main/packaging/homebrew/intel-mac.sh | bash -s -- --uninstall
This removes:
  /Users/vigil-test/homebrew, with everything installed through it and its data in /Users/vigil-test/homebrew/var:
    formulae: vigil
    casks:    none
  /Users/vigil-test/Library/Caches/Homebrew
  /Users/vigil-test/Library/Logs/Homebrew
  /Users/vigil-test/.homebrew
  the brew shellenv line in /Users/vigil-test/.zprofile
Remove? [y/N] y
removed /Users/vigil-test/homebrew
removed /Users/vigil-test/Library/Caches/Homebrew
removed /Users/vigil-test/Library/Logs/Homebrew
removed /Users/vigil-test/.homebrew
removed the brew shellenv line from /Users/vigil-test/.zprofile

Done. Open a new terminal: the one you have still has brew on its PATH.
```

A `~/homebrew` that is not a Homebrew clone is left alone, and with an older Homebrew in `/usr/local` the caches, logs and settings it shares stay.

Homebrew warns about the Intel Mac, the old macOS and the prefix; none of that matters to Vigil, which builds nothing. This is the macOS test machine, an Intel MacBook Air on macOS 12.7.6, the day 0.5.1 came out (the account and Mac names are replaced with `you` and `your-mac`):

```
$ brew --version
Homebrew 7.0.12

$ brew install godspeedhq/vigil/vigil
==> Pouring portable-ruby-4.0.9.big_sur.bottle.tar.gz
...
==> Tapping godspeedhq/vigil
Cloning into '/Users/you/homebrew/Library/Taps/godspeedhq/homebrew-vigil'...
Tapped 1 formula (18 files, 32.3KB).
Warning: Your Homebrew's prefix is not /usr/local.
...
Warning: You are using macOS 12.
We (and Apple) do not provide support for this old version.
...
==> Fetching downloads for: vigil
✔︎ Formula vigil (0.5.1)
==> Installing vigil from godspeedhq/vigil
...
🍺  /Users/you/homebrew/Cellar/vigil/0.5.1: 85 files, 1.1MB, built in 8 seconds

$ vigil about
Vigil 0.5.1
...
Installed   /Users/you/homebrew/var/vigil
Program     /Users/you/homebrew/opt/vigil/libexec, by Homebrew
Platform    macOS, bash 3.2.57

$ vigil self update
vigil: Vigil was installed by Homebrew: update it with brew upgrade vigil

$ vigil service install
vigil: Vigil was installed by Homebrew, which runs its service: brew services start vigil

$ brew services start vigil
==> Successfully started `vigil` (label: sh.brew.vigil)

$ vigil status
service: active, pid 61955 (launchd, user mode)

Vigil your-mac at 2026-11-07T12:35:57Z

WAITING
  base_cpu: next 2026-11-07T12:36:00Z
  base_memory: next 2026-11-07T12:36:00Z
  base_disk: next 2026-11-07T12:40:00Z
  base_network: next 2026-11-07T12:36:00Z
  base_load: next 2026-11-07T12:36:00Z
  base_services: next 2026-11-07T12:36:00Z

$ brew services list
Name  Status User            File
vigil started         you             ~/Library/LaunchAgents/sh.brew.vigil.plist
```

### In CI

CI installs, runs, upgrades and removes it on every change, on Homebrew 7 on macOS (`tests/packages/homebrew.sh`):

```
vigil formula 0.0.1 then 0.0.2, Homebrew 7.0.11 on Darwin arm64
  PASS  install: succeeds
  PASS  install: says how to start it
  PASS  install: no advice to run vigil service install
  PASS  the command is on PATH
  PASS  it runs the version installed
  PASS  about: the root is var/vigil
  PASS  about: the program and its package manager
  PASS  a starting configuration was written
  PASS  the base pack is in the root
  PASS  a job runs
  PASS  brew test passes
  PASS  self update: refused
  PASS  self update: says brew upgrade vigil
  PASS  uninstall: refused
  PASS  service install: refused
  PASS  service install: says brew services start vigil
  PASS  brew services start: succeeds
  PASS  the supervisor runs
  PASS  status finds brew services' registration
  PASS  service install: refused once registered
  PASS  service remove: refused
  PASS  vigil restart: succeeds
  PASS  vigil restart: a new supervisor
  PASS  upgrade: succeeds
  PASS  upgrade: the new version
  PASS  upgrade: the configuration is kept
  PASS  upgrade: scripts are kept
  PASS  upgrade: the service runs the new version
  PASS  upgrade: the service is active
  PASS  upgrade: the same supervisor process
  PASS  upgrade: it reloaded
  PASS  brew services stop: succeeds
  PASS  status: no longer registered
  PASS  uninstall: succeeds
  PASS  uninstall: the command is gone
  PASS  uninstall: the root is kept
  PASS  reinstall: succeeds
  PASS  reinstall: the configuration is untouched
38 passed, 0 failed
```

## ⚓ MacPorts

```sh
sudo port install vigil
sudo port load vigil           # runs it now and at every boot
```

🚧 **Not in the MacPorts ports tree yet:** the port is written and tested, and goes to [`macports/macports-ports`](https://github.com/macports/macports-ports) as a pull request. Until it is merged, `port install vigil` does not find it.

The Portfile is made from [`packaging/macports/Portfile.in`](https://github.com/godspeedhq/vigil/blob/main/packaging/macports/Portfile.in) by [`tools/release/portfile.sh`](https://github.com/godspeedhq/vigil/blob/main/tools/release/portfile.sh), which reads the release's archive for the RIPEMD-160 and size MacPorts asks for, and refuses an archive whose SHA-256 is not the one in the signed `SHA256SUMS`. Like the Homebrew formula, it builds nothing: it puts the scripts in place and writes a starting configuration.

| What | Where |
| --- | --- |
| The program, the port's | `/opt/local/libexec/vigil` |
| The `vigil` command | `/opt/local/bin/vigil` |
| Your configuration, scripts, state, logs and metrics | `/opt/local/var/vigil` |
| The service | the LaunchDaemon `org.macports.vigil`, as root, like the install script's system service |

- `sudo port load vigil` starts the service, and `sudo port unload vigil` stops it. `vigil status`, `stop`, `start` and `restart` find it.
- `sudo port selfupdate && sudo port upgrade vigil` updates it. MacPorts stops the service, swaps the versions and starts it again, and running jobs carry on.
- `sudo port uninstall vigil` removes the program and keeps `/opt/local/var/vigil`.

This is the macOS test machine, with test builds 0.5.3 and 0.5.4 of this port made from the branch that added it, beside the install script's Vigil (the Mac's name is replaced with `your-mac`):

```
$ sudo port -D ports-0.5.3/sysutils/vigil install
--->  Installing vigil @0.5.3_0
--->  Activating vigil @0.5.3_0
...
$ vigil about
Vigil 0.5.3
...
Installed   /opt/local/var/vigil
Program     /opt/local/libexec/vigil, by MacPorts
Platform    macOS, bash 3.2.57

$ vigil self update
vigil: Vigil was installed by MacPorts: update it with sudo port selfupdate && sudo port upgrade vigil

$ sudo vigil service install
vigil: MacPorts installed this service: start it with sudo port load vigil

$ sudo port -D ports-0.5.3/sysutils/vigil load
--->  Loading startupitem 'vigil' for vigil

$ vigil status
service: active, pid 39550 (launchd, system mode)

Vigil your-mac at 2026-11-07T23:09:03Z

$ sudo vigil stop; sudo vigil start
stopped vigil; running workers continue
started vigil

$ sudo port -D ports-0.5.4/sysutils/vigil install
--->  Installing vigil @0.5.4_0
--->  Unloading startupitem 'vigil' for vigil
--->  Deactivating vigil @0.5.3_0
--->  Activating vigil @0.5.4_0
$ sudo port -D ports-0.5.4/sysutils/vigil load
--->  Loading startupitem 'vigil' for vigil

$ vigil version; vigil status
Vigil 0.5.4
service: active, pid 40581 (launchd, system mode)

$ sudo port -D ports-0.5.4/sysutils/vigil unload
--->  Unloading startupitem 'vigil' for vigil

$ sudo port uninstall vigil @0.5.3_0; sudo port uninstall vigil @0.5.4_0
--->  Uninstalling vigil @0.5.3_0
--->  Deactivating vigil @0.5.4_0
--->  Uninstalling vigil @0.5.4_0
```

A port installed from its folder (`-D`) is outside the ports tree, so the commands name the folder, and `port upgrade`, which looks the port up in the tree, is its two steps: installing 0.5.4 over 0.5.3, which unloads, deactivates and activates, then loading again. The configuration edited before the upgrade was kept, and so was `/opt/local/var/vigil` after uninstalling. The install script's Vigil ran on throughout, and each `vigil status` found its own service.

CI does the same on every change, on MacPorts' own installer for the runner's macOS: [`tests/packages/macports.sh`](https://github.com/godspeedhq/vigil/blob/main/tests/packages/macports.sh), with `port lint --nitpick` first.

## 🥄 Scoop

```powershell
scoop bucket add vigil https://github.com/godspeedhq/scoop-vigil
scoop install vigil
vigil service install --user     # starts it at every logon
```

The manifest is made from [`packaging/scoop/vigil.json.in`](https://github.com/godspeedhq/vigil/blob/main/packaging/scoop/vigil.json.in) and published in the bucket [`godspeedhq/scoop-vigil`](https://github.com/godspeedhq/scoop-vigil). No administrator is needed. The Windows 11 test machine, 0.5.1, as a standard user, minutes after the release. A configuration was already in `~\scoop\persist\vigil` from an earlier install, so the installer kept it and wrote nothing:

```
PS> scoop bucket add vigil https://github.com/godspeedhq/scoop-vigil
Checking repo...
OK.
The vigil bucket was added successfully.

PS> scoop install vigil
Installing 'vigil' (0.5.1) [64bit] from 'vigil' bucket
Downloading https://github.com/godspeedhq/vigil/releases/download/v0.5.1/vigil-0.5.1.zip (619.3 KB)...
Checking hash of vigil-0.5.1.zip...
OK.
Extracting vigil-0.5.1.zip...
Done.
Running installer script...
Done.
Linking ~\scoop\apps\vigil\current => ~\scoop\apps\vigil\0.5.1
Creating shim for 'vigil'.
'vigil' (0.5.1) was installed successfully!

PS> vigil about
Vigil 0.5.1
...
Installed   C:\Users\vigil-test\scoop\persist\vigil
Program     C:\Users\vigil-test\scoop\apps\vigil\current, by Scoop
Platform    Windows, PowerShell 5.1

PS> vigil self update
vigil: Vigil was installed by Scoop: update it with scoop update vigil

PS> vigil service install --user
pre-flight checks:
...
precheck passed
registered the Vigil Run entry (C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe)
started vigil
note: user mode starts Vigil at logon and does not restart it if it stops; an administrator install (--system) does

PS> vigil status
service: active, pid 1160 (Run entry, user mode)

Vigil desktop-nn48drs at 2026-11-07T10:12:56Z

WAITING
  base_cpu: next 2026-11-07T10:13:00Z
  base_memory: next 2026-11-07T10:13:00Z
  base_disk: next 2026-11-07T10:15:00Z
  base_network: next 2026-11-07T10:13:00Z
  base_services: next 2026-11-07T10:13:00Z
```

- Your configuration, scripts, state and logs live in Scoop's persist folder, `~\scoop\persist\vigil`, so they survive every update.
- The logon entry runs `apps\vigil\current`, so after `scoop update vigil` it starts the new version, and a running supervisor reloads itself.
- `scoop uninstall vigil` removes the program and its logon entry and keeps your work; `scoop uninstall -p vigil` removes that too:
  ```
  PS> scoop uninstall vigil
  Uninstalling 'vigil' (0.5.1).
  Running uninstaller script... Done.
  Unlinking ~\scoop\apps\vigil\current
  'vigil' was uninstalled.
  removed the Vigil Run entry; running workers continue
  Removing shim 'vigil'.
  Removing shim 'vigil.cmd'.
  ```
- For a service that runs with nobody logged on, use the install script as an administrator: Scoop installs per user.

CI installs, updates and removes it on every change (`tests/packages/Scoop.ps1`).

## 🔄 How the tap and the bucket stay current

Both check for a new Vigil release every hour. Before writing anything, each verifies the release's `SHA256SUMS` against the release key it keeps, then writes the formula or manifest with [`tools/release/tap-bucket.sh`](https://github.com/godspeedhq/vigil/blob/main/tools/release/tap-bucket.sh) from that release's own tag. A change to either goes through this repository's review and CI, never straight into the tap or the bucket.

## 🗺️ Next

MacPorts, once the port is in the ports tree, is the last package manager planned: [backlog 30](https://github.com/godspeedhq/vigil/blob/main/backlog/30_package_managers.md). An MSI and winget wait for code signing: [backlog 33](https://github.com/godspeedhq/vigil/blob/main/backlog/33_signed_packages.md).
