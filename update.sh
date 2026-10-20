#!/usr/bin/env zsh
# Updates packaged apps from public GitHub releases. Source checkouts require
# an explicit update and local rebuild so scripts and the binary stay together.
#
# Writes "phase|detail||" to the progress file like the other actions.
set -uo pipefail
# Local previews must never contact the retired release server.
[[ "${BEATBAR_LOCAL_ONLY:-}" == "1" || "${LOCAL_ONLY:-}" == true ]] && exit 0
source "${0:A:h}/paths.sh"

REPO="https://github.com/Alexsometimescode/scrollback"
PUBLIC_GIT="https://github.com/Alexsometimescode/scrollback.git"
export GH_HOST="github.com"

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

valid_version() { [[ "$1" == <->.<->.<-> ]]; }
newer_release() {
  valid_version "$1" && valid_version "$here" || return 1
  autoload -Uz is-at-least
  ! is-at-least "$1" "$here"
}

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

# A checkout may only use the public project. Reject other remotes locally,
# before any fetch, pull or release lookup. Worktrees use a .git file.
inrepo=""
d="$BEAT_HOME"
for _ in 1 2 3 4; do
  if [[ -e "$d/.git" ]]; then
    u=$(git -C "$d" remote get-url origin 2>/dev/null)
    case "$u" in
      https://github.com/Alexsometimescode/scrollback|https://github.com/Alexsometimescode/scrollback.git|git@github.com:Alexsometimescode/scrollback.git)
        inrepo="$d"; break ;;
      *) say "Update unavailable|checkout must use the public Scrollback repository||"; exit 2 ;;
    esac
  fi
  d="${d:h}"
done

if [[ "${1:-}" == "--check" ]]; then
  print -r -- "CURRENT|${here}"
  if [[ -n "$inrepo" ]]; then
    # Only a successful public-main fetch can establish a remote update.
    git -C "$inrepo" fetch -q "$PUBLIC_GIT" main 2>/dev/null || exit 1
    b=$(git -C "$inrepo" rev-parse HEAD 2>/dev/null)
    r=$(git -C "$inrepo" rev-parse FETCH_HEAD 2>/dev/null)
    if [[ -n "$b" && -n "$r" && "$b" != "$r" ]] &&
       git -C "$inrepo" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
      l=$(git -C "$inrepo" show FETCH_HEAD:VERSION 2>/dev/null | tr -d '[:space:]')
      valid_version "$l" && print -r -- "LATEST|${l}"
    fi
    exit 0
  fi
  if command -v gh >/dev/null 2>&1; then
    release_tag=$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null) || exit 1
    l="${release_tag#v}"
    newer_release "$l" && print -r -- "LATEST|${l}"
  fi
  exit 0
fi

# Pulling source alone cannot update the compiled Swift app. Leave checkouts
# unchanged and report the required build instead of claiming a binary update.
if [[ -n "$inrepo" ]]; then
  say "Source build required|update the public checkout and rebuild with Scrollback/build.sh||"
  exit 2
fi
# --- preferred: the latest published release
if [[ -z "$inrepo" ]] && command -v gh >/dev/null 2>&1; then
  say "Checking for updates|installed v${here}||"
  latest_tag=$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null) || {
    say "Update unavailable|public release lookup failed; installed app unchanged||"
    exit 1
  }
  latest="${latest_tag#v}"
  if valid_version "$latest"; then
    if ! newer_release "$latest"; then
      say "No newer release|installed v${here}||"
      exit 0
    fi
    say "Downloading|v${here} to v${latest}||"
    tmp=$(mktemp -d) || exit 1
    if gh release download "$latest_tag" --repo "$REPO" --pattern 'Scrollback.app.zip' --dir "$tmp" --clobber 2>/dev/null; then
      ditto -x -k "$tmp/Scrollback.app.zip" "$tmp" && [[ -d "$tmp/Scrollback.app" ]] || {
        say "Update failed|the download could not be unpacked||"; rm -rf "$tmp"; exit 1; }
      # Stage on the app's filesystem. Copy failure must leave the old app intact.
      stage=$(mktemp -d "${app:h}/.scrollback-update.XXXXXX") || {
        say "Update failed|cannot stage the new app||"; rm -rf "$tmp"; exit 1; }
      if ! cp -R "$tmp/Scrollback.app" "$stage/Scrollback.app"; then
        say "Update failed|could not copy the new app; installed app unchanged||"
        rm -rf "$tmp" "$stage"; exit 1
      fi
      if ! mv "$app" "$stage/previous.app"; then
        say "Update failed|could not replace the installed app||"
        rm -rf "$tmp" "$stage"; exit 1
      fi
      if ! mv "$stage/Scrollback.app" "$app"; then
        mv "$stage/previous.app" "$app" 2>/dev/null || {
          say "Update failed|old app preserved at ${stage}/previous.app||"
          rm -rf "$tmp"; exit 1; }
        say "Update failed|previous app restored||"
        rm -rf "$tmp" "$stage"; exit 1
      fi
      rm -rf "$stage"
      rm -rf "$tmp"
      say "Restarting|now on v${latest}||"
      restart
      exit 0
    fi
    say "Download failed|could not fetch the release, check gh auth||"
  fi
fi

say "Update unavailable|no public release could be installed; source builds require a local rebuild||"
exit 2
