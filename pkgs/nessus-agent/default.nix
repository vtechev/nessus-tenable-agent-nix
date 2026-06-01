{ lib
, stdenv
, dpkg
, autoPatchelfHook
, debSrc ? null
}:

stdenv.mkDerivation rec {
  pname = "nessus-agent";
  version = "11.2.0";

  src = debSrc;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];

  buildInputs = [
    stdenv.cc.cc.lib
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x $src .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    # The deb extracts to ./opt/nessus_agent
    mkdir -p $out
    cp -r opt $out/

    # Replicate the "nessuscli install" step from postinst:
    # Extract the core plugins bundle so the agent doesn't need to do it at first start.
    local pluginsSrc="$out/opt/nessus_agent/var/nessus/plugins-core.tar.gz"
    local pluginsDst="$out/opt/nessus_agent/lib/nessus/plugins"
    if [ -f "$pluginsSrc" ]; then
      mkdir -p "$pluginsDst"
      tar -xzf "$pluginsSrc" -C "$pluginsDst"
      echo "Extracted core plugins to $pluginsDst"
    fi

    runHook postInstall
  '';

  # The binaries vendor most of their libraries, but we still want basic
  # autoPatchelf for the dynamic loader and any system glibc bits.
  # We keep the vendored lib/nessus in the rpath search.
  autoPatchelfIgnoreMissingDeps = true;

  postFixup = ''
    # Ensure the vendored libraries are discoverable via RUNPATH where possible.
    # Most binaries already have $ORIGIN references; this is a safety net.
    for bin in $out/opt/nessus_agent/sbin/* $out/opt/nessus_agent/bin/*; do
      if [ -f "$bin" ] && [ -x "$bin" ]; then
        patchelf --add-rpath "$out/opt/nessus_agent/lib/nessus" "$bin" 2>/dev/null || true
      fi
    done || true
  '';

  meta = with lib; {
    description = "Tenable Nessus Agent";
    homepage = "https://www.tenable.com/products/nessus/nessus-essentials";
    license = licenses.unfree;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}
