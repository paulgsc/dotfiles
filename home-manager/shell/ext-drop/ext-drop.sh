# ext-drop: build a some-ui extension and drop the zip where the Windows
# browser can download it (https://builds.<baseDomain>/, nixos/configuration.nix).
# docs/ext-drop.md has the whole loop, Windows side included.
#
#   ext-drop <extension> [chromium|firefox]      build, keep, point beta at it
#   ext-drop promote <extension> <target> [zip]  point stable at beta (or at zip)
#
# Every build is kept under its own name (time, commit, -dirty), so a
# working build is never overwritten. Two pointers name the ones that
# matter: beta.zip (the newest) and stable.zip (the one you trust). Only
# the newest EXT_DROP_KEEP builds survive, plus whatever a pointer names, so
# the folder cannot pile up and the stable build cannot be pruned away.
#
# Environment:
#   EXT_DROP_DIR   where builds go (default /srv/builds)
#   EXT_DROP_KEEP  builds kept per extension and target (default 5)
#   SOME_UI        the checkout to build (default: the repo you are in, else ~/dev/some-ui)

drop_root=${EXT_DROP_DIR:-/srv/builds}
keep=${EXT_DROP_KEEP:-5}
# Global, not local to cmd_build: the EXIT trap that removes it runs after
# cmd_build has returned.
stage=""

usage() {
  cat >&2 <<'EOF'
usage: ext-drop <extension> [chromium|firefox]
       ext-drop promote <extension> <target> [<build>.zip]
EOF
  exit 64
}

die() {
  echo "ext-drop: $*" >&2
  exit 1
}

check_name() {
  # Names become path segments under drop_root; refuse anything that could
  # climb out of it.
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "not an extension or target name: $1"
}

resolve_repo() {
  local top
  if [ -n "${SOME_UI:-}" ]; then
    echo "$SOME_UI"
  elif top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -d "$top/extensions" ]; then
    echo "$top"
  else
    echo "$HOME/dev/some-ui"
  fi
}

# pointers.txt sits beside the zips, so the browser listing says which build
# each pointer names (a download of stable.zip is just called stable.zip).
write_pointers() {
  local dest=$1 p
  {
    for p in stable beta; do
      if [ -L "$dest/$p.zip" ]; then
        echo "$p.zip -> $(readlink "$dest/$p.zip")"
      else
        echo "$p.zip -> (none yet)"
      fi
    done
  } >"$dest/.pointers.txt"
  mv -f "$dest/.pointers.txt" "$dest/pointers.txt"
}

# One lock per extension and target, held by a build from publishing its zip
# until its pointers are written, and by promote from its checks until its
# pointer is written. So a prune never runs between a promote's check and its
# pointer (which could delete the build stable is about to name), and two
# builds never publish at once. It lives outside drop_root, so the listing
# never shows it; the lock goes when the process exits.
lock() {
  exec 9>"${XDG_RUNTIME_DIR:-/tmp}/ext-drop-$1-$2.lock"
  flock 9
}

# One lock per checkout and extension, held from the build until its dist/ is
# copied: the targets of one extension share dist/, so a chromium and a
# firefox build run at once would otherwise zip each other's output. Keyed by
# the resolved path (realpath, so ./, .. and symlinks to one checkout share
# a lock), so separate checkouts still build in parallel.
lock_dist() {
  exec 8>"${XDG_RUNTIME_DIR:-/tmp}/ext-drop-dist-$(realpath -- "$1" | md5sum | cut -c1-12).lock"
  flock 8
}

point() {
  local dest=$1 name=$2 target=$3
  ln -sfn "$target" "$dest/.$name.zip"
  mv -fT "$dest/.$name.zip" "$dest/$name.zip"
}

prune() {
  local dest=$1 prefix=$2 n=0 f protected
  protected=" $(readlink "$dest/stable.zip" 2>/dev/null || true) $(readlink "$dest/beta.zip" 2>/dev/null || true) "
  # Names start with a sortable timestamp, so reverse name order is newest first.
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -le "$keep" ] && continue
    [[ $protected == *" $f "* ]] && continue
    rm -f -- "${dest:?}/$f"
    echo "ext-drop: pruned $f"
  done < <(find "$dest" -maxdepth 1 -type f -name "$prefix-*.zip" -printf '%f\n' | sort -r)
}

