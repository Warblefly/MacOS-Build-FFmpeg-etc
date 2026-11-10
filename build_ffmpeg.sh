#!/usr/bin/env bash
set -Eeuo pipefail

PREFIX="/usr/local"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STAMP_DIR="${SCRIPT_DIR}/.build-stamps"
KLVANC_DIR="${SCRIPT_DIR}/libklvanc"
LENSFUN_DIR="${SCRIPT_DIR}/lensfun"
FDK_AAC_DIR="${SCRIPT_DIR}/fdk-aac"
FFMPEG_DIR="${SCRIPT_DIR}/FFmpeg"
SUBRANDR_DIR="${SCRIPT_DIR}/subrandr"
MPV_DIR="${SCRIPT_DIR}/mpv"
JOBS="$(sysctl -n hw.logicalcpu)"

REBUILD_KLVANC=false
REBUILD_LENSFUN=false
REBUILD_FDK_AAC=false
REBUILD_FFMPEG=false
REBUILD_SUBRANDR=false
REBUILD_MPV=false
UPDATE_SOURCES=true

for arg in "$@"; do
  case "${arg}" in
    --rebuild-all)
      REBUILD_KLVANC=true
      REBUILD_LENSFUN=true
      REBUILD_FDK_AAC=true
      REBUILD_FFMPEG=true
      REBUILD_SUBRANDR=true
      REBUILD_MPV=true
      ;;
    --rebuild-libklvanc) REBUILD_KLVANC=true ;;
    --rebuild-lensfun)   REBUILD_LENSFUN=true ;;
    --rebuild-fdk-aac)   REBUILD_FDK_AAC=true ;;
    --rebuild-ffmpeg)    REBUILD_FFMPEG=true ;;
    --rebuild-mpv)       REBUILD_MPV=true ;;
    --no-update)         UPDATE_SOURCES=false ;;
    *)
      printf 'Unknown option: %s\n' "${arg}" >&2
      printf '%s\n' \
        'Options: --rebuild-all --rebuild-libklvanc --rebuild-lensfun' \
        '         --rebuild-fdk-aac --rebuild-ffmpeg --rebuild-mpv --no-update' >&2
      exit 2
      ;;
  esac
done

mkdir -p "${STAMP_DIR}"

# Locally compiled software is installed in /usr/local. Homebrew remains in
# /opt/homebrew and supplies other build tools and dependencies.
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
export PATH="${PREFIX}/bin${BREW_PREFIX:+:${BREW_PREFIX}/bin}:${PATH}"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig${BREW_PREFIX:+:${BREW_PREFIX}/lib/pkgconfig:${BREW_PREFIX}/share/pkgconfig}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export CMAKE_PREFIX_PATH="${PREFIX}${BREW_PREFIX:+:${BREW_PREFIX}}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"

DECKLINK_PREFIX="$(brew --prefix decklinksdk 2>/dev/null || true)"
DECKLINK_FLAGS="${DECKLINK_PREFIX:+-I${DECKLINK_PREFIX}/include}"

if [[ -n "${BREW_PREFIX}" ]] && brew --prefix libtool >/dev/null 2>&1; then
  LIBTOOL_PREFIX="$(brew --prefix libtool)"
  export PATH="${LIBTOOL_PREFIX}/bin:${LIBTOOL_PREFIX}/libexec/gnubin:${PATH}"
  export ACLOCAL_PATH="${LIBTOOL_PREFIX}/share/aclocal${ACLOCAL_PATH:+:${ACLOCAL_PATH}}"
fi

clone_or_update() {
  local url="$1"
  local dir="$2"

  if [[ ! -d "${dir}/.git" ]]; then
    git clone --depth 1 "${url}" "${dir}"
    return
  fi

  printf '==> Using existing checkout: %s\n' "${dir}"
  if [[ "${UPDATE_SOURCES}" == true ]]; then
    if git -C "${dir}" diff --quiet && git -C "${dir}" diff --cached --quiet; then
      git -C "${dir}" pull --ff-only
    else
      printf '==> Local changes found; not updating %s\n' "${dir}"
    fi
  fi
}

current_commit() {
  git -C "$1" rev-parse HEAD
}

