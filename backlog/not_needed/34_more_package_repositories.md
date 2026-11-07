# 34. More package repositories and a macOS .pkg

Not needed (owner, 2026-11-07): after MacPorts, packages are done. These
were steps of backlog 30.

| Format | Why it was considered | Why not |
| --- | --- | --- |
| Fedora COPR | `dnf upgrade` would update Vigil with the system | The `.rpm` installs, `vigil self update` updates the install script's Vigil, and a fleet follows the version in its configuration |
| An apt repository | `apt upgrade` would, on Debian and Ubuntu | The same, for the `.deb`; it would also need a GPG key and somewhere to host the repository |
| Chocolatey | `choco install vigil` on Windows | Scoop covers Windows without an administrator, and Chocolatey reviews every version by hand, for days |
| macOS `.pkg`, for Jamf, Intune and Kandji | A file an MDM can push | It needs an Apple Developer ID to sign and notarize; MacPorts and Homebrew cover macOS |

Any of them can come back as a backlog item of its own if a user asks for it.
