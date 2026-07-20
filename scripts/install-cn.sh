#!/bin/sh
set -eu

# =============================================================================
# install-cn.sh — 中国国内网络环境适配版
#
# 与 install.sh 的主要区别:
#   - Claude Code: 使用 npm 安装 (@anthropic-ai/claude-code@2.1.150)
#   - Codex: 使用 npm 安装，非交互模式
#   - npm: 使用 npmmirror 镜像源 (registry.npmmirror.com)
#   - uv: 优先通过 pip (清华镜像) 安装，备选原始安装脚本
#   - Python: 通过 UV_PYTHON_INSTALL_MIRROR 使用 npmmirror 镜像下载
#   - GitHub 资源: 通过 ghproxy.net 代理加速
# =============================================================================

# ---- 国内镜像源与代理配置 ----
NPM_REGISTRY="https://registry.npmmirror.com"
PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
UV_PYTHON_INSTALL_MIRROR="https://registry.npmmirror.com/-/binary/python/"
GH_PROXY="https://ghproxy.net/"

# ---- 仓库与版本 ----
REPO_ARCHIVE_URL="https://github.com/Alishahryar1/free-claude-code/archive/refs/heads/main.zip"
PYTHON_VERSION="3.14.0"
MIN_UV_VERSION="0.11.16"

# ---- npm 包定义 ----
CLAUDE_NPM_PACKAGE="@anthropic-ai/claude-code"
CLAUDE_NPM_VERSION="2.1.150"
CODEX_NPM_PACKAGE="@openai/codex"

# ---- Pi 安装地址 ----
PI_INSTALL_URL="https://pi.dev/install.sh"

# ---- uv 安装脚本 (通过代理) ----
UV_INSTALL_SCRIPT_URL="${GH_PROXY}https://raw.githubusercontent.com/astral-sh/uv/main/scripts/install.sh"

FCC_COMMANDS="fcc-server fcc-claude fcc-codex fcc-pi fcc-init free-claude-code"

dry_run=0
voice_nim=0
voice_local=0
voice_all=0
torch_backend=""
temporary_script=""

show_usage() {
    cat <<'USAGE'
Usage: install-cn.sh [options]

安装 Claude Code、Codex 和 Pi（如缺失），确保 uv 版本兼容，并安装或更新 Free Claude Code。
中国国内网络环境适配版。

选项:
  --voice-nim              安装 NVIDIA NIM 语音转录支持。
  --voice-local            安装本地 Whisper 语音转录支持。
  --voice-all              安装所有语音转录后端。
  --torch-backend VALUE    使用 uv PyTorch 后端，例如 cu130。需要 --voice-local。
  --dry-run                仅打印命令，不实际执行。
  --help                   显示此帮助信息。

国内适配说明:
  - Claude Code 通过 npm 安装，版本 2.1.150
  - Codex 通过 npm 安装
  - npm 使用 npmmirror 镜像 (registry.npmmirror.com)
  - pip 使用清华镜像 (pypi.tuna.tsinghua.edu.cn)
  - Python 下载使用 npmmirror 镜像
  - GitHub 资源通过 ghproxy.net 代理加速

前置依赖:
  - curl, bash, sh, mktemp（通常系统自带）
  - npm (Node.js 自带，推荐通过 nvm 安装: nvm install --lts)
  - pip (Python 自带，或通过 python -m ensurepip 安装)
USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$1"
}

quote_arg() {
    case "$1" in
        *[!A-Za-z0-9_./:@%+=,-]*|"")
            escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '"%s"' "$escaped"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

print_command() {
    printf '+'
    for arg in "$@"; do
        printf ' '
        quote_arg "$arg"
    done
    printf '\n'
}

run() {
    print_command "$@"
    if [ "$dry_run" -eq 1 ]; then
        return 0
    fi

    if "$@"; then
        return 0
    else
        status=$?
    fi

    fail "Command failed with exit code $status: $1"
}

