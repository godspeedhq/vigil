# Windows code signing

Authenticode on Vigil's own `.ps1` files, so they run under `AllSigned`
(spec 17). It covers Windows files only; `11` covers every platform.

## Scope
- Bought as an individual, so the publisher shown is the legal name; GodspeedHQ
  is not a registered company. Azure Artifact Signing takes individuals only
  in the US or Canada, so an OV certificate is the likely route from the UK.
- It must work from CI: certificates now need a token or cloud signing.

## Done when
- A release installs and runs on a Windows host set to `AllSigned`.
