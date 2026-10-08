#!/usr/bin/env bash
#
# Build a Moonlight VRR release tag for ARM64 Linux.
#
# Targets:
#   native   Compile against the host distro's libraries and produce a
#            relocatable install tree tarball (runs on the same distro release).
#   flatpak  Build a self-contained aarch64 Flatpak bundle from the tag's
#            packaging/flatpak manifest, pinned to the tag's commit.
#   all      Both of the above.
#
# PyroWave is gated to x86_64 upstream. --pyrowave lifts that gate on other
# architectures; Granite's math code has aarch64 NEON paths, but the decoder
# is untested on ARM GPUs. x86_64 builds always include PyroWave.
#
# The Flatpak's FFmpeg is patched with an av1_v4l2m2m decoder (see
# linux-patches/) so stateful V4L2 AV1 decoders such as Qualcomm iris
# (Linux 7.0+) decode AV1 in hardware. Native builds use the distro FFmpeg.
#
# The release tag is always checked out fresh into the output directory, so
# this script can be run from any branch (or copied out of the repository).
# --source builds a local checkout (including uncommitted changes) instead.
#
# Run on a Linux host of the target arch, or pass --docker to run inside a
# container of that arch (native speed on Apple Silicon for aarch64; qemu
# emulation otherwise).

set -euo pipefail

TAG="v6.1.0-vrr18"
REPO="https://github.com/Nonary/moonlight-qt.git"
ARCH="aarch64"
OUT_ROOT=""
INSTALL_DEPS=0
USE_DOCKER=0
DOCKER_IMAGE="debian:trixie"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
TARGET=""
PYROWAVE=0
SOURCE_DIR=""
VERSION=""

FLATPAK_APP_ID="com.moonlight_stream.Moonlight"
FLATPAK_BRANCH="master"
FLATHUB_REPO="https://flathub.org/repo/flathub.flatpakrepo"

usage()
{
    cat <<EOF
Usage: $0 [options] <native|flatpak|all>

Options:
  --tag TAG           Release tag to build (default: $TAG)
  --repo URL          Git repository to clone (default: $REPO)
  --source DIR        Build this local checkout instead of cloning --tag
  --version VER       Version string (default: tag, or git describe for --source)
  --arch ARCH         aarch64 or x86_64 (default: $ARCH)
  --out DIR           Output root (default: ./build/linux-<arch>-<version>)
  --jobs N            Parallel compile jobs (default: $JOBS)
  --install-deps      Install build dependencies with apt (Debian/Ubuntu, needs sudo)
  --pyrowave          Enable the PyroWave decoder on non-x86_64 builds (experimental)
  --docker            Run the whole build inside a container of the target arch
  --docker-image IMG  Container image for --docker (default: $DOCKER_IMAGE)
  -h, --help          Show this help

Examples:
  # On a Raspberry Pi 5 / ARM SBC running Debian or Ubuntu
  $0 --install-deps all

  # From an Apple Silicon Mac (Docker or Rancher Desktop running)
  $0 --docker all

  # Flatpak of the current working tree with PyroWave
  $0 --docker --pyrowave --source . flatpak
EOF
}

fail()
{
    echo "error: $*" 1>&2
    exit 1
}

log()
{
    echo
    echo "==> $*"
}

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --out) OUT_ROOT="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --pyrowave) PYROWAVE=1; shift ;;
        --docker) USE_DOCKER=1; shift ;;
        --docker-image) DOCKER_IMAGE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        native|flatpak|all) TARGET="$1"; shift ;;
        *) usage 1>&2; fail "unknown argument: $1" ;;
    esac
done

[ -n "$TARGET" ] || { usage 1>&2; exit 1; }

case "$ARCH" in
    aarch64|arm64) ARCH="aarch64"; DOCKER_PLATFORM="linux/arm64" ;;
    x86_64|amd64) ARCH="x86_64"; DOCKER_PLATFORM="linux/amd64" ;;
    *) fail "unsupported arch: $ARCH" ;;
esac

