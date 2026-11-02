#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

set -eu

CORE_DIR="${SRCROOT}/../linkcursor-core"
OUTPUT_DIR="${BUILT_PRODUCTS_DIR}"

# Xcode launched from Finder does not inherit the shell startup PATH. Add the
# standard rustup and Homebrew locations so the build behaves the same in the
# Xcode GUI and in a terminal.
RUST_TOOL_PATH=""
if [ -n "${CARGO_HOME:-}" ]; then
    RUST_TOOL_PATH="${CARGO_HOME}/bin"
fi
if [ -n "${HOME:-}" ]; then
    RUST_TOOL_PATH="${RUST_TOOL_PATH:+${RUST_TOOL_PATH}:}${HOME}/.cargo/bin"
fi
RUST_TOOL_PATH="${RUST_TOOL_PATH:+${RUST_TOOL_PATH}:}/opt/homebrew/bin:/usr/local/bin"
PATH="${RUST_TOOL_PATH}:${PATH}"
export PATH

if ! command -v rustup >/dev/null 2>&1; then
    echo "error: rustup was not found. Install Rust with rustup or set CARGO_HOME in the Xcode scheme."
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo was not found. Install Rust with rustup or set CARGO_HOME in the Xcode scheme."
    exit 1
fi

if [ ! -f "${CORE_DIR}/Cargo.toml" ]; then
    echo "error: LinkCursor Core was not found at ${CORE_DIR}. Keep linkcursor-core next to linkcursor-macos."
    exit 1
fi

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    CARGO_MODE="--release"
    PROFILE="release"
else
    CARGO_MODE=""
    PROFILE="debug"
fi

mkdir -p "${OUTPUT_DIR}"
TEMP_DIR="${DERIVED_FILE_DIR}/linkcursor-rust"
mkdir -p "${TEMP_DIR}"

set --
for ARCH in ${ARCHS:-$(uname -m)}; do
    case "${ARCH}" in
        arm64) RUST_TARGET="aarch64-apple-darwin" ;;
        x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
        *)
            echo "error: unsupported macOS architecture: ${ARCH}"
            exit 1
            ;;
    esac

    if ! rustup target list --installed | grep -qx "${RUST_TARGET}"; then
        echo "error: Rust target ${RUST_TARGET} is not installed. Run: rustup target add ${RUST_TARGET}"
        exit 1
    fi

    cargo build \
        --locked \
        --manifest-path "${CORE_DIR}/Cargo.toml" \
        --target-dir "${CORE_DIR}/target" \
        --target "${RUST_TARGET}" \
        ${CARGO_MODE}

    SOURCE_LIBRARY="${CORE_DIR}/target/${RUST_TARGET}/${PROFILE}/liblinkcursor_core.a"
    ARCH_LIBRARY="${TEMP_DIR}/liblinkcursor_core-${ARCH}.a"
    cp "${SOURCE_LIBRARY}" "${ARCH_LIBRARY}"
    set -- "$@" "${ARCH_LIBRARY}"
done

if [ "$#" -eq 1 ]; then
    cp "$1" "${OUTPUT_DIR}/liblinkcursor_core.a"
else
    xcrun lipo -create "$@" -output "${OUTPUT_DIR}/liblinkcursor_core.a"
fi
