#!/bin/sh
# shellcheck shell=dash
# shellcheck disable=SC2039  # local is non-POSIX
#
# Licensed under the MIT license
# <LICENSE-MIT or https://opensource.org/licenses/MIT>, at your
# option. This file may not be copied, modified, or distributed
# except according to those terms.

# This runs on Unix shells like bash/dash/ksh/zsh. It uses the common `local`
# extension. Note: Most shells limit `local` to 1 var per line, contra bash.

# Some versions of ksh have no `local` keyword. Alias it to `typeset`, but
# beware this makes variables global with f()-style function syntax in ksh93.
# mksh has this alias by default.
has_local() {
    # shellcheck disable=SC2034  # deliberately unused
    local _has_local
}

has_local 2>/dev/null || alias local=typeset

set -u

APP_NAME="uv"
APP_VERSION="0.10.4"
# Look for GitHub Enterprise-style base URL first
if [ -n "${UV_INSTALLER_GHE_BASE_URL:-}" ]; then
    INSTALLER_BASE_URL="$UV_INSTALLER_GHE_BASE_URL"
else
    INSTALLER_BASE_URL="${UV_INSTALLER_GITHUB_BASE_URL:-https://github.com}"
fi
if [ -n "${UV_DOWNLOAD_URL:-}" ]; then
    ARTIFACT_DOWNLOAD_URL="$UV_DOWNLOAD_URL"
elif [ -n "${INSTALLER_DOWNLOAD_URL:-}" ]; then
    ARTIFACT_DOWNLOAD_URL="$INSTALLER_DOWNLOAD_URL"
else
    ARTIFACT_DOWNLOAD_URL="${INSTALLER_BASE_URL}/astral-sh/uv/releases/download/0.10.4"
fi
if [ -n "${UV_PRINT_VERBOSE:-}" ]; then
    PRINT_VERBOSE="$UV_PRINT_VERBOSE"
else
    PRINT_VERBOSE=${INSTALLER_PRINT_VERBOSE:-0}
fi
if [ -n "${UV_PRINT_QUIET:-}" ]; then
    PRINT_QUIET="$UV_PRINT_QUIET"
else
    PRINT_QUIET=${INSTALLER_PRINT_QUIET:-0}
fi
if [ -n "${UV_NO_MODIFY_PATH:-}" ]; then
    NO_MODIFY_PATH="$UV_NO_MODIFY_PATH"
else
    NO_MODIFY_PATH=${INSTALLER_NO_MODIFY_PATH:-0}
fi
if [ "${UV_DISABLE_UPDATE:-0}" = "1" ]; then
    INSTALL_UPDATER=0
else
    INSTALL_UPDATER=1
fi
UNMANAGED_INSTALL="${UV_UNMANAGED_INSTALL:-}"
if [ -n "${UNMANAGED_INSTALL}" ]; then
    NO_MODIFY_PATH=1
    INSTALL_UPDATER=0
fi
AUTH_TOKEN="${UV_GITHUB_TOKEN:-}"

read -r RECEIPT <<EORECEIPT
{"binaries":["CARGO_DIST_BINS"],"binary_aliases":{},"cdylibs":["CARGO_DIST_DYLIBS"],"cstaticlibs":["CARGO_DIST_STATICLIBS"],"install_layout":"unspecified","install_prefix":"AXO_INSTALL_PREFIX","modify_path":true,"provider":{"source":"cargo-dist","version":"0.30.2"},"source":{"app_name":"uv","name":"uv","owner":"astral-sh","release_type":"github"},"version":"0.10.4"}
EORECEIPT

# Some Linux distributions don't set HOME
# https://github.com/astral-sh/uv/issues/6965#issuecomment-2915796022
get_home() {
    if [ -n "${HOME:-}" ]; then
        echo "$HOME"
    elif [ -n "${USER:-}" ]; then
        getent passwd "$USER" | cut -d: -f6
    else
        getent passwd "$(id -un)" | cut -d: -f6
    fi
}
# The HOME reference to show in user output. If `$HOME` isn't set, we show the absolute path instead.
get_home_expression() {
    if [ -n "${HOME:-}" ]; then
        # shellcheck disable=SC2016
        echo '$HOME'
    elif [ -n "${USER:-}" ]; then
        getent passwd "$USER" | cut -d: -f6
    else
        getent passwd "$(id -un)" | cut -d: -f6
    fi
}
INFERRED_HOME=$(get_home)
# shellcheck disable=SC2034
INFERRED_HOME_EXPRESSION=$(get_home_expression)
RECEIPT_HOME="${XDG_CONFIG_HOME:-$INFERRED_HOME/.config}/uv"

