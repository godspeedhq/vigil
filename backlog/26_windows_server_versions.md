# 26. Windows Server versions: test what the specification claims

## Why

The specification (§2, platform support) states, for Windows:

| Version | What it claims | Tested today |
| --- | --- | --- |
| Server 2016, 2019, 2022, 2025; Windows 10 and 11 | Supported, PowerShell 5.1 built in | Windows 11 (development and the test machine), and GitHub's `windows-latest` runner |
| Server 2012 / 2012 R2 | Supported once WMF 5.1 is installed | **No** |
| Server 2008 R2 SP1 / Windows 7 SP1 | Best effort with WMF 5.1: documented, not tested | **No** |

The claims for 2012 and 2008 R2 are untested. Running Vigil on each turns them into evidence or corrects them. The older versions also show the real failure modes: TLS 1.2 defaults in .NET and Schannel, no OpenSSH client, old certificate stores, PowerShell 5.1 installed rather than built in.

## The machines

Hyper-V VMs on the Windows 11 Pro test machine:

| Version | Status | Note |
| --- | --- | --- |
| Server 2025 | in Hyper-V | supported; OpenSSH built in |
| Server 2016 | in Hyper-V | supported; OpenSSH not built in (install Win32-OpenSSH, or reach it over PowerShell remoting) |
| Server 2012 R2, 2012 | dropped (2026-11-12) | not supported: below the Server 2016 floor |
| Server 2008 R2 | tried and dropped (2026-11-12) | not supported: below the Server 2016 floor |
| Server 2019, 2022 | suggested | the most common in production today |

Both Desktop Experience and Server Core where the version has both: Core lacks some of what Desktop has, and Vigil must not depend on it.

## Rules

- **Isolation.** The out-of-support versions (2008 R2, 2012, 2012 R2) get no security updates, so they live on a Hyper-V internal or private switch, never exposed to the internet or the wider network. Every VM is reachable only from the test machine and this laptop, and is snapshotted before each test so it can be reset.
- **Licensing is the user's.** Use evaluation media or licences you hold. Microsoft no longer offers evaluation downloads for 2008 R2 and 2012; nothing here obtains media.
- **No changes to Vigil to make an old version pass.** A version that fails is documented, with why, and the specification's support table is corrected to match. If a fix is cheap and safe, it's proposed separately, as a change of its own.

## Tests on each version

1. **Prerequisites:** the PowerShell version (`$PSVersionTable`), .NET Framework version, TLS 1.2 available and on by default, and the OpenSSH client present or not.
2. **Install:** `install.ps1` in user mode and in system mode (NSSM service); start, stop and restart; uninstall.
3. **The suites:** `tests/Run-Conformance.ps1`, and the Windows integration tests (`tests/integration/*.ps1`).
4. **The real-backend tests,** through tunnels to the Docker host: `run-vigil.ps1 lgtm`, `run-store.ps1` for each store, and `run-source.ps1` for each source once it exists (backlog task 25). These cover TLS against modern servers, certificate trust, and git and sftp where they can be installed.
5. **Under WMI refusal,** as over SSH (backlog/fixed/23): the native process route on each version (`NtQueryInformationProcess` command lines need Windows 8.1 or Server 2012 R2 and later, so **2008 R2 and 2012 are expected to differ here**).

## Results

A matrix in `tests/integration/backends/reports/windows-compatibility.md`:
- **For each version:** prerequisites, install, conformance, integration, backends, stores, sources, and the result.
- **Results:** Supported (passes), Works with caveats (named), or Not supported (why).

The specification's support table is then updated to say what was shown, version by version.

## Progress

- Written 2026-11-03. Waiting for the VMs: 2016 and 2025 fetched; 2012, 2012 R2 and 2008 R2 to fetch.
- 2026-11-07: 2016 and 2025 are installed in Hyper-V on the Windows 11 test
  machine. Only one can run at a time there, so the versions are tested one
  after the other, never side by side. Next: the owner makes each reachable
  over SSH as `vigil-test`.
- 2026-11-08: ready for the VMs. `tests/windows-server/Setup-Vm.ps1` (run once
  on each VM, elevated) makes it reachable over SSH as `vigil-test`, by key
  only, from the local subnet; `Probe.ps1` records step 1; the steps are in
  `tests/windows-server/README.md`, and the results go in
  `tests/integration/backends/reports/windows-compatibility.md`.
- 2026-11-10 to 11: Server 2016 VM run (backlog 48). 2026-11-11: the Server
  2025 VM set up and Vigil 0.7.0 installed, but too slow in Hyper-V to test;
  it moves to a physical machine.
- 2026-11-12: Server 2016 is the floor (backlog 49). Server 2008 R2 was tried
  on a physical machine and dropped (PowerShell 2.0, no service pack); 2012
  and 2012 R2 dropped too. Server 2016 run on that physical machine instead.
  Left: Server 2025 on real hardware; 2019 and 2022.