stamp_matches() {
  local stamp="$1"
  local expected="$2"
  [[ -f "${stamp}" ]] && [[ "$(cat "${stamp}")" == "${expected}" ]]
}

pkg_uses_usr_local() {
  local package="$1"
  command -v pkg-config >/dev/null 2>&1 || return 1
  pkg-config --exists "${package}" || return 1
  [[ "$(pkg-config --variable=prefix "${package}")" == "${PREFIX}" ]]
}

install_stamp() {
  printf '%s\n' "$2" > "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$1" >&2
    return 1
  }
}

build_libklvanc() {
  local stamp="${STAMP_DIR}/libklvanc.commit"
  local commit

  clone_or_update https://github.com/stoth68000/libklvanc.git "${KLVANC_DIR}"
  commit="$(current_commit "${KLVANC_DIR}")"

  if [[ "${REBUILD_KLVANC}" == false ]] && \
     stamp_matches "${stamp}" "${commit}" && \
     pkg_uses_usr_local libklvanc; then
    printf '==> libklvanc is current; skipping build.\n'
    return
  fi

  printf '==> Building libklvanc into %s\n' "${PREFIX}"
  cd "${KLVANC_DIR}"
  mkdir -p m4

  # Temporarily modernise the old Libtool macro without leaving the checkout dirty.
  cp configure.ac configure.ac.build-script-backup
  sed -i '' \
    's/^[[:space:]]*AC_PROG_LIBTOOL[[:space:]]*$/LT_INIT/' \
    configure.ac

  glibtoolize --force --copy
  if ! autoreconf --force --install --verbose \
       -I m4 ${LIBTOOL_PREFIX:+-I "${LIBTOOL_PREFIX}/share/aclocal"}; then
    mv configure.ac.build-script-backup configure.ac
    return 1
  fi
  mv configure.ac.build-script-backup configure.ac

  ./configure \
    --prefix="${PREFIX}" \
    --enable-shared \
    --disable-static

  make -j "${JOBS}"
  sudo make install

  install_stamp "${stamp}" "${commit}"
  pkg_uses_usr_local libklvanc || {
    printf 'ERROR: pkg-config is not selecting /usr/local libklvanc.\n' >&2
    return 1
  }
}

build_lensfun() {
  local stamp="${STAMP_DIR}/lensfun.commit"
  local commit

  clone_or_update https://github.com/lensfun/lensfun.git "${LENSFUN_DIR}"
  commit="$(current_commit "${LENSFUN_DIR}")"

  if [[ "${REBUILD_LENSFUN}" == false ]] && \
     stamp_matches "${stamp}" "${commit}" && \
     pkg_uses_usr_local lensfun && \
     grep -q 'lf_db_create' "${PREFIX}/include/lensfun/lensfun.h"; then
    printf '==> Lensfun is current; skipping build.\n'
    return
  fi

  printf '==> Building Lensfun into %s\n' "${PREFIX}"
  rm -rf "${LENSFUN_DIR}/cmake-build"

  cmake -S "${LENSFUN_DIR}" -B "${LENSFUN_DIR}/cmake-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_NAME_DIR="${PREFIX}/lib" \
    -DBUILD_STATIC=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_DOC=OFF \
    -DBUILD_LENSTOOL=OFF \
    -DINSTALL_HELPER_SCRIPTS=OFF \
    -DINSTALL_PYTHON_MODULE=OFF

  cmake --build "${LENSFUN_DIR}/cmake-build" --parallel "${JOBS}"
  sudo cmake --install "${LENSFUN_DIR}/cmake-build"

  install_stamp "${stamp}" "${commit}"
  pkg_uses_usr_local lensfun || {
    printf 'ERROR: pkg-config is not selecting /usr/local Lensfun.\n' >&2
    return 1
  }
  grep -q 'lf_db_create' "${PREFIX}/include/lensfun/lensfun.h" || {
    printf 'ERROR: installed Lensfun header lacks lf_db_create.\n' >&2
    return 1
  }
}

