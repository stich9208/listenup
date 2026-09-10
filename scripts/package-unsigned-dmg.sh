#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
info_plist="${repo_dir}/AppResources/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}")"

if (( $# > 0 )); then
    echo "This script reads the version from AppResources/Info.plist; arguments are not supported." >&2
    exit 1
fi

if [[ ! "${version}" =~ '^[0-9A-Za-z][0-9A-Za-z._-]*$' ]]; then
    echo "Invalid release version: ${version}" >&2
    exit 1
fi

release_dir="${repo_dir}/release"
app_dir="${repo_dir}/dist/ListenUp.app"
dmg_name="ListenUp-${version}-arm64-unsigned.dmg"
dmg_path="${release_dir}/${dmg_name}"
checksum_path="${dmg_path}.sha256"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/listenup-dmg.XXXXXX")"

cleanup() {
    rm -rf "${stage_dir}"
}
trap cleanup EXIT

"${repo_dir}/scripts/build-app.sh" Release
codesign --verify --deep --strict "${app_dir}"

mkdir -p "${release_dir}"
cp -R "${app_dir}" "${stage_dir}/ListenUp.app"
ln -s /Applications "${stage_dir}/Applications"
cp "${repo_dir}/docs/UNSIGNED_INSTALL.md" "${stage_dir}/처음 실행 안내.txt"

rm -f "${dmg_path}" "${checksum_path}"
hdiutil create \
    -volname "ListenUp" \
    -srcfolder "${stage_dir}" \
    -format UDZO \
    -ov \
    "${dmg_path}"

hdiutil verify "${dmg_path}"
(
    cd "${release_dir}"
    shasum -a 256 "${dmg_name}" > "${dmg_name}.sha256"
)

echo "Created ${dmg_path}"
echo "Created ${checksum_path}"