# x86_64 already builds PyroWave; the flag only matters elsewhere
if [ "$ARCH" = "x86_64" ]; then
    PYROWAVE=0
fi

if [ -n "$SOURCE_DIR" ]; then
    [ -d "$SOURCE_DIR/app" ] || fail "$SOURCE_DIR is not a moonlight-qt checkout"
    SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
    if [ -z "$VERSION" ]; then
        VERSION="$(git -C "$SOURCE_DIR" describe --tags --dirty 2>/dev/null || true)"
        VERSION="${VERSION#v}"
        [ -n "$VERSION" ] || VERSION="$(cat "$SOURCE_DIR/app/version.txt")-local"
    fi
fi
VERSION="${VERSION:-${TAG#v}}"
SUFFIX=""
if [ "$PYROWAVE" = 1 ]; then
    SUFFIX="-pyrowave"
fi
OUT_ROOT="${OUT_ROOT:-$PWD/build/linux-$ARCH-$VERSION}"

# Widens the Linux PyroWave gate in moonlight-qt.pro and app/app.pro
PYROWAVE_SED='s/^linux:contains(QT_ARCH, x86_64):!disable-pyrowave/linux:!disable-pyrowave/'
PYROWAVE_MARKER="PyroWave GPU history"

#
# Re-exec inside a container. The output root is bind-mounted so artifacts
# land on the host. Flatpak needs --privileged for bubblewrap sandboxing.
#
if [ "$USE_DOCKER" = 1 ]; then
    command -v docker >/dev/null 2>&1 || fail "docker not found in PATH"
    # flatpak-user persists the downloaded SDK/runtime between container runs
    mkdir -p "$OUT_ROOT/flatpak-user"
    OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    # Strip host-specific options from the forwarded arguments; the version
    # is resolved here because the container may not trust the mounted .git
    FORWARD=(--version "$VERSION")
    MOUNTS=()
    skip=0
    for a in "${ORIG_ARGS[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$a" in
            --docker) ;;
            --out|--docker-image|--source|--version) skip=1 ;;
            *) FORWARD+=("$a") ;;
        esac
    done
    if [ -n "$SOURCE_DIR" ]; then
        FORWARD+=(--source /src)
        MOUNTS+=(-v "$SOURCE_DIR:/src:ro")
    fi

    log "Running inside $DOCKER_IMAGE ($DOCKER_PLATFORM)"
    exec docker run --rm -i --privileged --platform "$DOCKER_PLATFORM" \
        -v "$OUT_ROOT:/out" \
        -v "$OUT_ROOT/flatpak-user:/root/.local/share/flatpak" \
        -v "$SCRIPT_DIR:/scripts:ro" \
        ${MOUNTS[@]+"${MOUNTS[@]}"} \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e LC_ALL=C.UTF-8 \
        "$DOCKER_IMAGE" \
        bash -c 'set -e
            apt-get update -qq && apt-get install -y -qq sudo >/dev/null
            status=0
            bash /scripts/build-linux-arm.sh --install-deps --out /out "$@" || status=$?
            chown -R "$HOST_UID:$HOST_GID" /out || true
            exit $status' -- "${FORWARD[@]}"
fi

[ "$(uname -s)" = "Linux" ] || fail "this script must run on Linux (use --docker on other hosts)"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    aarch64|arm64) HOST_ARCH="aarch64" ;;
    amd64) HOST_ARCH="x86_64" ;;
esac

SUDO=""
if [ "$(id -u)" != 0 ]; then
    SUDO="sudo"
fi

need_native=0
need_flatpak=0
case "$TARGET" in
    native) need_native=1 ;;
    flatpak) need_flatpak=1 ;;
    all) need_native=1; need_flatpak=1 ;;
esac

if [ "$need_native" = 1 ] && [ "$HOST_ARCH" != "$ARCH" ]; then
    fail "native builds must run on an $ARCH host (this is $HOST_ARCH); use --docker or the flatpak target"
fi