build_fdk_aac() {
  local stamp="${STAMP_DIR}/fdk-aac.commit"
  local commit
  local package

  require_command cmake
  require_command pkg-config

  clone_or_update https://github.com/mstorsjo/fdk-aac.git "${FDK_AAC_DIR}"
  commit="$(current_commit "${FDK_AAC_DIR}")"

  if [[ "${REBUILD_FDK_AAC}" == false ]] && \
     stamp_matches "${stamp}" "${commit}" && \
     pkg_uses_usr_local fdk-aac && \
     pkg_uses_usr_local fdk-xhe-aac; then
    printf '==> fdk-aac is current; skipping build.\n'
    return
  fi

  printf '==> Building fdk-aac into %s\n' "${PREFIX}"
  rm -rf "${FDK_AAC_DIR}/cmake-build"

  cmake -S "${FDK_AAC_DIR}" -B "${FDK_AAC_DIR}/cmake-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_NAME_DIR="${PREFIX}/lib" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_PROGRAMS=OFF \
    -DFDK_AAC_INSTALL_PKGCONFIG_MODULE=ON

  cmake --build "${FDK_AAC_DIR}/cmake-build" --parallel "${JOBS}"
  sudo cmake --install "${FDK_AAC_DIR}/cmake-build"

  for package in fdk-aac fdk-xhe-aac; do
    pkg_uses_usr_local "${package}" || {
      printf 'ERROR: pkg-config is not selecting /usr/local %s.\n' \
        "${package}" >&2
      return 1
    }
  done

  install_stamp "${stamp}" "${commit}"
}

