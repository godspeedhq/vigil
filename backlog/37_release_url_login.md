# 37. A release_url that needs a login

Asked by the owner on 2026-11-09, after 0.6.0's Artifactory test (backlog
35, "Found on the way" in 36).

## The problem

`release_url` (0.6.0) sends no credentials: a URL with a user or password in
it is refused, by design, and there is no other way to give one. So the
server must allow anonymous read. Most company Artifactory, Nexus or GitLab
servers don't, and the free Artifactory edition only lets anonymous read be
granted through its web UI (the permissions API is Pro-only). Today such a
fleet must either open the releases to anonymous read or use `release_path`
on a file share.

Anonymous read is not unsafe for Vigil itself: every file must be signed by
the installed release key, so a login protects nothing Vigil checks. It is a
company's rule about its own server, and a common one.

## Proposed

1. **The header pair a `https` source already has** (§6.9), under `[vigil]`:

   ```ini
   [vigil]
   release_url          = https://artifacts.example.com/artifactory/vigil
   release_header_name  = Authorization
   release_header_value = secret:VIGIL_RELEASES_AUTH
   ```

   The secret holds the whole value, as for a source: `Bearer <token>` for an
   Artifactory or GitLab token, `Basic <base64 of user:password>` for Nexus or
   a web server with basic auth, or the bare key for a header such as
   `X-JFrog-Art-Api`. One pair covers every server without Vigil knowing any
   of them.

   Not a `release_token` that always sends `Authorization: Bearer`: that fits
   Artifactory and GitLab but not Nexus or basic auth, and a second shape
   beside the source's would be one more thing to learn.

2. **`release_header_value` is a credential** (§6.5): `secret:`, `env:` or
   `store:` only, never a raw value, never echoed. `secret:` is the one to
   recommend, because an update runs both in the service (the notice,
   `version =`) and from a shell (`sudo vigil self update`). An `env:` value
   is in the service's environment but not in an admin's shell, so a hand-run
   update would fail without it.

3. **Sent only to the `release_url`'s host, and only over `https`** (or
   `http` to this machine, as now). Never on a command line: curl takes it on
   stdin (`curl -K -`), as the fetcher does; on Windows,
   `Invoke-WebRequest -Headers`.

4. **No redirects while a header is set**, as for a `https` source. curl
   keeps sending a custom header (anything but `Authorization`) to whatever
   host a redirect names, and the simple safe rule is not to follow one. A
   redirect is reported with its status and the URL's host, never the
   header. Artifactory serves from its own address unless it is set up to
   redirect to cloud storage ("direct cloud storage download"), which is off
   by default. Decide when building whether that case is worth handling
   (follow it without the header).

5. **Used by everything that reads `release_url`**: self update and its
   `--check`, the notice, `pack update` and `version =`.

6. **Errors that say which part failed.** A `401` or `403` names the
   release URL and says the server refused the login (`check
   release_header_value`), different from "cannot reach". A secret that
   can't be resolved is named, as for a job (`release_header_value
   secret:VIGIL_RELEASES_AUTH unavailable: not found`).

7. **Validation:**
   - `release_header_name` and `release_header_value` together, or neither.
   - Only with `release_url`: with `release_path`, or with neither (GitHub),
     it is an error. GitHub's releases need no login, and a share is reached
     as the account Vigil runs as.
   - The header name is a token (letters, digits, `-`), as for a source.

## Not included

- **The installers.** As now, they don't read `release_url`. A first install
  from a server that needs a login is done by fetching the files with the
  company's own tools, then `install.sh --archive <file> --key <pem>`.
- **Client certificates (mutual TLS).** Rare for an artifact server; ask
  when someone needs it.
- **A login for `release_path`.** A share is opened as the account Vigil
  runs as; that is the share's business, and the error already names the
  account (0.6.1).

## Tests

- The mock server gains a mode that requires a header and logs whether one
  came; it never logs the value.
- `self-update.sh` and `Self-Update.ps1`: with the header, `--check`, the
  update and `pack update --check` succeed; without it, or with a wrong one,
  the `401` message; a redirect is refused and the second host is never
  asked; the header never appears in the process list (POSIX: the curl
  command line is checked) or in any output.
- `version-config.sh` and `Version-Config.ps1`: a fetched configuration with
  the pair moves the machine to a release served only with a login.
- Conformance: the pair with `release_path`, without `release_url`, only one
  of the two, and a raw value in `release_header_value`.
- Optional: the same Artifactory OSS 7.77.17 container as 0.6.0's notes,
  with anonymous read off and an access token, from Fedora.

## Done when

- A fleet whose release server needs a token or a password updates from it
  (by hand, by `version =`, from the notice) and updates its packs, on
  Linux, macOS and Windows.
- The credential is never on a command line, in a log, in an error or sent
  to another host.
- The specification (§18.7) and the README's "A fleet that doesn't reach
  GitHub" describe it, and the README's anonymous-read note points to it.