cleanup() {
    if [ -n "$temporary_script" ] && [ -e "$temporary_script" ]; then
        rm -f "$temporary_script"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

add_path_entry() {
    [ -n "$1" ] || return 0
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="$1:$PATH" ;;
    esac
}

add_known_bin_directories() {
    if [ -n "${XDG_BIN_HOME:-}" ]; then
        add_path_entry "$XDG_BIN_HOME"
    fi

    if [ -n "${HOME:-}" ]; then
        add_path_entry "$HOME/.local/bin"
        add_path_entry "$HOME/.cargo/bin"
        add_path_entry "${XDG_DATA_HOME:-$HOME/.local/share}/pi-node/current/bin"
    fi

    export PATH
    hash -r 2>/dev/null || true
}

add_pi_bin_directories() {
    [ "$dry_run" -eq 0 ] || return 0
    add_known_bin_directories
    if command -v npm >/dev/null 2>&1; then
        pi_npm_prefix=$(npm prefix -g 2>/dev/null || npm config get prefix 2>/dev/null || true)
        if [ -n "$pi_npm_prefix" ]; then
            add_path_entry "$pi_npm_prefix/bin"
            export PATH
            hash -r 2>/dev/null || true
        fi
    fi
}

fcc_process_ids() {
    command_name=$1

    if command -v pgrep >/dev/null 2>&1; then
        {
            pgrep -x "$command_name" 2>/dev/null || true
            pgrep -f "(^|/)${command_name}([[:space:]]|$)" 2>/dev/null || true
        } | sort -nu
        return 0
    fi

    ps -A -o pid= -o args= 2>/dev/null |
        awk -v command_name="$command_name" '
            BEGIN {
                pattern = "(^|/)" command_name "([[:space:]]|$)"
            }
            {
                process_id = $1
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                if ($0 ~ pattern) {
                    print process_id
                }
            }
        ' || true
}

assert_no_fcc_processes_running() {
    running=""
    for command_name in $FCC_COMMANDS; do
        process_ids=$(fcc_process_ids "$command_name")
        [ -n "$process_ids" ] || continue

        for process_id in $process_ids; do
            process="$command_name (PID $process_id)"
            if [ -n "$running" ]; then
                running="$running, $process"
            else
                running=$process
            fi
        done
    done

    if [ -n "$running" ]; then
        fail "Free Claude Code is still running ($running). Stop those processes, then rerun the installer."
    fi
}

require_command() {
    if [ "$dry_run" -eq 0 ] && ! command -v "$1" >/dev/null 2>&1; then
        fail "$1 is required. Install it first, then rerun this installer."
    fi
}

download_and_run() {
    url=$1
    interpreter=$2
    label=$3
    non_interactive=${4:-0}

    if [ "$dry_run" -eq 1 ]; then
        print_command curl -fsSL "$url" -o "<temporary-script>"
        if [ "$non_interactive" -eq 1 ]; then
            printf '+ CODEX_NON_INTERACTIVE=1 '
            quote_arg "$interpreter"
            printf ' <temporary-script>\n'
        else
            print_command "$interpreter" "<temporary-script>"
        fi
        return 0
    fi

    temporary_script=$(mktemp "${TMPDIR:-/tmp}/fcc-install.XXXXXX") || fail "Unable to create a temporary file for $label."
    print_command curl -fsSL "$url" -o "$temporary_script"
    if curl -fsSL "$url" -o "$temporary_script"; then
        :
    else
        status=$?
        fail "Could not download the $label installer (curl exit code $status)."
    fi

    if [ ! -s "$temporary_script" ]; then
        fail "The downloaded $label installer was empty."
    fi

    if [ "$non_interactive" -eq 1 ]; then
        printf '+ CODEX_NON_INTERACTIVE=1 '
        quote_arg "$interpreter"
        printf ' '
        quote_arg "$temporary_script"
        printf '\n'
        if CODEX_NON_INTERACTIVE=1 "$interpreter" "$temporary_script"; then
            :
        else
            status=$?
            fail "$label installation failed with exit code $status."
        fi
    else
        print_command "$interpreter" "$temporary_script"
        if "$interpreter" "$temporary_script"; then
            :
        else
            status=$?
            fail "$label installation failed with exit code $status."
        fi
    fi

    rm -f "$temporary_script"
    temporary_script=""
}

verify_command() {
    command_name=$1
    display_name=$2

    if [ "$dry_run" -eq 1 ]; then
        print_command "$command_name" --version
        return 0
    fi

    command_path=$(command -v "$command_name" 2>/dev/null) || fail "$display_name was installed, but '$command_name' is not available on PATH."
    run "$command_path" --version
}

pi_command_is_compatible() {
    pi_command_path=$(command -v pi 2>/dev/null) || return 1
    pi_help=$("$pi_command_path" --help 2>/dev/null) || return 1
    case "$pi_help" in
        *--extension*) ;;
        *) return 1 ;;
    esac
    case "$pi_help" in
        *--models*) return 0 ;;
        *) return 1 ;;
    esac
}

