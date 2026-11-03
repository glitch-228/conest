#!/usr/bin/env bash
# The one place that maps a release tag to its channel, and checks the tag.
#
#   tool/release_channel.sh [--classify-only] [--tags-file FILE] [--today YYYYMMDD] <tag>
#
# Prints key=value lines:
#   channel=stable|nightly|canary
#   prerelease=true|false
#   version_code=<Android versionCode derived from the tag>
#
# Exits non-zero, with a message on stderr, for a tag that must not be
# released. The guards (a real date, not in the future, not before the
# previous canary, no stable of the same core, a canary core not below the
# newest nightly) read the existing tags from --tags-file (one per line;
# default: `git tag -l`). --classify-only skips them: the manifest tools use
# it to check that the channel they sign is the tag's own.
#
# --today is the date in UTC+1 (default: now); a tag may be up to that date.
#
# Tag shapes:
#   vX.Y.Z-canary.YYYYMMDD.N   canary (pre-release), N at most 99
#   anything containing nightly|beta|rc|alpha|dev|pre   nightly (pre-release)
#   otherwise                  stable
#
# Android versionCode: days since 2026-01-01 * 1000, plus 999 for stable and
# rank*100+N for the others (nightly rank 1, canary rank 2). The date is the
# tag's date, or today for a stable or an undated tag. Newer releases never
# have a lower code, which Android requires to install over an older build.
set -euo pipefail

die() {
  echo "release_channel: $*" >&2
  exit 1
}

classify_only=0
tags_file=""
today=""
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --classify-only) classify_only=1 ;;
    --tags-file)
      shift
      tags_file="${1:-}"
      ;;
    --today)
      shift
      today="${1:-}"
      ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$tag" ] || die "only one tag"
      tag="$1"
      ;;
  esac
  shift
done
[ -n "$tag" ] || die "missing tag"

lowered="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')"
canary_re='^v([0-9]+\.[0-9]+\.[0-9]+)-canary\.([0-9]{8})\.([0-9]+)$'
nightly_re='^v([0-9]+\.[0-9]+\.[0-9]+)-nightly\.([0-9]{8})\.([0-9]+)$'

channel="stable"
prerelease="false"
core=""
date=""
n="0"
if [[ "$lowered" == *canary* ]]; then
  [[ "$tag" =~ $canary_re ]] ||
    die "canary tags look like vX.Y.Z-canary.YYYYMMDD.N, not $tag"
  channel="canary"
  prerelease="true"
  core="${BASH_REMATCH[1]}"
  date="${BASH_REMATCH[2]}"
  n="${BASH_REMATCH[3]}"
else
  case "$lowered" in
    *nightly*|*beta*|*rc*|*alpha*|*dev*|*pre*)
      channel="nightly"
      prerelease="true"
      if [[ "$tag" =~ $nightly_re ]]; then
        core="${BASH_REMATCH[1]}"
        date="${BASH_REMATCH[2]}"
        n="${BASH_REMATCH[3]}"
      fi
      ;;
  esac
fi

[ -n "$today" ] || today="$(TZ=Etc/GMT-1 date +%Y%m%d)"
[[ "$today" =~ ^[0-9]{8}$ ]] || die "--today must be YYYYMMDD"

epoch_of() { date -u -d "${1:0:4}-${1:4:2}-${1:6:2}" +%s 2>/dev/null; }

if [ -n "$date" ]; then
  [ "$((10#$n))" -le 99 ] || die "the counter of $tag is above 99"
  real="$(date -u -d "${date:0:4}-${date:4:2}-${date:6:2}" +%Y%m%d 2>/dev/null || true)"
  [ "$real" = "$date" ] || die "$date in $tag is not a real date"
  [ "$date" -ge 20260101 ] || die "$date in $tag is before 2026-01-01"
fi

if [ "$classify_only" -eq 0 ] && [ -n "$date" ]; then
  [ "$date" -le "$today" ] || die "$date in $tag is later than today ($today)"
fi

if [ "$classify_only" -eq 0 ] && [ -n "$core" ]; then
  if [ -n "$tags_file" ]; then
    [ -r "$tags_file" ] || die "cannot read $tags_file"
    tags="$(cat "$tags_file")"
  else
    tags="$(git tag -l)"
  fi
  others="$(printf '%s\n' "$tags" | grep -vxF "$tag" || true)"
  if printf '%s\n' "$others" | grep -qxF "v$core"; then
    die "v$core is already released as stable; $tag would be older than it"
  fi
  if [ "$channel" = "canary" ]; then
    previous="$(printf '%s\n' "$others" |
      sed -nE 's/^v[0-9]+\.[0-9]+\.[0-9]+-canary\.([0-9]{8})\.[0-9]+$/\1/p' |
      sort -n | tail -n 1)"
    if [ -n "$previous" ] && [ "$date" -lt "$previous" ]; then
      die "$date in $tag is earlier than the previous canary ($previous)"
    fi
    newest_nightly="$(printf '%s\n' "$others" |
      sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)-nightly\..*$/\1/p' |
      sort -V | tail -n 1)"
    if [ -n "$newest_nightly" ]; then
      lowest="$(printf '%s\n%s\n' "$core" "$newest_nightly" | sort -V | head -n 1)"
      if [ "$lowest" = "$core" ] && [ "$core" != "$newest_nightly" ]; then
        die "canary core $core is lower than the newest nightly core $newest_nightly"
      fi
    fi
  fi
fi

code_date="$date"
[ -n "$code_date" ] || code_date="$today"
days=$(((($(epoch_of "$code_date")) - $(epoch_of 20260101)) / 86400))
case "$channel" in
  stable) tail_code=999 ;;
  nightly) tail_code=$((100 + 10#$n)) ;;
  canary) tail_code=$((200 + 10#$n)) ;;
esac
version_code=$((days * 1000 + tail_code))

echo "channel=$channel"
echo "prerelease=$prerelease"
echo "version_code=$version_code"