cmd_build() {
  local ext=$1 target=${2:-} repo ext_dir pkg script sha dirty="" branch stamp name dest
  check_name "$ext"
  [ -z "$target" ] || check_name "$target"
  [[ $keep =~ ^[1-9][0-9]*$ ]] || die "EXT_DROP_KEEP must be a positive number, got: $keep"
  [ -d "$drop_root" ] || die "$drop_root does not exist (nixos/configuration.nix creates it; rebuild first)"

  repo=$(resolve_repo)
  ext_dir=$repo/extensions/$ext
  [ -f "$ext_dir/package.json" ] || die "no extension at $ext_dir"
  command -v pnpm >/dev/null || die "pnpm is not on PATH"

  pkg=$(jq -r .name "$ext_dir/package.json")
  script=build${target:+:$target}
  jq -e --arg s "$script" '.scripts[$s]' "$ext_dir/package.json" >/dev/null ||
    die "$pkg has no \"$script\" script (targets it has: $(jq -r '[.scripts | keys[] | select(startswith("build:")) | ltrimstr("build:")] | join(", ") | if . == "" then "none, run without one" else . end' "$ext_dir/package.json"))"

  # A fresh checkout has no workspace dist/, and the extension's build cannot
  # resolve @some-ui/* without it. turbo builds only what this one depends on.
  lock_dist "$ext_dir"
  echo "ext-drop: building $pkg's dependencies"
  pnpm -C "$repo" exec turbo run build --filter="$pkg^..." --output-logs=errors-only
  echo "ext-drop: pnpm run $script in $ext_dir"
  pnpm -C "$ext_dir" run "$script"
  [ -f "$ext_dir/dist/manifest.json" ] || die "the build left no dist/manifest.json"

  # With no target named, label the build by what it is: Chrome's MV3
  # background is a service worker, Firefox's is scripts.
  if [ -z "$target" ]; then
    if jq -e '.background.service_worker' "$ext_dir/dist/manifest.json" >/dev/null; then
      target=chromium
    else
      target=firefox
    fi
  fi

  sha=$(git -C "$repo" rev-parse --short=7 HEAD)
  [ -z "$(git -C "$repo" status --porcelain)" ] || dirty=-dirty
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  stamp=$(date +%Y%m%d-%H%M%S)
  name=$ext-$target-$stamp-$sha$dirty.zip
  dest=$drop_root/$ext/$target
  mkdir -p "$dest"

  # Zip a copy, so the build record goes into the download and not into the
  # checkout's dist/. The record is how a file saved as stable.zip still
  # says which commit it is.
  stage=$(mktemp -d)
  trap '[ -z "$stage" ] || rm -rf "$stage"' EXIT
  cp -r "$ext_dir/dist" "$stage/ext"
  exec 8>&-
  jq -n --arg ext "$ext" --arg target "$target" --arg commit "$(git -C "$repo" rev-parse HEAD)" \
    --arg branch "$branch" --arg built "$stamp" --argjson dirty "$([ -n "$dirty" ] && echo true || echo false)" \
    '{$ext, $target, $commit, $branch, $dirty, $built}' >"$stage/ext/ext-drop.json"
  (cd "$stage/ext" && zip -qrX "$stage/out.zip" .)
  # Into a dotfile of this run's own first, then linked into place: the listing
  # never offers a half-written zip, and ln (unlike mv) refuses a name that is
  # already taken, so two builds in the same second at the same commit cannot
  # replace one another, or the build a pointer names. The dotfile is unique
  # per run because the link shares its inode: a shared one would let a second
  # run's cp rewrite the zip the first had just published. mktemp makes it
  # 0600, and Caddy has to read it.
  lock "$ext" "$target"
  local part
  part=$(mktemp "$dest/.$name.XXXXXX")
  cp "$stage/out.zip" "$part"
  chmod 0644 "$part"
  if ! ln "$part" "$dest/$name" 2>/dev/null; then
    rm -f "$part"
    die "$name is already kept; build again in a second"
  fi
  rm -f "$part"

  point "$dest" beta "$name"
  prune "$dest" "$ext-$target"
  write_pointers "$dest"

  echo "ext-drop: $name ($branch)"
  echo "ext-drop: beta.zip -> $name"
  if [ -L "$dest/stable.zip" ]; then
    echo "ext-drop: stable.zip -> $(readlink "$dest/stable.zip")"
  else
    echo "ext-drop: no stable yet; once this one works: ext-drop promote $ext $target"
  fi
  [ -z "$dirty" ] || echo "ext-drop: built with uncommitted changes; the commit alone will not rebuild it"
}

cmd_promote() {
  local ext=${1:-} target=${2:-} build=${3:-} dest
  [ -n "$ext" ] && [ -n "$target" ] || usage
  check_name "$ext"
  check_name "$target"
  dest=$drop_root/$ext/$target
  [ -d "$dest" ] || die "nothing dropped for $ext/$target yet"
  lock "$ext" "$target"
  if [ -z "$build" ]; then
    build=$(readlink "$dest/beta.zip" 2>/dev/null) || die "$ext/$target has no beta to promote"
  fi
  build=${build##*/}
  [[ $build == "$ext-$target-"*.zip ]] && [ -f "$dest/$build" ] ||
    die "no build $build in $dest (kept: $(find "$dest" -maxdepth 1 -type f -name "$ext-$target-*.zip" -printf '%f\n' | sort | tr '\n' ' '))"

  point "$dest" stable "$build"
  write_pointers "$dest"
  echo "ext-drop: stable.zip -> $build"
}

case "${1:-}" in
  "" | -h | --help) usage ;;
  promote)
    shift
    cmd_promote "$@"
    ;;
  *)
    [ "$#" -le 2 ] || usage
    cmd_build "$@"
    ;;
esac