verify_pi_command() {
    if [ "$dry_run" -eq 1 ]; then
        printf '+ pi --help (verify --extension and --models support)\n'
        print_command pi --version
        return 0
    fi

    pi_command_path=$(command -v pi 2>/dev/null) || fail "Pi was installed, but 'pi' is not available on PATH."
    pi_command_is_compatible || fail "The 'pi' command at $pi_command_path is not a compatible Pi Coding Agent."
    run "$pi_command_path" --version
}

# ---- npm 安装辅助函数 ----

ensure_npm() {
    if command -v npm >/dev/null 2>&1; then
        printf 'npm already found on PATH.\n'
        return 0
    fi
    fail "npm is not installed. Please install Node.js first (recommend nvm: https://github.com/nvm-sh/nvm)."
}

npm_global_install() {
    package_spec=$1
    label=$2

    if [ "$dry_run" -eq 1 ]; then
        print_command npm install -g --registry "$NPM_REGISTRY" "$package_spec"
        return 0
    fi

    print_command npm install -g --registry "$NPM_REGISTRY" "$package_spec"
    if npm install -g --registry "$NPM_REGISTRY" "$package_spec"; then
        return 0
    else
        status=$?
        fail "$label installation via npm failed with exit code $status."
    fi
}

# ---- Claude Code: npm 安装 ----

ensure_claude() {
    if command -v claude >/dev/null 2>&1; then
        printf 'Claude Code already found on PATH; verifying it.\n'
    else
        npm_global_install "${CLAUDE_NPM_PACKAGE}@${CLAUDE_NPM_VERSION}" "Claude Code"
        add_known_bin_directories
    fi

    verify_command claude "Claude Code"
}

# ---- Codex: npm 安装 ----

ensure_codex() {
    if command -v codex >/dev/null 2>&1; then
        printf 'Codex already found on PATH; verifying it.\n'
    else
        npm_global_install "$CODEX_NPM_PACKAGE" "Codex"
        add_known_bin_directories
    fi

    verify_command codex "Codex"
}

# ---- Pi: 保持官方安装方式 ----

ensure_pi() {
    if [ "$dry_run" -eq 1 ] && command -v pi >/dev/null 2>&1; then
        printf 'Pi already found on PATH; verifying it.\n'
    elif pi_command_is_compatible; then
        printf 'Pi already found on PATH; verifying it.\n'
    else
        if existing_pi_path=$(command -v pi 2>/dev/null); then
            printf "The existing 'pi' command at %s is not Pi Coding Agent; installing Pi.\n" "$existing_pi_path"
        fi
        download_and_run "$PI_INSTALL_URL" sh "Pi"
        add_pi_bin_directories
    fi

    verify_pi_command
}

# ---- uv 版本检测与安装 ----

current_uv_version() {
    if output=$(uv --version); then
        :
    else
        return 1
    fi

    case "$output" in
        uv\ *) version=${output#uv } ;;
        *) version=$output ;;
    esac
    version=${version%% *}

    case "$version" in
        [0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$version" ;;
        *) return 1 ;;
    esac
}

