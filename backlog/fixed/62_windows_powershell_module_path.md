# 62. Windows PowerShell started with PowerShell 7's module folders

Found on 2026-11-20, testing the redis pack on Windows: under Windows
PowerShell 5.1, `vigil secret set` failed with

```text
vigil: The 'ConvertFrom-SecureString' command was found in the module 'Microsoft.PowerShell.Security', but the module could not be loaded. For more information, run 'Import-Module Microsoft.PowerShell.Security'.
```

and every job with a `secret:` reference failed, saying the secret "cannot
be decrypted by this account on this machine; set it again", which was not
the cause.

## Why

Windows PowerShell 5.1 started by something that PowerShell 7 started (a
terminal, an editor, Git Bash, a tool's shell) inherits `PSModulePath` with
PowerShell 7's module folders ahead of its own:

```text
C:\Users\<you>\Documents\PowerShell\Modules
C:\Program Files\PowerShell\Modules
C:\Program Files\PowerShell\7\Modules
C:\Program Files (x86)\WindowsPowerShell\Modules
C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules
```

Asked for `ConvertTo-SecureString`, it autoloads `Microsoft.PowerShell.Security`
from the first folder that has it, PowerShell 7's, which it cannot load. The
same module holds `Get-Acl` and `Set-Acl`, so `vigil service install` and
`install.ps1`, which protect folders with them, failed the same way.

PowerShell 7 drops its own folders from `PSModulePath` when it starts
Windows PowerShell itself, so a 5.1 started straight from PowerShell 7, or
from Explorer, the service manager or a scheduled task, is fine. Only a 5.1
started further down such a chain is not.

## The fix

Under Windows PowerShell, `vigil.ps1` drops PowerShell 7's module folders
from `PSModulePath` before anything else (entries ending
`\PowerShell\Modules` or `\PowerShell\<7...>\Modules`; Windows PowerShell's
own end `\WindowsPowerShell\...`), as PowerShell 7 does. Every process Vigil
starts inherits the cleaned path. `install.ps1` does the same while it runs,
and puts the caller's path back at the end, as it does its preferences.

## Done

- `tests/integration/Secrets.ps1`, step 5c: Windows PowerShell 5.1, started by
  .NET with PowerShell 7's `Modules` folder first in `PSModulePath` (PowerShell
  7 itself would clean it), sets a secret, which is stored, and runs a job
  that reads secrets, which succeeds. Before the fix: 26 passed, 3 failed, with
  the message above; after: 29 passed, 0 failed, run from Windows PowerShell
  5.1 and from PowerShell 7 (2026-11-20, on the Windows 11 laptop). Skipped
  where PowerShell 7 is not installed.
- By hand, from Git Bash on the same laptop: `vigil secret set` under 5.1,
  which failed before, sets the secret.