install_deps()
{
    command -v apt-get >/dev/null 2>&1 || fail "--install-deps only supports apt-based distros"

    local pkgs=(git ca-certificates python3 xz-utils)
    if [ "$need_native" = 1 ]; then
        pkgs+=(
            build-essential pkg-config qmake6 qt6-base-dev qt6-declarative-dev
            libqt6svg6-dev qt6-tools-dev-tools
            qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-templates
            qml6-module-qtquick-layouts qml6-module-qtquick-window qml6-module-qtqml-workerscript
            libsdl2-dev libsdl2-ttf-dev libopus-dev libssl-dev
            libavcodec-dev libavformat-dev libavutil-dev libswscale-dev
            libva-dev libvdpau-dev libdrm-dev libplacebo-dev libvulkan-dev
            libwayland-dev wayland-protocols libegl-dev libgl-dev libx11-dev
        )
    fi
    if [ "$need_flatpak" = 1 ]; then
        # flatpak-builder runs patch/eu-strip/unzip on the host, and export
        # validates the SVG icon with the host gdk-pixbuf loader
        pkgs+=(flatpak flatpak-builder dbus ccache patch elfutils unzip bzip2 zstd
            librsvg2-common)
        if [ "$HOST_ARCH" != "$ARCH" ]; then
            pkgs+=(qemu-user-static binfmt-support)
        fi
    fi

    log "Installing build dependencies"
    $SUDO apt-get update
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "${pkgs[@]}"
}

if [ "$INSTALL_DEPS" = 1 ]; then
    install_deps
fi

command -v git >/dev/null 2>&1 || fail "git not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

SRC_DIR="$OUT_ROOT/src"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/linux-patches"
FFMPEG_AV1_PATCH="ffmpeg-v4l2m2m-av1.patch"
mkdir -p "$OUT_ROOT"

#
# Fetch the tagged source with submodules. Reuse an existing checkout only if
# it is still at the requested tag.
#
fetch_source()
{
    if [ -n "$SOURCE_DIR" ]; then
        # Work on a copy: the build edits files and writes a manifest into it
        log "Copying local source from $SOURCE_DIR"
        rm -rf "$SRC_DIR"
        mkdir -p "$SRC_DIR"
        tar -C "$SOURCE_DIR" --exclude=./build --exclude=.git \
            --exclude=.DS_Store -cf - . | tar -C "$SRC_DIR" -xf -
        return
    fi

    if [ -d "$SRC_DIR/.git" ]; then
        local have
        have="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || true)"
        if [ "$have" = "$TAG" ]; then
            log "Reusing existing $TAG checkout"
            # Drop edits from a previous --pyrowave run
            git -C "$SRC_DIR" reset -q --hard
            git -C "$SRC_DIR" submodule update --init --recursive
            return
        fi
        rm -rf "$SRC_DIR"
    fi

    log "Cloning $REPO at $TAG"
    git clone --branch "$TAG" --depth 1 --recurse-submodules --shallow-submodules \
        "$REPO" "$SRC_DIR"
}

fetch_source
if [ -n "$SOURCE_DIR" ]; then
    COMMIT=""
    log "Building local source as version $VERSION"
else
    COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
    log "Building $TAG ($COMMIT) as version $VERSION"
fi