uv_version_is_supported() {
    case "$1" in
        *-*) return 1 ;;
    esac

    current=${1%%+*}
    minimum=${2%%+*}

    old_ifs=$IFS
    IFS=.
    set -- $current
    current_major=${1:-0}
    current_minor=${2:-0}
    current_patch=${3:-0}
    set -- $minimum
    minimum_major=${1:-0}
    minimum_minor=${2:-0}
    minimum_patch=${3:-0}
    IFS=$old_ifs

    case "$current_major$current_minor$current_patch$minimum_major$minimum_minor$minimum_patch" in
        *[!0-9]*) return 1 ;;
    esac

    [ "$current_major" -gt "$minimum_major" ] && return 0
    [ "$current_major" -lt "$minimum_major" ] && return 1
    [ "$current_minor" -gt "$minimum_minor" ] && return 0
    [ "$current_minor" -lt "$minimum_minor" ] && return 1
    [ "$current_patch" -ge "$minimum_patch" ]
}

verify_uv() {
    if [ "$dry_run" -eq 1 ]; then
        print_command uv --version
        return 0
    fi

    command -v uv >/dev/null 2>&1 || fail "uv was installed, but it is not available on PATH."
    version=$(current_uv_version) || fail "uv is present, but 'uv --version' did not return a valid version."
    if ! uv_version_is_supported "$version" "$MIN_UV_VERSION"; then
        fail "Stable uv $MIN_UV_VERSION or newer is required; found uv $version after installation."
    fi

    printf 'Verified uv %s.\n' "$version"
}

ensure_uv() {
    if [ "$dry_run" -eq 1 ]; then
        if command -v uv >/dev/null 2>&1; then
            print_command uv --version
            printf 'A compatible existing uv will be left unchanged; an obsolete one will be replaced by the standalone installer.\n'
        else
            printf 'uv is not installed; will try pip (Tsinghua mirror) then standalone installer.\n'
            download_and_run "$UV_INSTALL_SCRIPT_URL" sh "uv"
            verify_uv
        fi
        return 0
    fi

    if command -v uv >/dev/null 2>&1; then
        version=$(current_uv_version) || fail "uv is present, but 'uv --version' did not return a valid version."
        if uv_version_is_supported "$version" "$MIN_UV_VERSION"; then
            printf 'uv %s already satisfies >=%s; leaving it unchanged.\n' "$version" "$MIN_UV_VERSION"
            return 0
        fi
        printf 'uv %s does not satisfy stable >=%s; installing the current standalone uv.\n' "$version" "$MIN_UV_VERSION"
    else
        printf 'uv is not installed.\n'
    fi

    # 优先尝试 pip (清华镜像)，备选 GitHub 代理安装脚本
    if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
        pip_cmd="pip3"
        command -v pip3 >/dev/null 2>&1 || pip_cmd="pip"
        printf 'Attempting uv installation via %s (Tsinghua mirror)...\n' "$pip_cmd"
        print_command "$pip_cmd" install -i "$PIP_INDEX_URL" uv
        if "$pip_cmd" install -i "$PIP_INDEX_URL" uv; then
            add_known_bin_directories
        else
            printf 'pip install failed, falling back to standalone installer via ghproxy...\n'
            download_and_run "$UV_INSTALL_SCRIPT_URL" sh "uv"
            add_known_bin_directories
        fi
    else
        printf 'pip not found, using standalone installer via ghproxy...\n'
        download_and_run "$UV_INSTALL_SCRIPT_URL" sh "uv"
        add_known_bin_directories
    fi

    verify_uv
}

# ---- 参数解析与校验 ----

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --voice-nim)
                voice_nim=1
                ;;
            --voice-local)
                voice_local=1
                ;;
            --voice-all)
                voice_all=1
                ;;
            --torch-backend)
                shift
                [ "$#" -gt 0 ] || fail "--torch-backend requires a value."
                torch_backend=$1
                [ -n "$torch_backend" ] || fail "--torch-backend requires a non-empty value."
                ;;
            --torch-backend=*)
                torch_backend=${1#*=}
                [ -n "$torch_backend" ] || fail "--torch-backend requires a non-empty value."
                ;;
            --dry-run)
                dry_run=1
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                show_usage >&2
                fail "unknown option: $1"
                ;;
        esac
        shift
    done
}

