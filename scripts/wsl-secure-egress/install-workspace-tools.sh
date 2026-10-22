#!/bin/sh
# Compatibility entry point. The reviewed installer is the single authority.
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
AUTHORITATIVE_INSTALLER="${SCRIPT_DIR}/tools/install-wsl-tools.sh"

if [ ! -f "${AUTHORITATIVE_INSTALLER}" ]; then
    echo "authoritative tool installer is missing: ${AUTHORITATIVE_INSTALLER}" >&2
    exit 2
fi

exec /bin/sh "${AUTHORITATIVE_INSTALLER}" "$@"