usage() {
    # print help (this cat/EOF stuff is a "heredoc" string)
    cat <<EOF
uv-installer.sh

The installer for uv 0.10.4

This script detects what platform you're on and fetches an appropriate archive from
https://github.com/astral-sh/uv/releases/download/0.10.4
then unpacks the binaries and installs them to the first of the following locations

    \$XDG_BIN_HOME
    \$XDG_DATA_HOME/../bin
    \$HOME/.local/bin

It will then add that dir to PATH by adding the appropriate line to your shell profiles.

USAGE:
    uv-installer.sh [OPTIONS]

OPTIONS:
    -v, --verbose
            Enable verbose output

    -q, --quiet
            Disable progress output

        --no-modify-path
            Don't configure the PATH environment variable

    -h, --help
            Print help information
EOF
}

download_binary_and_run_installer() {
    downloader --check
    need_cmd uname
    need_cmd mktemp
    need_cmd chmod
    need_cmd mkdir
    need_cmd rm
    need_cmd tar
    need_cmd grep
    need_cmd cat

    for arg in "$@"; do
        case "$arg" in
            --help)
                usage
                exit 0
                ;;
            --quiet)
                PRINT_QUIET=1
                ;;
            --verbose)
                PRINT_VERBOSE=1
                ;;
            --no-modify-path)
                say "--no-modify-path has been deprecated; please set UV_NO_MODIFY_PATH=1 in the environment"
                NO_MODIFY_PATH=1
                ;;
            *)
                OPTIND=1
                if [ "${arg%%--*}" = "" ]; then
                    err "unknown option $arg"
                fi
                while getopts :hvq sub_arg "$arg"; do
                    case "$sub_arg" in
                        h)
                            usage
                            exit 0
                            ;;
                        v)
                            # user wants to skip the prompt --
                            # we don't need /dev/tty
                            PRINT_VERBOSE=1
                            ;;
                        q)
                            # user wants to skip the prompt --
                            # we don't need /dev/tty
                            PRINT_QUIET=1
                            ;;
                        *)
                            err "unknown option -$OPTARG"
                            ;;
                        esac
                done
                ;;
        esac
    done

    get_architecture || return 1
    local _true_arch="$RETVAL"
    assert_nz "$_true_arch" "arch"
    local _cur_arch="$_true_arch"


    # look up what archives support this platform
    local _artifact_name
    _artifact_name="$(select_archive_for_arch "$_true_arch")" || return 1
    local _bins
    local _zip_ext
    local _arch
    local _checksum_style
    local _checksum_value

    # destructure selected archive info into locals
    case "$_artifact_name" in 
        "uv-aarch64-apple-darwin.tar.gz")
            _arch="aarch64-apple-darwin"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-aarch64-pc-windows-msvc.zip")
            _arch="aarch64-pc-windows-msvc"
            _zip_ext=".zip"
            _bins="uv.exe uvx.exe uvw.exe"
            _bins_js_array='"uv.exe","uvx.exe","uvw.exe"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-aarch64-unknown-linux-gnu.tar.gz")
            _arch="aarch64-unknown-linux-gnu"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-aarch64-unknown-linux-musl.tar.gz")
            _arch="aarch64-unknown-linux-musl-static"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-arm-unknown-linux-musleabihf.tar.gz")
            _arch="arm-unknown-linux-musl-staticeabihf"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-armv7-unknown-linux-gnueabihf.tar.gz")
            _arch="armv7-unknown-linux-gnueabihf"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-armv7-unknown-linux-musleabihf.tar.gz")
            _arch="armv7-unknown-linux-musl-staticeabihf"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-i686-pc-windows-msvc.zip")
            _arch="i686-pc-windows-msvc"
            _zip_ext=".zip"
            _bins="uv.exe uvx.exe uvw.exe"
            _bins_js_array='"uv.exe","uvx.exe","uvw.exe"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-i686-unknown-linux-gnu.tar.gz")
            _arch="i686-unknown-linux-gnu"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-i686-unknown-linux-musl.tar.gz")
            _arch="i686-unknown-linux-musl-static"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-powerpc64-unknown-linux-gnu.tar.gz")
            _arch="powerpc64-unknown-linux-gnu"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-powerpc64le-unknown-linux-gnu.tar.gz")
            _arch="powerpc64le-unknown-linux-gnu"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-riscv64gc-unknown-linux-gnu.tar.gz")
            _arch="riscv64gc-unknown-linux-gnu"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-s390x-unknown-linux-gnu.tar.gz")
            _arch="s390x-unknown-linux-gnu"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-x86_64-apple-darwin.tar.gz")
            _arch="x86_64-apple-darwin"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-x86_64-pc-windows-msvc.zip")
            _arch="x86_64-pc-windows-msvc"
            _zip_ext=".zip"
            _bins="uv.exe uvx.exe uvw.exe"
            _bins_js_array='"uv.exe","uvx.exe","uvw.exe"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-x86_64-unknown-linux-gnu.tar.gz")
            _arch="x86_64-unknown-linux-gnu"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        "uv-x86_64-unknown-linux-musl.tar.gz")
            _arch="x86_64-unknown-linux-musl-static"
            _zip_ext=".tar.gz"
            _bins="uv uvx"
            _bins_js_array='"uv","uvx"'
            _libs=""
            _libs_js_array=""
            _staticlibs=""
            _staticlibs_js_array=""
            _updater_name=""
            _updater_bin=""
            ;;
        *)
            err "internal installer error: selected download $_artifact_name doesn't exist!?"
            ;;
    esac


    # Replace the placeholder binaries with the calculated array from above
    RECEIPT="$(echo "$RECEIPT" | sed s/'"CARGO_DIST_BINS"'/"$_bins_js_array"/)"
    RECEIPT="$(echo "$RECEIPT" | sed s/'"CARGO_DIST_DYLIBS"'/"$_libs_js_array"/)"
    RECEIPT="$(echo "$RECEIPT" | sed s/'"CARGO_DIST_STATICLIBS"'/"$_staticlibs_js_array"/)"

    # download the archive
    local _url="$ARTIFACT_DOWNLOAD_URL/$_artifact_name"
    local _dir
    _dir="$(ensure mktemp -d)" || return 1
    local _file="$_dir/input$_zip_ext"

    say "downloading $APP_NAME $APP_VERSION ${_arch}" 1>&2
    say_verbose "  from $_url" 1>&2
    say_verbose "  to $_file" 1>&2

    ensure mkdir -p "$_dir"

    if ! downloader "$_url" "$_file"; then
      say "failed to download $_url"
      say "this may be a standard network error, but it may also indicate"
      say "that $APP_NAME's release process is not working. When in doubt"
      say "please feel free to open an issue!"
      exit 1
    fi

    if [ -n "${_checksum_style:-}" ]; then
        verify_checksum "$_file" "$_checksum_style" "$_checksum_value"
    else
        say "no checksums to verify"
    fi

    # ...and then the updater, if it exists
    if [ -n "$_updater_name" ] && [ "$INSTALL_UPDATER" = "1" ]; then
        local _updater_url="$ARTIFACT_DOWNLOAD_URL/$_updater_name"
        # This renames the artifact while doing the download, removing the
        # target triple and leaving just the appname-update format
        local _updater_file="$_dir/$APP_NAME-update"

        if ! downloader "$_updater_url" "$_updater_file"; then
          say "failed to download $_updater_url"
          say "this may be a standard network error, but it may also indicate"
          say "that $APP_NAME's release process is not working. When in doubt"
          say "please feel free to open an issue!"
          exit 1
        fi

        # Add the updater to the list of binaries to install
        _bins="$_bins $APP_NAME-update"
    fi

    # unpack the archive
    case "$_zip_ext" in
        ".zip")
            ensure unzip -q "$_file" -d "$_dir"
            ;;

        ".tar."*)
            ensure tar xf "$_file" --strip-components 1 -C "$_dir"
            ;;
        *)
            err "unknown archive format: $_zip_ext"
            ;;
    esac

    install "$_dir" "$_bins" "$_libs" "$_staticlibs" "$_arch" "$@"
    local _retval=$?
    if [ "$_retval" != 0 ]; then
        return "$_retval"
    fi

    ignore rm -rf "$_dir"

    # Install the install receipt
    if [ "$INSTALL_UPDATER" = "1" ]; then
        if ! mkdir -p "$RECEIPT_HOME"; then
            err "unable to create receipt directory at $RECEIPT_HOME"
        else
            echo "$RECEIPT" > "$RECEIPT_HOME/$APP_NAME-receipt.json"
            # shellcheck disable=SC2320
            local _retval=$?
        fi
    else
        local _retval=0
    fi

    return "$_retval"
}

