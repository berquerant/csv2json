#!/bin/bash

THISD=$(cd $(dirname $0);pwd)
libsd=libs
package_file=requirements.txt
PACKAGE_FILE="${THISD}/${package_file}"
LIBSD="${THISD}/{libsd}"

usage() {
    cat - <<EOF
Usage: ./package.sh [command]

Commands:

  clean     Clean ${libsd}
  update    Install packages in ${package_file} into ${libsd}
EOF
}

clean() {
    rm -rf "$LIBSD"
    mkdir -p "$LIBSD"
}

update() {
    mkdir -p "$LIBSD"
    cd "$LIBSD"

    cat "$PACKAGE_FILE" | while read line ; do
        colnum=$(echo $line|awk '{print NF}')
        if [[ $colnum -lt 2 ]] ; then
            echo "Broken line found: $line" >&2
            exit 1
        fi
        repository=$(echo $line|cut -d" " -f1)
        version=$(echo $line|cut -d" " -f2)
        git clone "https://${repository}" >/dev/null 2>&1
        dest=$(echo $repository|grep -oE '/[^/]+$'|tr -d "/")
        cd "$dest"
        git checkout "$version" >/dev/null 2>&1
    done
}


case "$1" in
    "clean") clean ;;
    "update") update ;;
    *) usage ;;
esac