build_ffmpeg() {
  local stamp="${STAMP_DIR}/ffmpeg.build"
  local commit fdk_aac_key option_hash build_key

  clone_or_update https://github.com/FFmpeg/FFmpeg.git "${FFMPEG_DIR}"
  commit="$(current_commit "${FFMPEG_DIR}")"

  for package in fdk-aac fdk-xhe-aac; do
    pkg_uses_usr_local "${package}" || {
      printf 'ERROR: FFmpeg requires /usr/local %s.\n' "${package}" >&2
      return 1
    }
  done

  fdk_aac_key="$(cat "${STAMP_DIR}/fdk-aac.commit" 2>/dev/null || printf 'unknown')"

  # Compatibility fix for DeckLink SDK releases that expose IUnknownUUID on macOS.
  if [[ -f "${FFMPEG_DIR}/libavdevice/decklink_common.h" ]] && \
     ! grep -q 'define IID_IUnknown' "${FFMPEG_DIR}/libavdevice/decklink_common.h"; then
    sed -i '' '/#define DECKLINK_FREE(s) CFRelease(s)/a\
#define IID_IUnknown CFUUIDGetUUIDBytes(IUnknownUUID)
' "${FFMPEG_DIR}/libavdevice/decklink_common.h"
  fi

  local standard_options=(
    "--prefix=${PREFIX}"
    "--logfile=/dev/tty"
    "--extra-cflags=-I${PREFIX}/include${BREW_PREFIX:+ -I${BREW_PREFIX}/include}${DECKLINK_FLAGS:+ ${DECKLINK_FLAGS}}"
    "--extra-cxxflags=-I${PREFIX}/include${BREW_PREFIX:+ -I${BREW_PREFIX}/include}${DECKLINK_FLAGS:+ ${DECKLINK_FLAGS}}"
    "--extra-ldflags=-L${PREFIX}/lib${BREW_PREFIX:+ -L${BREW_PREFIX}/lib} -Wl,-rpath,${PREFIX}/lib"
  )

  local licensing_options=(
    --enable-nonfree
    --enable-version3
    --enable-gpl
  )

  local configuration_options=(
    --disable-static
    --enable-shared
    --enable-runtime-cpudetect
    --enable-gray
    --disable-w32threads
  )

  local component_options=(
    --enable-filter=frei0r
    --enable-decoder=aac
  )

  local library_options=(
    --enable-libsvtav1
    --enable-frei0r
    --enable-libaom
    --enable-libass
    --enable-libbluray
    --enable-libbs2b
    --enable-libcaca
    --enable-libcdio
    --enable-libcodec2
    --enable-libdc1394
    --enable-libfdk-aac
    --enable-libfdk-xhe-aac
    --enable-libflite
    --enable-libfontconfig
    --enable-libfreetype
    --enable-libfribidi
    --enable-libgme
    --enable-gnutls
    --enable-libgsm
    --enable-libilbc
    --enable-libjxl
    --enable-libklvanc
    --enable-liblc3
    --enable-liblensfun
    --enable-libmodplug
    --enable-libmp3lame
    --enable-libopencore-amrnb
    --enable-libopencore-amrwb
    --enable-libopenmpt
    --enable-libopus
    --enable-librist
    --enable-librubberband
    --enable-librtmp
    --enable-libsnappy
    --enable-libsoxr
    --enable-libspeex
    --enable-libsrt
    --enable-libtesseract
    --enable-libtheora
    --enable-libtwolame
    --enable-libvidstab
    --enable-libvmaf
    --enable-libvo-amrwbenc
    --enable-libvorbis
    --enable-libvpx
    --enable-libwebp
    --enable-libx264
    --enable-libx265
    --enable-libxvid
    --enable-libxml2
    --enable-libzimg
    --enable-libzmq
    --enable-libzvbi
    --enable-lv2
    --enable-decklink
    --enable-libmysofa
    --enable-vulkan
    --enable-opencl
    --enable-libharfbuzz
    --enable-libdav1d
    --enable-libplacebo
    --enable-libxeve
    --enable-libxevd
    --enable-libopencolorio
  )

  local toolchain_options=(
    --extra-version=Compiled_by_John_Warburton
  )

  local developer_options=(
    --enable-lto
    --disable-debug
    --enable-stripping
  )

  local all_options=(
    "${standard_options[@]}"
    "${licensing_options[@]}"
    "${configuration_options[@]}"
    "${component_options[@]}"
    "${library_options[@]}"
    "${toolchain_options[@]}"
    "${developer_options[@]}"
  )

  option_hash="$(printf '%s\0' "${all_options[@]}" | shasum -a 256 | awk '{print $1}')"
  build_key="${commit}:${fdk_aac_key}:${option_hash}"

  if [[ "${REBUILD_FFMPEG}" == false ]] && \
     stamp_matches "${stamp}" "${build_key}" && \
     [[ -x "${PREFIX}/bin/ffmpeg" ]]; then
    printf '==> FFmpeg is current and its options are unchanged; skipping build.\n'
    return
  fi

  printf '==> Building FFmpeg into %s\n' "${PREFIX}"
  cd "${FFMPEG_DIR}"

  if [[ -f ffbuild/config.mak ]]; then
    make distclean
  fi

  ./configure "${all_options[@]}"
  make -j "${JOBS}"

  # Build these extra tools before installation. They remain in the source tree.
  make tools/ismindex tools/graph2dot

  sudo make install
  install_stamp "${stamp}" "${build_key}"

  
  ENCODERS="$("${PREFIX}/bin/ffmpeg" -hide_banner -encoders 2>/dev/null)"
  grep -Eq '[[:space:]]libfdk_aac[[:space:]]' <<<"${ENCODERS}" || { printf 'ERROR: installed FFmpeg lacks libfdk_aac.\n' >&2; return 1; }


  local filter

  FILTERS="$("${PREFIX}/bin/ffmpeg" -hide_banner -filters 2>/dev/null)"
  for filter in drawtext subtitles ass; do
    grep -Eq "[[:space:]]${filter}[[:space:]]" <<<"${FILTERS}" || { printf 'ERROR: missing FFmpeg filter: %s\n' "${filter}" >&2; return 1; }
  done

  otool -L "${PREFIX}/bin/ffmpeg" | grep -q "${PREFIX}/lib/libav" || {
    printf 'ERROR: FFmpeg is not linked to shared libraries in %s/lib.\n' "${PREFIX}" >&2
    return 1
  }
}

