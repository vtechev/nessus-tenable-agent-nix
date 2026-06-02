{ lib
, stdenv
, dpkg
, autoPatchelfHook
, glibc
, debSrc ? null
}:

assert (debSrc != null) || throw
  "nessus-agent: you must supply `debSrc` (the .deb for your architecture, e.g. the amd64 or aarch64 Ubuntu build). See the README.";

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
    # Give autoPatchelfHook a glibc it can use to rewrite the dynamic linker
    # (the .deb ships with a stock /lib/ld-linux-... interpreter).
    glibc
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

    # Architecture guard.
    # The .deb must contain binaries whose ELF machine type matches the
    # platform we are building for.  A mismatch produces a package that
    # will later fail at runtime with the unhelpful
    # "cannot execute binary file".  Fail early with a clear message.
    local bin="$out/opt/nessus_agent/sbin/nessus-service"
    if [ -f "$bin" ]; then
      # e_machine is at offset 18 (little-endian u16 for both common arches)
      local em
      em=$(od -An -tu2 -j 18 -N 2 --endian=little "$bin" 2>/dev/null | tr -d '[:space:]' || echo 0)
      local expected=0
      case "${stdenv.hostPlatform.parsed.cpu.name}" in
        x86_64)  expected=62 ;;   # EM_X86_64
        aarch64) expected=183 ;;  # EM_AARCH64
      esac
      if [ "$expected" != 0 ] && [ "$em" != "$expected" ]; then
        echo "ERROR: debSrc contains a binary for a different architecture (ELF e_machine=$em)"
        echo "       than the platform this package is being built for (${stdenv.hostPlatform.system}, expected $expected)."
        echo "Use the architecture-matched NessusAgent .deb (amd64 vs aarch64) for your system."
        echo "See README.md and the examples."
        exit 1
      fi
    fi

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
    # Make sure the interpreter is a Nix store path (the .deb ships with
    # a stock /lib/ld-linux-... that won't exist at runtime, neither on
    # a plain NixOS host nor inside our FHS environment unless we also
    # populate it with glibc).
    #
    # We do this unconditionally for the shipped executables as a belt-and-
    # suspenders measure; autoPatchelfHook is great but does not always
    # touch every binary living under opt/ on every combination of builder
    # and deb.
    local interp
    interp=$(< "$NIX_CC/nix-support/dynamic-linker")

    for bin in $out/opt/nessus_agent/sbin/* $out/opt/nessus_agent/bin/*; do
      if [ -f "$bin" ] && [ -x "$bin" ]; then
        # Only rewrite if it still looks like a distro path (idempotent otherwise).
        if patchelf --print-interpreter "$bin" 2>/dev/null | grep -q '^/lib'; then
          patchelf --set-interpreter "$interp" "$bin" 2>/dev/null || true
        fi
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