#
# Native build: links against the distro's Qt, SDL, FFmpeg and libplacebo.
#
build_native()
{
    local qmake
    qmake="$(command -v qmake6 || true)"
    if [ -z "$qmake" ] && [ -x /usr/lib/qt6/bin/qmake ]; then
        qmake=/usr/lib/qt6/bin/qmake
    fi
    [ -n "$qmake" ] || fail "qmake6 not found (install qt6-base-dev / qmake6, or use --install-deps)"

    local build_dir="$OUT_ROOT/native-build"
    local stage_dir="$OUT_ROOT/native-stage"
    local distro="linux"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        distro="$(. /etc/os-release && echo "${ID}${VERSION_ID:+-$VERSION_ID}")"
    fi
    local tarball="$OUT_ROOT/Moonlight-VRR-$VERSION-$distro-$ARCH$SUFFIX.tar.gz"

    if [ "$PYROWAVE" = 1 ]; then
        log "Enabling PyroWave for $ARCH"
        sed -i "$PYROWAVE_SED" "$SRC_DIR/moonlight-qt.pro" "$SRC_DIR/app/app.pro"
        [ "$(grep -c '^linux:!disable-pyrowave' "$SRC_DIR/moonlight-qt.pro" "$SRC_DIR/app/app.pro" | grep -c ':1$')" = 2 ] \
            || fail "PyroWave gate not found in $TAG"
    fi

    rm -rf "$build_dir" "$stage_dir"
    mkdir -p "$build_dir" "$stage_dir"

    log "Configuring native build"
    (
        cd "$build_dir"
        CI_VERSION="$VERSION" "$qmake" "$SRC_DIR/moonlight-qt.pro" \
            CONFIG+=release PREFIX=/usr
    )

    log "Compiling with $JOBS jobs"
    CI_VERSION="$VERSION" make -C "$build_dir" -j"$JOBS" release

    log "Staging install tree"
    make -C "$build_dir" install INSTALL_ROOT="$stage_dir"

    [ -x "$stage_dir/usr/bin/moonlight" ] || fail "moonlight binary missing from stage"
    file "$stage_dir/usr/bin/moonlight" 2>/dev/null || true
    if [ "$PYROWAVE" = 1 ]; then
        grep -qa "$PYROWAVE_MARKER" "$stage_dir/usr/bin/moonlight" || fail "PyroWave missing from moonlight binary"
        echo "    PyroWave decoder present"
    fi

    tar -C "$stage_dir" -czf "$tarball" usr
    log "Native tarball: $tarball"
    echo "    Extract with: sudo tar -C / -xzf $(basename "$tarball")"
}

