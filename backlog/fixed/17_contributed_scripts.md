# Contributed scripts

People contribute scripts that become part of the packs. Contributors sign
nothing and hold no keys: a script is reviewed and merged, and the release
pipeline signs it. A signature means the project reviewed it.

## Scope
- The rules for a contributed script: review, tests, metric naming.
- Protected `main`, so nothing reaches a signed release unreviewed.

## Done when
- A contribution guide exists, and a pack release is signed only from
  reviewed code.

## Closed

2026-11-04.

- **The guide:** `CONTRIBUTING.md`, with the rules for a contributed script (what it may use and do, metric naming, the header, the tests), the review checklist, and how a script reaches a signed release.
- **Protected `main`:** a repository ruleset, in force since 2026-11-01, takes changes to `main` only as pull requests that pass all four CI jobs, and forbids force-pushes and deleting it. Contributors cannot merge, so a maintainer reviews what reaches `main`.
- **Signed only from reviewed code:** the release workflow builds and signs only a tag on `main` (`git merge-base --is-ancestor`), so nothing unreviewed is signed.