validate_args() {
    include_local=$voice_local
    if [ "$voice_all" -eq 1 ]; then
        include_local=1
    fi

    if [ -n "$torch_backend" ] && [ "$include_local" -ne 1 ]; then
        fail "--torch-backend requires --voice-local or --voice-all."
    fi
}

# ---- Free Claude Code 安装 ----

package_spec() {
    include_nim=$voice_nim
    include_local=$voice_local

    if [ "$voice_all" -eq 1 ]; then
        include_nim=1
        include_local=1
    fi

    if [ "$include_nim" -eq 1 ] && [ "$include_local" -eq 1 ]; then
        printf 'free-claude-code[voice,voice_local] @ %s' "$REPO_ARCHIVE_URL"
    elif [ "$include_nim" -eq 1 ]; then
        printf 'free-claude-code[voice] @ %s' "$REPO_ARCHIVE_URL"
    elif [ "$include_local" -eq 1 ]; then
        printf 'free-claude-code[voice_local] @ %s' "$REPO_ARCHIVE_URL"
    else
        printf 'free-claude-code @ %s' "$REPO_ARCHIVE_URL"
    fi
}

install_free_claude_code() {
    assert_no_fcc_processes_running
    spec=$(package_spec)

    if [ -n "$torch_backend" ]; then
        run uv tool install --force --refresh-package free-claude-code --python "$PYTHON_VERSION" --torch-backend "$torch_backend" "$spec"
    else
        run uv tool install --force --refresh-package free-claude-code --python "$PYTHON_VERSION" "$spec"
    fi
}

configure_and_verify_free_claude_code() {
    run uv tool update-shell

    if [ "$dry_run" -eq 1 ]; then
        print_command uv tool dir --bin
        printf '+ verify fcc-server, fcc-claude, fcc-codex, and fcc-pi in the uv tool bin directory\n'
        print_command fcc-server --version
        return 0
    fi

    print_command uv tool dir --bin
    if tool_bin=$(uv tool dir --bin); then
        :
    else
        status=$?
        fail "Could not determine the uv tool bin directory (exit code $status)."
    fi
    [ -n "$tool_bin" ] || fail "uv returned an empty tool bin directory."

    add_path_entry "$tool_bin"
    export PATH
    hash -r 2>/dev/null || true

    for command_name in fcc-server fcc-claude fcc-codex fcc-pi; do
        [ -x "$tool_bin/$command_name" ] || fail "Free Claude Code installation did not create $tool_bin/$command_name."
    done

    run "$tool_bin/fcc-server" --version
}

# ---- 主流程 ----

parse_args "$@"
validate_args
add_known_bin_directories

# 设置国内镜像环境变量，使 uv python install 使用国内源
export UV_PYTHON_INSTALL_MIRROR

step "Checking for running Free Claude Code processes"
assert_no_fcc_processes_running

step "Checking installation prerequisites"
require_command curl
require_command bash
require_command sh
require_command mktemp
require_command npm

step "Ensuring Claude Code is installed (npm: ${CLAUDE_NPM_PACKAGE}@${CLAUDE_NPM_VERSION})"
ensure_claude

step "Ensuring Codex is installed (npm: ${CODEX_NPM_PACKAGE})"
ensure_codex

step "Ensuring Pi is installed"
ensure_pi

step "Ensuring uv $MIN_UV_VERSION or newer is installed (CN mirrors: pip + ghproxy)"
ensure_uv

step "Installing or updating Free Claude Code"
install_free_claude_code

step "Configuring PATH and verifying Free Claude Code"
configure_and_verify_free_claude_code

if [ "$dry_run" -eq 1 ]; then
    printf '\nDry run complete. No changes were made.\n'
else
    printf '\nFree Claude Code is installed and verified. Start the proxy with: fcc-server\n'
    printf 'Run Claude Code with: fcc-claude\n'
    printf 'Run Codex with: fcc-codex\n'
    printf 'Run Pi with: fcc-pi\n'
fi
