#!/bin/sh
#
# Sissy — records which repository a CLI session's working directory belongs
# to, from inside that directory, while it still exists.
#
# Installed under Sissy's own Application Support directory and run by Claude
# Code and Codex at SessionStart. It answers the one question Sissy cannot
# answer later: a worktree created and deleted while Sissy was not running
# leaves nothing on disk to walk up from, and its spend is counted against
# nothing. This writes the pair down before that can happen.
#
# It writes only into a directory Sissy has already created, so an install
# whose data has been deleted leaves this inert rather than re-creating it.
#
# Exits 0 on every path and prints nothing: a SessionStart hook's stdout is
# injected into the agent's context, and its exit status is surfaced to the
# user as a hook error.

PATH=/usr/bin:/bin
export PATH
umask 077

payload=$(head -c 65536)
# Whatever is past the cap still has to be consumed, or a caller writing
# a larger payload blocks on a full pipe until its own hook timeout.
cat >/dev/null 2>&1 || :
exec >/dev/null 2>&1

script_dir=$(dirname "$0")
inbox="$script_dir/../checkout-inbox"
[ -d "$inbox" ] || exit 0

# A value carrying a backslash is a JSON escape this cannot decode, so it is
# left unmatched and the process's own directory answers instead.
dir=$(printf '%s' "$payload" \
	| grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"\]*"' \
	| head -1 \
	| sed 's/^.*"\([^"]*\)"$/\1/')
[ -n "$dir" ] || dir=$PWD
case $dir in
/*) ;;
*) exit 0 ;;
esac
[ -d "$dir" ] || exit 0

# git answers with the physical path, so the comparison below has to be made in
# the same terms: on macOS /tmp and /var are symlinks, and a session that names
# its directory through one would otherwise fail the ancestor test and record
# nothing at all.
dir=$(cd "$dir" 2>/dev/null && pwd -P) || exit 0
[ -n "$dir" ] || exit 0

# `env -i` is what drops an inherited GIT_DIR or GIT_WORK_TREE, which otherwise
# beat `-C` and answer for a repository the session was never in. HOME stays so
# the user's own git config — `safe.directory` above all — still applies.
git_() {
	env -i PATH=/usr/bin:/bin HOME="$HOME" GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 \
		/usr/bin/git -C "$dir" "$@"
}

top=$(git_ rev-parse --show-toplevel) || exit 0
[ -n "$top" ] || exit 0

# The walk Sissy does itself can only ever land on an ancestor of where it
# started. `core.worktree` lets a repository claim any path at all, so without
# this a downloaded tree chooses what Sissy writes down.
case $dir in
"$top" | "$top"/*) ;;
*) exit 0 ;;
esac

common=$(git_ rev-parse --path-format=absolute --git-common-dir) || exit 0
case $common in
/*) ;;
*) common="$top/$common" ;;
esac
# A common directory that is not `<repo>/.git` belongs to a submodule, which is
# its own repository — the answer `ProjectResolver` reaches by another road.
case $common in
*/.git) project=${common%/.git} ;;
*) project=$top ;;
esac

# Not `$(printf '\n')`: command substitution strips trailing newlines, so that
# spelling is the empty string and the guard matches everything.
nl='
'
case "$top$project" in
*"$nl"*) exit 0 ;;
esac

key=$(printf '%s' "$top" | shasum -a 256 | cut -c1-32)
[ -n "$key" ] || exit 0
staged="$inbox/.$key.$$"
printf '%s\n%s\n' "$top" "$project" >"$staged" || exit 0
mv -f "$staged" "$inbox/$key.txt" || rm -f "$staged"
exit 0
