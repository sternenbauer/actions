#!/usr/bin/env bash

# Publishes a release of an app on Hemisphere, see action.yml. Expects KEY,
# EDITION, IMAGES, VERSION and API_URL in the environment and writes its
# outputs to GITHUB_OUTPUT.

set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

# request performs an API request, stores the response body in RESPONSE and
# fails with the reason the API gives, it must not run in a subshell as the
# failure would not reach the log
request() {
  local method="$1" target="$2" data="${3:-}"

  # accept paths and the absolute links of paginated responses
  local url="$target"
  if [[ "$target" != http* ]]; then
    url="$API_URL$target"
  fi

  # prepare arguments, the JSON:API endpoints refuse a JSON content type
  local args=(-sS -X "$method" -H "Authorization: Bearer $KEY" -w $'\n%{http_code}')
  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi

  # perform request
  local response status body
  response=$(curl "${args[@]}" "$url")
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  # check status
  if [[ "$status" -ge 400 ]]; then
    local reason
    reason=$(jq -r '.errors[0].detail // .errors[0].title // empty' <<<"$body" 2>/dev/null || true)
    if [[ -n "$reason" ]]; then
      fail "$method $target failed with $status: $reason"
    elif [[ "$status" == "401" ]]; then
      fail "$method $target failed with 401: the key is unknown or has been revoked"
    fi
    fail "$method $target failed with $status"
  fi

  RESPONSE="$body"
}

# parse images, one container=image per line
images=$(jq -Rn '
  [inputs | gsub("^\\s+|\\s+$"; "") | select(length > 0) |
    if test("^[^=]+=.+$") then capture("^(?<key>[^=]+)=(?<value>.+)$") | map_values(gsub("^\\s+|\\s+$"; ""))
    else error("invalid image line: \(.)") end] | from_entries
' <<<"$IMAGES" 2>&1) || fail "${images#jq: error (at <stdin>:*): }"
if [[ "$images" == "{}" ]]; then
  fail "missing images"
fi

# accept a tag carrying the version, like v1.2.3, server/v1.2.3 or
# refs/tags/server/v1.2.3
if [[ -n "$VERSION" ]]; then
  tag="$VERSION"
  VERSION="${VERSION##*/}"
  VERSION="${VERSION#v}"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "invalid version $tag, expected x.y.z or a tag like server/v1.2.3"
  fi
fi

# determine the version, unless provided
if [[ -z "$VERSION" ]]; then
  # find edition
  request GET "/data/editions?filter%5Bslug%5D=$EDITION"
  edition=$(jq -r '.data[0].id // empty' <<<"$RESPONSE")
  if [[ -z "$edition" ]]; then
    fail "unknown edition $EDITION"
  fi

  # collect the releases of the edition
  releases="[]"
  target="/data/editions/$edition/releases"
  while [[ -n "$target" ]]; do
    request GET "$target"
    releases=$(jq -c --argjson releases "$releases" '$releases + .data' <<<"$RESPONSE")
    target=$(jq -r '.links.next // empty' <<<"$RESPONSE")
  done

  # return the latest release if it already runs the images, so a rerun
  # does not publish the same images again
  latest=$(jq -c '[.[] | select(.attributes.withdrawn == null)] | max_by(.attributes["version-number"]) // empty' <<<"$releases")
  if [[ -n "$latest" ]] && jq -e --argjson images "$images" '
    [(.attributes["init-containers"] // []) + (.attributes["run-containers"] // []) | .[] | {key: .name, value: .image}] | from_entries as $current |
    $images | to_entries | all(.value == $current[.key])
  ' <<<"$latest" >/dev/null; then
    id=$(jq -r '.id' <<<"$latest")
    version=$(jq -r '.attributes.version' <<<"$latest")
    echo "Release $version already runs the images."
    {
      echo "id=$id"
      echo "version=$version"
      echo "created=false"
    } >>"$GITHUB_OUTPUT"
    exit 0
  fi

  # bump the patch of the highest version, withdrawn ones included, as each
  # segment is limited to 999
  highest=$(jq -r 'max_by(.attributes["version-number"]) | .attributes.version // empty' <<<"$releases")
  if [[ -z "$highest" ]]; then
    fail "edition $EDITION has no release to derive from"
  fi
  IFS=. read -r major minor patch <<<"$highest"
  patch=$((patch + 1))
  if [[ "$patch" -gt 999 ]]; then
    patch=0
    minor=$((minor + 1))
  fi
  if [[ "$minor" -gt 999 ]]; then
    minor=0
    major=$((major + 1))
  fi
  VERSION="$major.$minor.$patch"
fi

# publish release
payload=$(jq -n --arg edition "$EDITION" --arg version "$VERSION" --argjson images "$images" \
  '{edition: $edition, version: $version, images: $images}')
request POST "/data/releases/publish" "$payload"

# write outputs
id=$(jq -r '.id' <<<"$RESPONSE")
version=$(jq -r '.version' <<<"$RESPONSE")
created=$(jq -r '.created' <<<"$RESPONSE")
if [[ "$created" == "true" ]]; then
  echo "Published release $version."
else
  echo "Release $version had already been published."
fi
{
  echo "id=$id"
  echo "version=$version"
  echo "created=$created"
} >>"$GITHUB_OUTPUT"
