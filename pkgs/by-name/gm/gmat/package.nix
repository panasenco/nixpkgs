{
  lib,
  stdenv,
  cmake,
  swig,
  fetchFromGitHub,
  fetchurl,
  autoPatchelfHook,
  copyDesktopItems,
  makeDesktopItem,
  wrapGAppsHook3,
  cspice,
  glib,
  gsettings-desktop-schemas,
  jdk11_headless,
  libGL,
  libGLU,
  libX11,
  python312,
  wxwidgets_3_2,
  xercesc,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "gmat";
  version = "R2026a";

  src = fetchFromGitHub {
    owner = "NASA";
    repo = "GMAT";
    rev = finalAttrs.version;
    hash = "sha256-Tv2u9FfTD2aKoO5NZOn9NkGlSmsT2rJoMq0Y8SDNV6U=";
  };

  # The built HTML help (docs/help) is not in the git source tree;
  # upstream only ships it in the binary installers.
  docsSrc = fetchurl {
    url = "https://downloads.sourceforge.net/project/gmat/GMAT/GMAT-R2026a/gmat-ubuntu-x64-R2026a.tar.gz";
    hash = "sha256-/hJLSmBrLjtwSm+7HDe4dZjV3w0Yy2YcMEtfYAdKd1Q=";
  };

  strictDeps = true;

  nativeBuildInputs = [
    cmake
    swig
    autoPatchelfHook
    copyDesktopItems
    wrapGAppsHook3
  ];

  buildInputs = [
    cspice
    glib
    gsettings-desktop-schemas
    jdk11_headless
    libGL
    libGLU
    libX11
    python312
    wxwidgets_3_2
    xercesc
  ];

  env.JAVA_HOME = "${jdk11_headless.home}";
  # GMAT's CMake prepends its vendored wx dir to PATH, so bypass it.
  env.WX_CONFIG = "${wxwidgets_3_2}/bin/wx-config";

  cmakeFlags = [
    # GMAT resolves data/plugin paths relative to the installed executable.
    (lib.cmakeFeature "CMAKE_INSTALL_PREFIX" "${placeholder "out"}/share/gmat")
    (lib.cmakeBool "GMAT_INCLUDE_API" true)
    (lib.cmakeFeature "CSPICE_DIR" "${cspice}")
    # Build the API for one Python only, matching the shipped startup file.
    (lib.cmakeFeature "GMAT_PYTHON3_VERSIONS" "3.12")
    (lib.cmakeFeature "Python3_EXECUTABLE" "${python312}/bin/python3.12")
  ];

  preFixup = ''
    addAutoPatchelfSearchPath $out/share/gmat/bin
  '';

  postPatch = ''
    # strcpy of fixed-width arrays trips _FORTIFY_SOURCE here.
    substituteInPlace src/base/solarsys/DeFile.hpp \
      --replace-fail 'strcpy(constName[i],r.constName[i])' 'memcpy (constName[i], r.constName[i], sizeof(constName[i]))'
    # GMAT changes its CWD at runtime, so the global config must not be
    # CWD-relative; wx then resolves it against the standard user config dir.
    substituteInPlace src/gui/app/GmatAppData.cpp \
      --replace-fail 'wxCONFIG_USE_LOCAL_FILE | wxCONFIG_USE_RELATIVE_PATH);' 'wxCONFIG_USE_LOCAL_FILE);'
    # wx 3.2's GTK wxGLCanvas is not HiDPI-aware (fixed in wx 3.3); scale
    # the viewport or plots only fill the bottom-left quadrant on scaled
    # displays.
    for f in src/gui/subscriber/OrbitViewCanvas.cpp \
             src/gui/subscriber/GroundTrackCanvas.cpp; do
      substituteInPlace $f \
        --replace-fail 'glViewport(0, 0, (GLint) nWidth, (GLint) nHeight);' \
          'glViewport(0, 0, (GLint) (nWidth * GetContentScaleFactor()), (GLint) (nHeight * GetContentScaleFactor()));'
    done
    substituteInPlace src/gui/subscriber/ViewCanvas.cpp \
      --replace-fail 'glViewport(0, 0, nWidth, nHeight);' \
        'glViewport(0, 0, (GLint) (nWidth * GetContentScaleFactor()), (GLint) (nHeight * GetContentScaleFactor()));'
    substituteInPlace src/gui/spacecraft/VisualModelCanvas.cpp \
      --replace-fail 'glViewport(0, 0, w, h);' \
        'glViewport(0, 0, (GLint) (w * GetContentScaleFactor()), (GLint) (h * GetContentScaleFactor()));'
  '';

  postInstall = ''
    chmod -R u+w $out/share/gmat/lib
    rm -rf $out/share/gmat/lib
    sed -i -e 's|^PLUGIN                  = ../plugins/libMatlabInterface|#&|' \
           -e 's|^PLUGIN                  = ../plugins/proprietary/|#&|' \
           -e 's|^PLUGIN                  = ../plugins/libOpenFramesInterface|#&|' \
           -e 's|^PLUGIN                  = ../plugins/libOVtoOFI|#&|' \
      $out/share/gmat/bin/gmat_startup_file.txt
    tar xzf ${finalAttrs.docsSrc} -C $out/share/gmat --strip-components=2 GMAT/R2026a/docs
    # GMAT resolves all relative paths (plugins, data, samples, its own
    # startup file) against the CWD, so wrap it to run from a writable
    # per-user directory that mirrors the store layout one level up.
    mkdir -p $out/bin
    write_gmat_wrapper() {
      cat > $out/bin/$2 <<'EOF'
#!@bash@
GMAT_PREFIX="@store@"
dir="$HOME/.local/share/gmat"
mkdir -p "$dir/run" "$dir/output"
# ../data, ../plugins etc. must resolve from the CWD.
for name in data plugins samples docs extras matlab api; do
  if [ -d "$GMAT_PREFIX/share/gmat/$name" ] && [ ! -e "$dir/$name" ]; then
    ln -s "$GMAT_PREFIX/share/gmat/$name" "$dir/$name"
  fi
done
# Regenerate on package change so nothing points at a GC'd store path.
stamp="$dir/.store-path"
if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$GMAT_PREFIX" ]; then
  sed -e "s|^ROOT_PATH.*|ROOT_PATH                = $GMAT_PREFIX/share/gmat/|" \
      -e "s|^OUTPUT_PATH.*|OUTPUT_PATH              = $dir/output/|" \
      -e "s|^VEHICLE_EPHEM_PATH.*|VEHICLE_EPHEM_PATH         = $dir/output/|" \
      -e "s|^HELP_PATH.*|HELP_PATH                = $GMAT_PREFIX/share/gmat/docs/help|" \
      -e "s|^PERSONALIZATION_FILE.*|PERSONALIZATION_FILE     = OUTPUT_PATH/MyGmat.ini|" \
      -e "s|^\(PLUGIN[[:space:]]*=\) \.\./plugins/|\1 $GMAT_PREFIX/share/gmat/plugins/|" \
    "$GMAT_PREFIX/share/gmat/bin/gmat_startup_file.txt" > "$dir/run/gmat_startup_file.txt"
  # wx's Classic file layout reads the global config from $HOME.
  cp "$GMAT_PREFIX/share/gmat/bin/GMAT.ini" "$HOME/GMAT.ini"
  chmod 644 "$HOME/GMAT.ini" 2>/dev/null || true
  # Must exist for GMAT's personalization-file lookup.
  [ -f "$dir/output/MyGmat.ini" ] || cp "$GMAT_PREFIX/share/gmat/data/gui_config/MyGmat.ini" "$dir/output/MyGmat.ini"
  chmod 644 "$dir/output/MyGmat.ini" 2>/dev/null || true
  echo "$GMAT_PREFIX" > "$stamp"
fi
# Absolutize script arguments before cd.
args=()
for a in "$@"; do
  if [ -f "$a" ]; then
    args+=("$(readlink -f "$a")")
  else
    args+=("$a")
  fi
done
cd "$dir/run"
exec "@gmatbin@" "''${args[@]}"
EOF
      sed -i -e "s|@bash@|${stdenv.shell}|" -e "s|@store@|$out|" -e "s|@gmatbin@|$out/share/gmat/bin/$1|" $out/bin/$2
      chmod +x $out/bin/$2
    }
    write_gmat_wrapper GmatConsole-R2026a GmatConsole
    write_gmat_wrapper GMAT-R2026a GMAT
    install -Dm0644 $out/share/gmat/data/graphics/icons/GMAT_logo.png \
      $out/share/icons/hicolor/256x256/apps/gmat.png
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "gmat";
      desktopName = "GMAT";
      comment = "General Mission Analysis Tool";
      exec = "GMAT";
      icon = "gmat";
      categories = [
        "Science"
        "Engineering"
      ];
      terminal = false;
    })
  ];

  meta = {
    description = "General Mission Analysis Tool for space mission design, optimization and navigation";
    longDescription = ''
      GMAT (General Mission Analysis Tool) is an open source space mission
      design system developed by NASA. It supports missions in flight regimes
      ranging from low Earth orbit to lunar, libration point, and deep space
      missions, and can be driven through its GUI, a scripting console, or
      Python/Java APIs.
    '';
    homepage = "https://software.nasa.gov/software/GSC-19468-1";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [ panasenco ];
    mainProgram = "GMAT";
    platforms = lib.platforms.linux;
  };
})