#
# Flatpak build: reuse the tag's manifest, pin the moonlight module to the
# exact tag commit and version, and build for the requested arch.
#
build_flatpak()
{
    command -v flatpak >/dev/null 2>&1 || fail "flatpak not found (use --install-deps)"

    local manifest_src="$SRC_DIR/packaging/flatpak/$FLATPAK_APP_ID.json"
    [ -f "$manifest_src" ] || fail "$TAG has no packaging/flatpak manifest"

    # Generated alongside the original so relative patch/file paths resolve
    local manifest="$SRC_DIR/packaging/flatpak/$FLATPAK_APP_ID.$ARCH.json"
    if [ -z "$COMMIT" ]; then
        # Sandboxed builds only read sources inside the manifest's directory,
        # so a local-source manifest must sit at the root of the tree
        manifest="$SRC_DIR/$FLATPAK_APP_ID.$ARCH.json"
    fi
    local fp_build="$OUT_ROOT/flatpak-build"
    local fp_repo="$OUT_ROOT/flatpak-repo"
    local fp_state="$OUT_ROOT/flatpak-state"
    local bundle="$OUT_ROOT/Moonlight-VRR-$VERSION-linux-$ARCH$SUFFIX.flatpak"

    [ -f "$PATCH_DIR/$FFMPEG_AV1_PATCH" ] || fail "missing $PATCH_DIR/$FFMPEG_AV1_PATCH"
    cp "$PATCH_DIR/$FFMPEG_AV1_PATCH" "$SRC_DIR/packaging/flatpak/"

    log "Pinning Flatpak manifest to ${COMMIT:-local source}"
    local extra_cmd=""
    if [ "$PYROWAVE" = 1 ]; then
        extra_cmd="sed -i '$PYROWAVE_SED' moonlight-qt.pro app/app.pro"
    fi
    python3 - "$manifest_src" "$manifest" "$REPO" "$TAG" "$COMMIT" "$VERSION" "$extra_cmd" "$FFMPEG_AV1_PATCH" <<'PY'
import json, os, sys
src, dst, repo, tag, commit, version, extra_cmd, av1_patch = sys.argv[1:]
manifest = json.load(open(src))
ffmpeg = next(m for m in manifest["modules"] if m["name"] == "ffmpeg")
ffmpeg["sources"].append({"type": "patch", "path": av1_patch})
ffmpeg["build-options"]["config-opts"].append("--enable-decoder=av1_v4l2m2m")
module = next(m for m in manifest["modules"] if m["name"] == "moonlight")
git = next(s for s in module["sources"] if s["type"] == "git")
if commit:
    git.update({"url": repo, "tag": tag, "commit": commit})
else:
    # Local source: the manifest sits inside the copied tree
    module["sources"][module["sources"].index(git)] = {"type": "dir", "path": "."}
    # Re-base the other relative source paths from packaging/flatpak/
    for m in manifest["modules"]:
        for source in m.get("sources", []):
            if "path" in source and source["type"] != "dir":
                source["path"] = os.path.normpath(os.path.join("packaging/flatpak", source["path"]))
for s in module["sources"]:
    if s["type"] == "shell":
        s["commands"] = [f"echo {version} > app/version.txt"] + ([extra_cmd] if extra_cmd else [])
json.dump(manifest, open(dst, "w"), indent=4)
open(dst, "a").write("\n")
PY

    flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO"

    local builder=(flatpak-builder)
    if ! command -v flatpak-builder >/dev/null 2>&1; then
        flatpak install --user -y flathub org.flatpak.Builder
        builder=(flatpak run org.flatpak.Builder)
    fi

    # flatpak-builder needs a session bus; containers usually lack one
    local wrap=()
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
        wrap=(dbus-run-session --)
    fi

    log "Building Flatpak for $ARCH (dependencies compile from source; this takes a while)"
    "${wrap[@]}" "${builder[@]}" --user --arch="$ARCH" --force-clean --sandbox \
        --install-deps-from=flathub --ccache --jobs="$JOBS" \
        --state-dir="$fp_state" --repo="$fp_repo" \
        "$fp_build" "$manifest"

    log "Verifying exported manifest"
    python3 - "$fp_build/files/manifest.json" "$COMMIT" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
modules = {m["name"]: m for m in manifest["modules"]}
if sys.argv[2]:
    assert any(s.get("commit") == sys.argv[2] for s in modules["moonlight"]["sources"]), "moonlight commit mismatch"
assert any(s["type"] == "patch" and "libplacebo-disable-internally-synchronized-queues.patch" in s["path"]
           for s in modules["libplacebo"]["sources"]), "libplacebo gamescope patch missing"
assert any(s["type"] == "patch" and s["path"].endswith("ffmpeg-v4l2m2m-av1.patch")
           for s in modules["ffmpeg"]["sources"]), "FFmpeg AV1 V4L2 patch missing"
print("    moonlight commit, libplacebo and FFmpeg patches verified")
PY
    grep -qa "av1_v4l2m2m" "$fp_build"/files/lib/libavcodec.so.* || fail "av1_v4l2m2m missing from libavcodec"
    echo "    av1_v4l2m2m decoder present"
    if [ "$PYROWAVE" = 1 ] || [ "$ARCH" = "x86_64" ]; then
        grep -qa "$PYROWAVE_MARKER" "$fp_build/files/bin/moonlight" || fail "PyroWave missing from moonlight binary"
        echo "    PyroWave decoder present"
    fi

    log "Exporting bundle"
    flatpak build-bundle --arch="$ARCH" --runtime-repo="$FLATHUB_REPO" \
        "$fp_repo" "$bundle" "$FLATPAK_APP_ID" "$FLATPAK_BRANCH"

    log "Flatpak bundle: $bundle"
    echo "    Install with: flatpak install --user --reinstall $(basename "$bundle")"
}

if [ "$need_native" = 1 ]; then
    build_native
fi
if [ "$need_flatpak" = 1 ]; then
    build_flatpak
fi

log "Done. Artifacts in $OUT_ROOT"
ls -lh "$OUT_ROOT"/*.tar.gz "$OUT_ROOT"/*.flatpak 2>/dev/null || true
