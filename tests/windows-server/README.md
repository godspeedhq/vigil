# Windows Server test VMs

How each Windows Server version in [backlog 26](../../backlog/26_windows_server_versions.md) is made reachable and tested. The results go in [`windows-compatibility.md`](../integration/backends/reports/windows-compatibility.md).

## 1. The VM (its owner, once per VM)

1. In Hyper-V, connect the VM to an **internal** switch (or the Default Switch), never an external one: the VMs are reachable only from the Hyper-V host. Server 2008 R2, 2012 and 2012 R2 get no security updates, so this matters most for them.
2. **Server 2016 only:** install the OpenSSH server first. Windows offers none: take the MSI from [Win32-OpenSSH's releases](https://github.com/PowerShell/Win32-OpenSSH/releases). Server 2019 and later have it built in, and `Setup-Vm.ps1` installs it.
3. Copy `Setup-Vm.ps1` to the VM and run it from an elevated PowerShell, with the test key's public half:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-Vm.ps1 -PublicKey 'ssh-ed25519 AAAA...' -Administrator
   ```

   `-Administrator` lets the system-mode tests run (installing the service needs it). Leave it out to test user mode only. The account's password is random and never shown: the key is the only way in. `-Remove` undoes it.
4. Take a checkpoint named `clean`, to go back to before each run.

## 2. Reaching it

The VM is reached through the Hyper-V host, which already takes SSH as `vigil-test`:

```sh
ssh -J vigil-test@<Hyper-V host> vigil-test@<VM address>
```

Over SSH, the shell is `cmd`: chain commands with `&`, not `;`. Copy scripts over with `scp -J` and run them with `powershell -NoProfile -ExecutionPolicy Bypass -File`.

## 3. The tests, in order

1. **Prerequisites:** `Probe.ps1`, which changes nothing and needs no administrator. Its table goes in the report as it is.
2. **Install:** `install.ps1 -User`, then `-System` (with `-Administrator`): start, stop, restart, status, uninstall.
3. **The suites:** `tests\Run-Conformance.ps1`, then `tests\integration\*.ps1`, from a copy of the repository on the VM.
4. **The real backends:** `run-vigil.ps1 lgtm` and the store tests, through tunnels to the Docker host.
5. **WMI refused:** the native process route, as over SSH (2008 R2 and 2012 are expected to differ).

Restore the `clean` checkpoint between versions' runs, and between a failed run and the next.
