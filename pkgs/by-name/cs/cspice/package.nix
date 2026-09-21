{
  lib,
  stdenv,
  fetchurl,
  tcsh,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "cspice";
  version = "N0067";

  src = fetchurl {
    url = "https://naif.jpl.nasa.gov/pub/naif/misc/toolkit_${finalAttrs.version}/C/PC_Linux_GCC_64bit/packages/cspice.tar.Z";
    hash = "sha256-YKlbUaZHLxr+fkDXfr3uQ8ErtbiCNnbMx0aS3f7eBs4=";
  };

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [ tcsh ];

  # Upstream ships prebuilt libraries in lib/, replace them with a source build.
  # -ansi is required: the f2c-generated sources rely on implicit int, which
  # modern gcc rejects without it.
  env.TKCOMPILEOPTIONS = "-c -ansi -O2 -fPIC -DNON_UNIX_STDIO";
  env.TKLINKOPTIONS = "-lm";

  postPatch = ''
    rm lib/*.a
  '';

  buildPhase = ''
    runHook preBuild
    for prod in cspice csupport; do
      (cd src/$prod && tcsh ./mkprodct.csh)
    done
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -t $out/include include/*.h
    install -D -t $out/lib lib/*.a
    runHook postInstall
  '';

  meta = {
    description = "NASA NAIF SPICE toolkit for reading and writing SPICE data files";
    homepage = "https://naif.jpl.nasa.gov/naif/aboutspice.html";
    # NAIF's rules allow redistributing SPICE modules as part of a larger
    # package, but the license is not OSI-approved.
    license = lib.licenses.unfreeRedistributable;
    maintainers = with lib.maintainers; [ panasenco ];
    platforms = lib.platforms.linux;
  };
})
