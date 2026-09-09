#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
configuration="${1:-Release}"
configuration="${configuration:l}"
products_dir="${repo_dir}/.build/arm64-apple-macosx/${configuration}"

cd "${repo_dir}"
swift build \
    --configuration "${configuration}" \
    --disable-sandbox \
    -j 2

[[ -x "${products_dir}/ListenUpApp" ]] || { echo "Missing ListenUpApp build product" >&2; exit 1; }

app_dir="${repo_dir}/dist/ListenUp.app"
contents_dir="${app_dir}/Contents"

if [[ -d "${app_dir}" ]]; then
    backup="${repo_dir}/dist/ListenUp.previous.$(date +%Y%m%d-%H%M%S).app"
    mv "${app_dir}" "${backup}"
fi

mkdir -p "${contents_dir}/MacOS" "${contents_dir}/Resources"
cp "${products_dir}/ListenUpApp" "${contents_dir}/MacOS/ListenUpApp"
cp "${repo_dir}/AppResources/Info.plist" "${contents_dir}/Info.plist"

codesign --force --deep --sign - "${app_dir}"
echo "Built ${app_dir}"