build_subrandr() {
  local stamp="${STAMP_DIR}/subrandr.commit"
  local commit stage install_root
  local fontconfig_prefix freetype_prefix harfbuzz_prefix
  local cargo_rustflags cargo_library_path dep_prefix

  require_command brew
  require_command cargo
  require_command rustc
  require_command pkg-config

  fontconfig_prefix="$(brew --prefix fontconfig)"
  freetype_prefix="$(brew --prefix freetype)"
  harfbuzz_prefix="$(brew --prefix harfbuzz)"

  for dep_prefix in \
    "${fontconfig_prefix}" \
    "${freetype_prefix}" \
    "${harfbuzz_prefix}"; do
    [[ -d "${dep_prefix}/lib" ]] || {
      printf 'ERROR: expected Homebrew library directory not found: %s/lib\n' \
        "${dep_prefix}" >&2
      return 1
    }
  done

  pkg-config --exists fontconfig freetype2 harfbuzz || {
    printf 'ERROR: pkg-config cannot find Fontconfig, FreeType, or HarfBuzz.\n' >&2
    return 1
  }

  clone_or_update https://github.com/afishhh/subrandr.git "${SUBRANDR_DIR}"
  commit="$(current_commit "${SUBRANDR_DIR}")"

  if [[ "${REBUILD_SUBRANDR}" == false ]] && \
     stamp_matches "${stamp}" "${commit}" && \
     pkg_uses_usr_local subrandr && \
     pkg-config --atleast-version=1.1.0 subrandr; then
    printf '==> Subrandr is current; skipping build.\n'
    return
  fi

  printf '==> Building Subrandr into %s\n' "${PREFIX}"
  cd "${SUBRANDR_DIR}"

  # Subrandr currently emits -lfontconfig, -lfreetype, and -lharfbuzz but the
  # macOS linker also needs the Homebrew library directories supplied via -L.
  cargo_rustflags="${RUSTFLAGS:-}"
  for dep_prefix in \
    "${fontconfig_prefix}" \
    "${freetype_prefix}" \
    "${harfbuzz_prefix}"; do
    cargo_rustflags+=" -L native=${dep_prefix}/lib"
  done

  cargo_library_path="${fontconfig_prefix}/lib:${freetype_prefix}/lib:${harfbuzz_prefix}/lib"
  cargo_library_path+="${LIBRARY_PATH:+:${LIBRARY_PATH}}"

  # Build and stage the installation as the normal user. The Subrandr
  # installer currently expects DESTDIR to include the final prefix.
  stage="$(mktemp -d "${TMPDIR:-/tmp}/subrandr-install.XXXXXX")"
  install_root="${stage}${PREFIX}"
  mkdir -p "${install_root}"

  if ! env -u CARGO_ENCODED_RUSTFLAGS \
       RUSTFLAGS="${cargo_rustflags}" \
       LIBRARY_PATH="${cargo_library_path}" \
       PKG_CONFIG_PATH="${PKG_CONFIG_PATH}" \
       cargo xtask install \
         --prefix "${PREFIX}" \
         --destdir "${install_root}"; then
    rm -rf "${stage}"
    return 1
  fi

  # Only the final copy into /usr/local needs elevation.
  sudo ditto "${install_root}" "${PREFIX}"
  rm -rf "${stage}"

  # Cargo embeds its target-directory path as the dylib's install name.
  # Rewrite it to the final installed location before anything links to it.
  local subrandr_dylib
  subrandr_dylib="$(find "${PREFIX}/lib" -maxdepth 1 \
    -name 'libsubrandr*.dylib' -print -quit)"

  otool -D "${subrandr_dylib}" | grep -qx \
    "${PREFIX}/lib/$(basename "${subrandr_dylib}")" || {
      printf 'ERROR: Subrandr dylib has an incorrect install name.\n' >&2
      otool -D "${subrandr_dylib}" >&2
      return 1
    }

  sudo install_name_tool \
    -id "${PREFIX}/lib/$(basename "${subrandr_dylib}")" \
    "${subrandr_dylib}"

  pkg_uses_usr_local subrandr || {
    printf 'ERROR: pkg-config is not selecting /usr/local Subrandr.\n' >&2
    return 1
  }

  pkg-config --atleast-version=1.1.0 subrandr || {
    printf 'ERROR: mpv requires Subrandr 1.1.0 or newer.\n' >&2
    return 1
  }

  [[ -f "${PREFIX}/include/subrandr/subrandr.h" ]] || {
    printf 'ERROR: Subrandr C header was not installed.\n' >&2
    return 1
  }

  find "${PREFIX}/lib" -maxdepth 1 -name 'libsubrandr*.dylib' -print -quit |
    grep -q . || {
      printf 'ERROR: Subrandr shared library was not installed.\n' >&2
      return 1
    }

  install_stamp "${stamp}" "${commit}"
  printf '==> Subrandr built and installed successfully.\n'
}