# Replaces $HOME with the variable name for display to the user,
# only if $HOME is defined.
replace_home() {
    local _str="$1"

    if [ -n "${HOME:-}" ]; then
        echo "$_str" | sed "s,$HOME,\$HOME,"
    else
        echo "$_str"
    fi
}

json_binary_aliases() {
    local _arch="$1"

    case "$_arch" in 
    "aarch64-apple-darwin")
        echo '{}'
        ;;
    "aarch64-pc-windows-gnu")
        echo '{}'
        ;;
    "aarch64-unknown-linux-gnu")
        echo '{}'
        ;;
    "aarch64-unknown-linux-musl-dynamic")
        echo '{}'
        ;;
    "aarch64-unknown-linux-musl-static")
        echo '{}'
        ;;
    "arm-unknown-linux-gnueabihf")
        echo '{}'
        ;;
    "arm-unknown-linux-musl-dynamiceabihf")
        echo '{}'
        ;;
    "arm-unknown-linux-musl-staticeabihf")
        echo '{}'
        ;;
    "armv7-unknown-linux-gnueabihf")
        echo '{}'
        ;;
    "armv7-unknown-linux-musl-dynamiceabihf")
        echo '{}'
        ;;
    "armv7-unknown-linux-musl-staticeabihf")
        echo '{}'
        ;;
    "i686-pc-windows-gnu")
        echo '{}'
        ;;
    "i686-unknown-linux-gnu")
        echo '{}'
        ;;
    "i686-unknown-linux-musl-dynamic")
        echo '{}'
        ;;
    "i686-unknown-linux-musl-static")
        echo '{}'
        ;;
    "powerpc64-unknown-linux-gnu")
        echo '{}'
        ;;
    "powerpc64le-unknown-linux-gnu")
        echo '{}'
        ;;
    "riscv64gc-unknown-linux-gnu")
        echo '{}'
        ;;
    "s390x-unknown-linux-gnu")
        echo '{}'
        ;;
    "x86_64-apple-darwin")
        echo '{}'
        ;;
    "x86_64-pc-windows-gnu")
        echo '{}'
        ;;
    "x86_64-unknown-linux-gnu")
        echo '{}'
        ;;
    "x86_64-unknown-linux-musl-dynamic")
        echo '{}'
        ;;
    "x86_64-unknown-linux-musl-static")
        echo '{}'
        ;;
    *)
        echo '{}'
        ;;
    esac
}

