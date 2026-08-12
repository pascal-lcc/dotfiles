#!/bin/bash
TARGET="en_US.UTF-8"

if ! dpkg -s locales >/dev/null 2>&1; then
    apt-get update && apt-get install -y locales
fi

if ! locale -a | grep -qi "${TARGET//-}"; then
    sed -i "s/^# \(${TARGET} UTF-8\)/\1/" /etc/locale.gen
    locale-gen "$TARGET"
fi

if [[ "$LANG" != "$TARGET" ]]; then
    update-locale LANG="$TARGET" LC_ALL="$TARGET"
    export LANG="$TARGET" LC_ALL="$TARGET"
fi


