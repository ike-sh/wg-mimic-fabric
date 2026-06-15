#!/usr/bin/env bash

# One-line installer: curl -fsSL .../bootstrap.sh | sudo bash

# Optional: WMF_TAG=v0.1.0 to pin a release

set -euo pipefail



REPO="${WMF_REPO:-ike-sh/wg-mimic-fabric}"

TAG="${WMF_TAG:-}"

TS="$(date +%s)"



fetch_repo_file() {

    local relpath="$1" dest="$2" ref="${3:-main}"

    if curl -fsSL -H "Accept: application/vnd.github.raw+json" \

        -o "$dest" "https://api.github.com/repos/${REPO}/contents/${relpath}?ref=${ref}" 2>/dev/null; then

        return 0

    fi

    curl -fsSL -o "$dest" "https://raw.githubusercontent.com/${REPO}/${ref}/${relpath}?ts=${TS}"

}



tmp="$(mktemp /tmp/wg-mimic-install.XXXXXX)"

trap 'rm -f -- "$tmp"' EXIT



if [[ -n "$TAG" ]]; then

    [[ "$TAG" == v* ]] || TAG="v${TAG}"

    echo "[INFO] 下载 ${REPO} ${TAG} ..."

    fetch_repo_file "install.sh" "$tmp" "$TAG"

else

    echo "[INFO] 下载 ${REPO} main（最新 install.sh）..."

    fetch_repo_file "install.sh" "$tmp" "main"

fi

chmod +x "$tmp"

remote_ver="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | sed -E 's/^SCRIPT_VERSION="([^"]+)".*/\1/')"

[[ -n "$remote_ver" ]] && echo "[INFO] 远端版本：${remote_ver}"



if [[ "$(id -u)" -eq 0 ]]; then

    bash "$tmp" install-wm-cli

    ver="$(/usr/local/bin/wm --version 2>/dev/null || true)"

    [[ -n "$ver" ]] && echo "[OK] ${ver}" || { echo "[ERROR] wm 仍不可用" >&2; exit 1; }

    if [[ "${WMF_NO_MENU:-}" != "1" ]]; then

        if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]]; then

            exec /usr/local/bin/wm </dev/tty >/dev/tty 2>&1

        elif [[ -t 0 ]]; then

            exec /usr/local/bin/wm

        else

            echo "[INFO] 安装完成。运行 wm 进入管理菜单。"

        fi

    fi

else

    echo "[INFO] 非 root：仅下载 install.sh 到当前目录"

    install -m 0755 "$tmp" ./install.sh

    echo "[OK] 已保存 ./install.sh（${remote_ver:-未知版本}）"

    echo "请运行：sudo bash install.sh install-wm-cli"

fi

