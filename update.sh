#!/usr/bin/env zsh
# Updates the app, preferring GitHub Releases and falling back to a git pull.
#
# Releases are the path that works for everyone: a zip install has no remote to
# pull from, and comparing published versions is clearer than comparing commits.
# The repo is private, so the download needs the gh CLI's credentials; without
# gh it falls back to pulling a checkout.
#
# Writes "phase|detail||" to the progress file like the other actions.
set -uo pipefail
source "${0:A:h}/paths.sh"
# Local previews must never contact the retired release server.
[[ "${BEATBAR_LOCAL_ONLY:-}" == "1" || "${LOCAL_ONLY:-}" == true ]] && exit 0

REPO="Alexsometimescode/scrollback"
export GH_HOST="${GH_HOST:-github.groupondev.com}"

say() { print -r -- "$1" > "$PROG"; }

# Which app to replace. Getting this wrong is not harmless: an earlier version
# fell through to /Applications, compared against a bundle that was not there,
# decided every check was an update, and wrote a stray copy.
app=""
if [[ "$BEAT_HOME" == */Contents/Resources/scripts ]]; then
  app="${BEAT_HOME:h:h:h}"                 # scripts bundled inside the app
else
  for c in "${BEAT_HOME}/Scrollback/Scrollback.app" \
           "${BEAT_HOME}/Scrollback.app" \
           "${BEAT_HOME}/Scrollback/Scrollback.app" \
           "${BEAT_HOME}/Scrollback.app" \
           "${BEAT_HOME:h}/Scrollback.app" \
           "${BEAT_HOME:h}/Scrollback.app" \
           "/Applications/Scrollback.app" \
           "/Applications/Scrollback.app"; do
    [[ -d "$c" ]] && { app="$c"; break; }
  done
fi
[[ -d "$app" ]] || { say "Cannot find the app|nothing to update||"; exit 2; }

here=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || print 0.0.0)

restart() { ( sleep 1; pkill -x Scrollback; sleep 1; open "$app" ) >/dev/null 2>&1 & }

# --check answers "is there a newer one" and installs nothing. The app polls this
# quietly in the background so it can offer the update instead of waiting to be
# asked: nothing told anyone a release existed, so people sat on old versions.
# Prints CURRENT|x and, when there is one, LATEST|y. Silent about anything else.
# --summary counts what the newest release changed, straight from CHANGELOG.md,
# so the offer says "3 fixes · 2 added" without anyone typing numbers.
if [[ "${1:-}" == "--summary" ]]; then
  cl=""
  d="$BEAT_HOME"
  for _ in 1 2 3 4; do
    [[ -f "$d/CHANGELOG.md" ]] && { cl="$d/CHANGELOG.md"; break; }
    d="${d:h}"
  done
  [[ -z "$cl" ]] && exit 0
  # the first "## x.y.z" block only
  blk=$(awk '/^## /{n++} n==1' "$cl")
  fixes=$(print -r -- "$blk" | awk '/^### Fixed/{f=1;next} /^### /{f=0} f&&/^- /{c++} END{print c+0}')
  added=$(print -r -- "$blk" | awk '/^### Added/{a=1;next} /^### /{a=0} a&&/^- /{c++} END{print c+0}')
  out=()
  (( fixes )) && out+=("${fixes} fix$([[ $fixes -ne 1 ]] && print es)")
  (( added )) && out+=("${added} added")
  (( ${#out} )) && print -r -- "${(j: · :)out}"
  exit 0
fi

if [[ "${1:-}" == "--check" ]]; then
  print -r -- "CURRENT|${here}"
  d="$BEAT_HOME"
  for _ in 1 2 3 4; do
    if [[ -d "$d/.git" ]]; then
      u=$(git -C "$d" remote get-url origin 2>/dev/null)
      if [[ "$u" == *scrollback* ]]; then
        # A checkout: newer means the remote has commits we do not.
        git -C "$d" fetch -q origin 2>/dev/null
        b=$(git -C "$d" rev-parse HEAD 2>/dev/null)
        r=$(git -C "$d" rev-parse '@{u}' 2>/dev/null)
        [[ -n "$r" && "$b" != "$r" ]] && print -r -- "LATEST|$(git -C "$d" show '@{u}:VERSION' 2>/dev/null | tr -d '[:space:]')"
        exit 0
      fi
    fi
    d="${d:h}"
  done
  if command -v gh >/dev/null 2>&1; then
    l=$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null | sed 's/^v//')
    [[ -n "$l" && "$l" != "$here" ]] && print -r -- "LATEST|${l}"
  fi
  exit 0
fi

# --- a git checkout updates itself, and must do so BEFORE the release path.
# Every judgement in this tool lives in a shell script, and the app prefers the
# checkout's scripts over the copy bundled in the .app. Downloading the release
# replaces only the .app, so a cloned install used to end up running a new binary
# against the old scripts: the half that decides anything never moved.
inrepo=""
d="$BEAT_HOME"
for _ in 1 2 3 4; do
  if [[ -d "$d/.git" ]]; then
    u=$(git -C "$d" remote get-url origin 2>/dev/null)
    [[ "$u" == *scrollback* ]] && { inrepo="$d"; break; }
  fi
  d="${d:h}"
done

# --- preferred: the latest published release
if [[ -z "$inrepo" ]] && command -v gh >/dev/null 2>&1; then
  say "Checking for updates|installed v${here}||"
  latest=$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null | sed 's/^v//')
  if [[ -n "$latest" ]]; then
    if [[ "$latest" == "$here" ]]; then
      say "Up to date|v${here} is the latest||"
      exit 0
    fi
    say "Downloading|v${here} to v${latest}||"
    tmp=$(mktemp -d) || exit 1
    if gh release download --repo "$REPO" --pattern 'Scrollback.app.zip' --dir "$tmp" --clobber 2>/dev/null; then
      ditto -x -k "$tmp/Scrollback.app.zip" "$tmp" && [[ -d "$tmp/Scrollback.app" ]] || {
        say "Update failed|the download could not be unpacked||"; rm -rf "$tmp"; exit 1; }
      rm -rf "$app" && cp -R "$tmp/Scrollback.app" "$app"
      rm -rf "$tmp"
      say "Restarting|now on v${latest}||"
      restart
      exit 0
    fi
    say "Download failed|could not fetch the release, check gh auth||"
  fi
fi

# --- a checkout: pull it, which moves the scripts and the prebuilt app together
root="$inrepo"
[[ -z "$root" ]] && { say "No update source|install gh, or clone the repo||"; exit 2; }

say "Checking for updates|${root:t}||"
before=$(git -C "$root" rev-parse --short HEAD 2>/dev/null)
git -C "$root" pull --ff-only -q 2>/dev/null || {
  say "Could not update|pull failed, check the network or local changes||"; exit 1; }
after=$(git -C "$root" rev-parse --short HEAD 2>/dev/null)
[[ "$before" == "$after" ]] && { say "Up to date|v${here}||"; exit 0; }

[[ -f "$root/Scrollback.app.zip" ]] && ditto -x -k "$root/Scrollback.app.zip" "$root"
say "Restarting|updated||"
restart
exit 0
