#!/usr/bin/env bash
#
# build.sh - generates the documentation site from the repository.
#
#   bash tools/docs/build.sh [<out dir>]      default: .site
#
# Everything on the site comes from the code and the documents beside it,
# so it is never edited by hand and never out of date once rebuilt:
#
#   Home            README.md
#   Vision          VISION.md
#   Specification   SPECIFICATION.md, one page per numbered section
#   Commands        the usage headers of app/vigil and app/vigil.ps1
#   Error codes     every code the validator can report (validate.sh), with
#                   its meaning from the specification and the conformance
#                   cases that exercise it
#   Status          README's "What works today", and the backlog
#   Tests           the conformance suites and integration tests, from
#                   their own headers
#   Examples        the annotated configurations in tests/mocks
#
# The output is Markdown with front matter for Jekyll and the Just the Docs
# theme; tools/docs/publish.sh, through .github/workflows/pages.yml, turns
# it into the GitHub Pages site. Needs only bash, awk, sed and git.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:-$repo/.site}
blob=https://github.com/godspeedhq/vigil/blob/main
tree=https://github.com/godspeedhq/vigil/tree/main

commit=$(git -C "$repo" rev-parse --short HEAD 2> /dev/null || printf unknown)
built=$(date -u '+%Y-%m-%d %H:%M UTC')

rm -rf "$out"
mkdir -p "$out/spec" "$out/reference"

# Front matter, then the body inside raw tags so Liquid never reads it.
page() {
    local file=$1
    shift
    {
        printf -- '---\n'
        for kv in "$@"; do printf '%s\n' "$kv"; done
        printf -- '---\n\n{%% raw %%}\n'
        cat
        printf '\n{%% endraw %%}\n'
    } > "$out/$file"
}

# Rewrites links for the site: the specification to its pages, other
# repository files to GitHub, and drops the document's own title line.
relink() {
    sed -E \
        -e 's#\]\(SPECIFICATION\.md\)#](/vigil/spec/)#g' \
        -e 's#\]\(VISION\.md\)#](/vigil/vision/)#g' \
        -e 's#\]\(README\.md\)#](/vigil/)#g' \
        -e 's#\]\(LICENSE\)#]('"$blob"'/LICENSE)#g' \
        -e 's#\]\(([A-Za-z0-9_.-]+/)([^):]*)\)#]('"$tree"'/\1\2)#g'
}

# --- Home, Vision -----------------------------------------------------------

sed '1{/^# /d;}' "$repo/README.md" | relink |
    page index.md 'title: Home' 'layout: home' 'nav_order: 1' 'permalink: /'
sed '1{/^# /d;}' "$repo/VISION.md" | relink |
    page vision.md 'title: Vision' 'nav_order: 2' 'permalink: /vision/'

# --- Specification, one page per "## N. Title" -----------------------------

awk -v dir="$out/spec" '
    function flush() { if (file != "") close(file) }
    function fm(title, order, link) {
        printf "---\ntitle: \"%s\"\nparent: Specification\nnav_order: %d\npermalink: %s\n---\n\n{%% raw %%}\n", title, order, link > file
    }
    BEGIN {
        file = dir "/index.md"
        printf "---\ntitle: Specification\nnav_order: 3\nhas_children: true\npermalink: /spec/\n---\n\n{%% raw %%}\n" > file
    }
    NR == 1 && /^# / { next }
    /^## [0-9]+\. / {
        printf "\n{%% endraw %%}\n" > file
        flush()
        n = $2; sub(/\.$/, "", n)
        title = $0; sub(/^## /, "", title); gsub(/"/, "\\\"", title)
        slug = sprintf("%02d", n)
        file = dir "/" slug ".md"
        fm(title, n, "/spec/" slug "/")
        print "# " substr($0, 4) > file
        next
    }
    /^```/ { fence = !fence }
    # A section page starts at "#": its subsections move up a level.
    !fence && slug != "" && /^###/ { sub(/^#/, "") }
    { print > file }
    END { printf "\n{%% endraw %%}\n" > file }
' "$repo/SPECIFICATION.md"
for f in "$out"/spec/*.md; do
    relink < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

# --- Commands ---------------------------------------------------------------

{
    printf '# Commands\n\n'
    printf 'Taken from the usage text of the commands themselves. Linux and macOS: [`app/vigil`](%s/app/vigil). Windows: [`app/vigil.ps1`](%s/app/vigil.ps1).\n\n' "$blob" "$blob"
    printf '## Linux and macOS\n\n```text\n'
    # The comment block after the shebang, up to the first non-comment line.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$repo/app/vigil" |
        sed '/^vigil - /d' | awk 'NF || seen { seen = 1; print }'
    printf '```\n\n## Windows\n\n```text\n'
    awk '/^\.DESCRIPTION/ { on = 1; next } /^#>/ { exit } on { sub(/^    /, ""); print }' "$repo/app/vigil.ps1"
    printf '```\n'
} | page reference/commands.md 'title: Commands' 'parent: Reference' 'nav_order: 1' 'permalink: /reference/commands/'

# --- Error codes --------------------------------------------------------------