build_mpv() {
  local stamp="${STAMP_DIR}/mpv.build"
  local commit ffmpeg_key option_hash build_key
  local package

  require_command meson
  require_command ninja
  require_command pkg-config

  clone_or_update https://github.com/mpv-player/mpv.git "${MPV_DIR}"
  commit="$(current_commit "${MPV_DIR}")"

  # mpv must use the FFmpeg installation produced above, not Homebrew FFmpeg.
  for package in \
    libavcodec libavfilter libavformat libavutil libswresample libswscale; do
    pkg_uses_usr_local "${package}" || {
      printf 'ERROR: pkg-config is not selecting /usr/local %s.\n' "${package}" >&2
      printf '       Selected pc file: %s\n' \
        "$(pkg-config --variable=pcfiledir "${package}" 2>/dev/null || printf 'not found')" >&2
      return 1
    }
  done

  for package in libass libplacebo; do
    pkg-config --exists "${package}" || {
      printf 'ERROR: mpv requires %s, but pkg-config cannot find it.\n' "${package}" >&2
      return 1
    }
  done

  local mpv_options=(
    "--prefix=${PREFIX}"
    --buildtype=release
    --wrap-mode=nofallback
    -Dcplayer=true
    -Dlibmpv=true
    -Dtests=false
    -Db_lto=true
    -Dcocoa=enabled
    -Dcoreaudio=enabled
    -Dgl=enabled
    -Dgl-cocoa=enabled
    -Dmacos-cocoa-cb=enabled
    -Dvideotoolbox-gl=enabled
    -Dvideotoolbox-pl=auto
    -Dlibavdevice=enabled
    -Dlibarchive=auto
    -Dlibbluray=auto
    -Dlibcurl=auto
    -Dlua=auto
    -Djavascript=auto
    -Drubberband=auto
    -Dzimg=auto
    -Dmanpage-build=auto
  )

  ffmpeg_key="$(cat "${STAMP_DIR}/ffmpeg.build" 2>/dev/null || printf 'unknown')"
  option_hash="$(printf '%s\0' "${mpv_options[@]}" | shasum -a 256 | awk '{print $1}')"
  build_key="${commit}:${ffmpeg_key}:${option_hash}"

  if [[ "${REBUILD_MPV}" == false ]] && \
     stamp_matches "${stamp}" "${build_key}" && \
     [[ -x "${PREFIX}/bin/mpv" ]]; then
    printf '==> mpv is current, FFmpeg is unchanged, and options match; skipping build.\n'
    return
  fi

  printf '==> Building mpv against FFmpeg in %s\n' "${PREFIX}"
  rm -rf "${MPV_DIR}/build"

  meson setup "${MPV_DIR}/build" "${MPV_DIR}" "${mpv_options[@]}"
  meson compile -C "${MPV_DIR}/build" -j "${JOBS}"

  "${MPV_DIR}/build/mpv" --no-config --version

  # --no-rebuild prevents the privileged install step from recompiling anything.
  sudo "$(command -v meson)" install \
    -C "${MPV_DIR}/build" \
    --no-rebuild

  install_stamp "${stamp}" "${build_key}"

  [[ -x "${PREFIX}/bin/mpv" ]] || {
    printf 'ERROR: mpv was not installed at %s/bin/mpv.\n' "${PREFIX}" >&2
    return 1
  }

  "${PREFIX}/bin/mpv" --no-config --version | grep -q 'FFmpeg library versions' || {
    printf 'ERROR: installed mpv did not report its FFmpeg library versions.\n' >&2
    return 1
  }

  otool -L "${PREFIX}/bin/mpv" | grep -q "${PREFIX}/lib/libav" || {
    printf 'ERROR: mpv is not linked to FFmpeg libraries in %s/lib.\n' "${PREFIX}" >&2
    otool -L "${PREFIX}/bin/mpv" >&2
    return 1
  }
}

build_libklvanc
build_lensfun
build_fdk_aac
build_ffmpeg
build_subrandr
build_mpv

printf '\nSUCCESS\n'
printf 'FFmpeg installed at: %s/bin/ffmpeg\n' "${PREFIX}"
printf 'mpv installed at:    %s/bin/mpv\n' "${PREFIX}"
printf 'Local pkg-config path: %s\n' "${PKG_CONFIG_PATH}"
printf 'This nonfree FFmpeg build is for local use and must not be redistributed.\n'

