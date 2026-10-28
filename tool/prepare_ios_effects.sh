#!/bin/sh
# Keep the fixed-version source in Flutter's ignored, durable dependency cache.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dependency_dir="$project_dir/.dart_tool/guitarbook-native"
juce_dir="$dependency_dir/JUCE-8.0.12"
if [ ! -f "$juce_dir/modules/juce_core/juce_core.h" ]; then
    mkdir -p "$dependency_dir"
    # Publish only after a complete, checksum-verified extraction.
    staging_dir=$(mktemp -d "$dependency_dir/juce-download.XXXXXX")
    trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
    curl --fail --location --retry 3 --connect-timeout 30 --max-time 300 \
        https://codeload.github.com/juce-framework/JUCE/tar.gz/refs/tags/8.0.12 \
        -o "$staging_dir/juce.tar.gz"
    echo "dec1a8baee5aaec4502b717a421b850e257ab7e9c2efd03766185ec1957cf102  $staging_dir/juce.tar.gz" | shasum -a 256 -c -
    tar -xzf "$staging_dir/juce.tar.gz" -C "$staging_dir"
    mv "$staging_dir/JUCE-8.0.12" "$juce_dir"
fi