{
    printf '# Error codes\n\n'
    printf 'Every code the configuration validator can report, found in [`validate.sh`](%s/app/lib/posix/validate.sh) (its twin `Validate.ps1` reports the same). *Meaning* is the row of the specification that names the code; *Tested by* counts the conformance cases whose expected output contains it.\n\n' "$blob"
    printf '| Code | Meaning | Tested by |\n| --- | --- | --- |\n'
    grep -o 'E_[A-Z0-9_]*[A-Z0-9]' "$repo/app/lib/posix/validate.sh" | sort -u | while read -r code; do
        meaning=$(grep -F -- "\`$code\`" "$repo/SPECIFICATION.md" | grep '^|' | head -n 1 |
            awk -F'|' '{ m = $(NF - 1); gsub(/^ +| +$/, "", m); print m }')
        [ -n "$meaning" ] || meaning=$(grep -F -- "\`$code\`" "$repo/SPECIFICATION.md" | head -n 1 | cut -c1-200)
        [ -n "$meaning" ] || meaning='*not in the specification*'
        cases=$(grep -rlF -- "$code" "$repo/tests/conformance" --include='*.expected' 2> /dev/null | wc -l | tr -d ' ')
        [ "$cases" = 0 ] && cases='**none**'
        printf '| `%s` | %s | %s |\n' "$code" "$(printf '%s' "$meaning" | tr '|' '/')" "$cases"
    done
} | relink | page reference/errors.md 'title: Error codes' 'parent: Reference' 'nav_order: 2' 'permalink: /reference/errors/'

printf '# Reference\n\nGenerated from the code: the commands, the error codes, the tests and the example configurations.\n' |
    page reference/index.md 'title: Reference' 'nav_order: 4' 'has_children: true' 'permalink: /reference/'

# --- Tests ----------------------------------------------------------------------

{
    printf '# Tests\n\n'
    printf 'Two layers keep the bash and PowerShell implementations honest. CI runs both on Linux, macOS (bash 3.2), Windows PowerShell 5.1 and PowerShell 7 for every pull request.\n\n'
    printf '## Conformance suites\n\nThe same inputs go to both implementations, which must produce byte-identical output ([`tests/conformance`](%s/tests/conformance)).\n\n' "$tree"
    printf '| Suite | Cases |\n| --- | --- |\n'
    total=0
    for d in "$repo"/tests/conformance/*/; do
        n=$(find "$d" -name '*.expected' | wc -l | tr -d ' ')
        total=$((total + n))
        printf '| [`%s`](%s/tests/conformance/%s) | %s |\n' "$(basename "$d")" "$tree" "$(basename "$d")" "$n"
    done
    printf '| **Total** | **%s** |\n\n' "$total"
    printf '## Integration tests\n\nReal jobs, a real supervisor, real services ([`tests/integration`](%s/tests/integration)). Each has a bash and a PowerShell twin.\n\n' "$tree"
    for f in "$repo"/tests/integration/*.sh; do
        name=$(basename "$f")
        printf '### %s\n\n' "$name"
        awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$f" |
            sed -e '/^Exit code:/d' | awk 'NF || seen { seen = 1; print }'
        printf '\n'
    done
} | relink | page reference/tests.md 'title: Tests' 'parent: Reference' 'nav_order: 3' 'permalink: /reference/tests/'

# --- Examples ------------------------------------------------------------------

{
    printf '# Example configurations\n\nThe annotated configurations in [`tests/mocks`](%s/tests/mocks), checked by the conformance suite.\n\n' "$tree"
    find "$repo/tests/mocks" -name '*.config' | sort | while read -r f; do
        rel=${f#"$repo"/}
        printf '## %s\n\n```ini\n' "${rel#tests/mocks/}"
        cat "$f"
        printf '```\n\n'
    done
} | page reference/examples.md 'title: Examples' 'parent: Reference' 'nav_order: 4' 'permalink: /reference/examples/'

# --- Status ------------------------------------------------------------------------

{
    printf '# Status\n\n## What works today\n\n'
    awk '/^## What works today/ { on = 1; next } on && /^(## |---)/ { exit } on' "$repo/README.md"
    printf '\n## Backlog\n\nOpen work, in order ([`backlog/`](%s/backlog)).\n\n' "$tree"
    for f in "$repo"/backlog/*.md; do
        [ -f "$f" ] || continue
        title=$(sed -n '1s/^# //p' "$f")
        printf -- '- **%s** — %s\n' "$(basename "$f" .md | cut -d_ -f1)" "$title"
    done
    printf '\n## Done\n\n'
    for f in "$repo"/backlog/fixed/*.md; do
        [ -f "$f" ] || continue
        printf -- '- %s\n' "$(sed -n '1s/^# //p' "$f")"
    done
} | relink | page status.md 'title: Status' 'nav_order: 5' 'permalink: /status/'

# --- Site configuration ----------------------------------------------------------

cat > "$out/_config.yml" <<EOF
title: Vigil
description: A lightweight cross-platform job scheduler, supervisor and metrics forwarder, built only from OS-native scripts.
baseurl: /vigil
remote_theme: just-the-docs/just-the-docs@v0.10.1
# Just the Docs' built-in dark scheme.
color_scheme: dark
plugins:
  - jekyll-remote-theme
search_enabled: true
heading_anchors: true
aux_links:
  GitHub: https://github.com/godspeedhq/vigil
footer_content: "Generated from <a href=\"https://github.com/godspeedhq/vigil/commit/$commit\">$commit</a> on $built. Apache License 2.0."
markdown: kramdown
kramdown:
  input: GFM
  hard_wrap: false
EOF

printf 'built %s pages in %s from %s\n' "$(find "$out" -name '*.md' | wc -l | tr -d ' ')" "$out" "$commit"
