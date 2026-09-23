#!/usr/bin/env bash
# Publishes files to the rolling `nightly` prerelease.
#
#   publish-nightly.sh <component> <summary> <file>...
#
# Both Flutter-build.yml and Python-build.yml call this, each for its own
# files. Asset names are fixed so download URLs never change, and --clobber
# replaces the previous night's copy. The release notes keep one line per
# component, so one workflow never wipes out what the other wrote.
#
# The release must stay a prerelease: Config.py reads /releases/latest and
# parses the tag as a float, which "nightly" is not. /releases/latest never
# returns a prerelease.
#
# Callers must serialise on `concurrency: nightly-release`, otherwise two runs
# can both see "no release" and race to create it.
#
# Needs GH_TOKEN (contents: write) and a checkout whose origin can be pushed to.

set -euo pipefail

TAG=nightly
component=$1
summary=$2
shift 2

# Move the tag to this run's commit. The tag only says where the most recent
# publish came from; each component's own commit is in the notes.
git tag -f "${TAG}" "${GITHUB_SHA}"
git push -f origin "refs/tags/${TAG}"

if ! gh release view "${TAG}" >/dev/null 2>&1; then
  gh release create "${TAG}" --prerelease --title "Nightly" \
    --notes "master 每次推送自動建置，未經測試。檔名固定，下載網址不會變。"
fi

gh release upload "${TAG}" "$@" --clobber

# Replace this component's line in the notes, keep everything else.
line="- **${component}**: ${summary} · $(date -u +'%Y-%m-%d %H:%M UTC') · ${GITHUB_SHA::7} · [run](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
body=$(gh release view "${TAG}" --json body -q .body | grep -v -F -- "- **${component}**:" || true)
printf '%s\n%s\n' "${body}" "${line}" > notes.md
gh release edit "${TAG}" --prerelease --notes-file notes.md
rm -f notes.md
