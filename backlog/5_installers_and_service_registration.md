# Installers, service registration, `vigil init`

## Scope
- Linux (systemd), macOS (launchd), Windows (NSSM) service registration.
- Windows: the host is a choice (`powershell` or `pwsh`), used for the
  service, supervisor, workers and the generated `.ps1` runner; never a
  silent fallback to 5.1.
- `vigil precheck` runs before the service is started; failure stops install.
- `vigil init`: a starter configuration.

## Done when
- Install, start, stop, uninstall tested on each platform in CI.
