#!/usr/bin/env bash
# Build the LibreOmi release artifacts and, unless --dry-run is given, attach them to a
# draft GitHub Release. This script is the single definition of what a release contains:
# .github/workflows/release.yml runs the very same steps so a tag push and a laptop
# produce the same files. See docs/08-dev-workflow.md §7.
#
# Usage:
#   scripts/release.sh --dry-run     # build + checksums only, touches nothing on GitHub
#   scripts/release.sh               # the above, then `gh release create vX.Y.Z --draft`
#   scripts/release.sh --version 0.2.0 --dry-run
#
# Signing: the Gradle build picks the release key up from the LIBREOMI_KEYSTORE_* environment
# variables or android/key.properties, and falls back to the debug key with a warning when
# neither is present (android/app/build.gradle.kts). This script does not handle key material
# itself, and deliberately never echoes any of it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dry_run=false
version=""

usage() {
    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --version)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "error: --version needs a value, e.g. --version 0.1.0" >&2
                exit 2
            fi
            version="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# `flutter` is pinned by mise.toml; going through `mise exec` means this script uses the same
# SDK as CI and as the checklist in docs/08, whatever is first on the caller's PATH.
flutter() {
    if command -v mise >/dev/null 2>&1; then
        mise exec -- flutter "$@"
    else
        command flutter "$@"
    fi
}

pubspec_version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' pubspec.yaml | head -n1)"
if [ -z "$pubspec_version" ]; then
    echo "error: could not read 'version:' out of pubspec.yaml" >&2
    exit 1
fi
build_name="${pubspec_version%%+*}"
build_number="${pubspec_version##*+}"

if [ -n "$version" ] && [ "$version" != "$build_name" ]; then
    echo "error: --version $version does not match pubspec.yaml ($build_name). Bump pubspec.yaml first." >&2
    exit 1
fi
tag="v$build_name"

echo "==> LibreOmi $build_name (versionCode $build_number) -> $tag"
if [ "$dry_run" = true ]; then
    echo "    dry run: artifacts are built and hashed, no GitHub Release is created"
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "    warning: the working tree has uncommitted changes; the build will include them"
fi

echo "==> flutter pub get"
flutter pub get

# Two ABIs on purpose. x86_64 exists only for emulators, and shipping it in a Release would
# add ~70 MiB of sherpa-onnx native code that no Omi user can run.
echo "==> flutter build apk --release --split-per-abi"
flutter build apk --release --split-per-abi \
    --target-platform android-arm64,android-arm

echo "==> flutter build appbundle --release"
flutter build appbundle --release

apk_dir="build/app/outputs/flutter-apk"
aab="build/app/outputs/bundle/release/app-release.aab"
artifacts=(
    "$apk_dir/app-arm64-v8a-release.apk"
    "$apk_dir/app-armeabi-v7a-release.apk"
    "$aab"
)

missing=false
for artifact in "${artifacts[@]}"; do
    if [ ! -f "$artifact" ]; then
        echo "error: expected artifact not produced: $artifact" >&2
        missing=true
    fi
done
[ "$missing" = false ] || exit 1

# sha256 so the Release body can state exactly what was uploaded; `shasum` is what macOS has
# and `sha256sum` is what the Linux runner has.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

echo
echo "==> Artifacts"
printf '| %-34s | %9s | %s |\n' "file" "size" "sha256"
printf '| %-34s | %9s | %s |\n' "----" "----" "------"
for artifact in "${artifacts[@]}"; do
    printf '| %-34s | %9s | %s |\n' \
        "$(basename "$artifact")" \
        "$(du -h "$artifact" | cut -f1 | tr -d ' ')" \
        "$(sha256 "$artifact")"
done
echo

# Which key actually signed the APK. Without this a debug-key build is indistinguishable from
# a properly signed one until somebody tries to install the update over a Play build.
apksigner_bin="$(command -v apksigner || true)"
if [ -z "$apksigner_bin" ]; then
    android_home="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    apksigner_bin="$(ls -1 "$android_home"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n1 || true)"
fi

debug_signed=unknown
if [ -n "$apksigner_bin" ]; then
    echo "==> Signing certificate ($(basename "$(dirname "$apksigner_bin")")/apksigner)"
    certs="$("$apksigner_bin" verify --print-certs "$apk_dir/app-arm64-v8a-release.apk")"
    echo "$certs" | grep -E 'Signer #1 certificate (DN|SHA-256 digest)' || true
    if echo "$certs" | grep -q 'CN=Android Debug'; then
        debug_signed=yes
    else
        debug_signed=no
    fi
else
    echo "==> apksigner not found; the signing certificate could NOT be checked"
fi
echo

# A debug-signed build is useless as a release: it cannot update a properly signed install and
# its key is on every machine that ever built this app. The warning alone is not enough - a
# missing or misspelled signing secret would otherwise sail straight into a published Release
# (docs/08 §7.2), so refuse to go any further than a dry run.
if [ "$dry_run" = false ]; then
    if [ "$debug_signed" = yes ]; then
        echo "error: these artifacts are signed with the DEBUG key. Configure the release key" >&2
        echo "       (docs/08-dev-workflow.md §7.2) and rebuild; refusing to create a release." >&2
        exit 1
    fi
    if [ "$debug_signed" = unknown ]; then
        echo "error: apksigner was not found, so the signing key could not be verified." >&2
        echo "       Install the Android build-tools or set ANDROID_HOME; refusing to create" >&2
        echo "       a release that might be debug-signed." >&2
        exit 1
    fi
elif [ "$debug_signed" = yes ]; then
    echo "    WARNING: signed with the DEBUG key. Do not publish this build."
    echo
fi

if [ "$dry_run" = true ]; then
    echo "==> Dry run finished. Nothing was uploaded."
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh is required to create the release (or pass --dry-run)" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "==> Tag $tag already exists locally"
else
    echo "error: tag $tag does not exist. Create and push it first: git tag $tag && git push origin $tag" >&2
    exit 1
fi

if gh release view "$tag" >/dev/null 2>&1; then
    echo "error: a GitHub Release for $tag already exists. Delete it or bump the version" >&2
    echo "       (gh release delete $tag)." >&2
    exit 1
fi

echo "==> gh release create $tag --draft"
gh release create "$tag" "${artifacts[@]}" \
    --draft \
    --title "LibreOmi $build_name" \
    --notes "See CHANGELOG.md. Draft created by scripts/release.sh; edit the notes before publishing."
echo "==> Draft release created. Review it on GitHub, then publish manually."