aliases_for_binary() {
    local _bin="$1"
    local _arch="$2"

    case "$_arch" in 
    "aarch64-apple-darwin")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "aarch64-pc-windows-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "aarch64-unknown-linux-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "aarch64-unknown-linux-musl-dynamic")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "aarch64-unknown-linux-musl-static")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "arm-unknown-linux-gnueabihf")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "arm-unknown-linux-musl-dynamiceabihf")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "arm-unknown-linux-musl-staticeabihf")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "armv7-unknown-linux-gnueabihf")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "armv7-unknown-linux-musl-dynamiceabihf")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "armv7-unknown-linux-musl-staticeabihf")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "i686-pc-windows-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "i686-unknown-linux-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "i686-unknown-linux-musl-dynamic")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "i686-unknown-linux-musl-static")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "powerpc64-unknown-linux-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "powerpc64le-unknown-linux-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "riscv64gc-unknown-linux-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "s390x-unknown-linux-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "x86_64-apple-darwin")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "x86_64-pc-windows-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "x86_64-unknown-linux-gnu")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "x86_64-unknown-linux-musl-dynamic")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    "x86_64-unknown-linux-musl-static")
        case "$_bin" in
        *)
            echo ""
            ;;
        esac
        ;;
    *)
        echo ""
        ;;
    esac
}

select_archive_for_arch() {
    local _true_arch="$1"
    local _archive

    # try each archive, checking runtime conditions like libc versions
    # accepting the first one that matches, as it's the best match
    case "$_true_arch" in 
        "aarch64-apple-darwin")
            _archive="uv-aarch64-apple-darwin.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            _archive="uv-x86_64-apple-darwin.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "aarch64-pc-windows-gnu")
            _archive="uv-aarch64-pc-windows-msvc.zip"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "aarch64-pc-windows-msvc")
            _archive="uv-aarch64-pc-windows-msvc.zip"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            _archive="uv-x86_64-pc-windows-msvc.zip"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            _archive="uv-i686-pc-windows-msvc.zip"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "aarch64-unknown-linux-gnu")
            _archive="uv-aarch64-unknown-linux-gnu.tar.gz"
            if ! check_glibc "2" "28"; then
                _archive=""
            fi
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            _archive="uv-aarch64-unknown-linux-musl.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "aarch64-unknown-linux-musl-dynamic")
            _archive="uv-aarch64-unknown-linux-musl.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "aarch64-unknown-linux-musl-static")
            _archive="uv-aarch64-unknown-linux-musl.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "arm-unknown-linux-gnueabihf")
            _archive="uv-arm-unknown-linux-musleabihf.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "arm-unknown-linux-musl-dynamiceabihf")
            _archive="uv-arm-unknown-linux-musleabihf.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "arm-unknown-linux-musl-staticeabihf")
            _archive="uv-arm-unknown-linux-musleabihf.tar.gz"
            if [ -n "$_archive" ]; then
                echo "$_archive"
                return 0
            fi
            ;;
        "armv7-unknown-linux-gnueabihf")
            _archive="uv-armv7-unknown-linux-gnueabihf.tar.gz"
            if ! check_glibc "2" "17"; then
                _archive=""
            fi
            if [ -n "$_archive" ]; then
             