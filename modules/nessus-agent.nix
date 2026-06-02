{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nessus-agent;

  # The "real" extracted package (the tree under /opt/nessus_agent)
  realPackage = cfg.package;

  # FHS environment that provides a traditional Linux view + the agent at /opt/nessus_agent
  # This is required because the agent is distributed as a .deb with glibc expectations
  # and vendored libraries that assume FHS layout for some dlopen() calls.
  fhsEnv = pkgs.buildFHSEnv {
    name = "nessus-agent-fhs";
    targetPkgs = pkgs: with pkgs; [
      coreutils
      procps
      nettools
      iproute2
      # Provide a dynamic linker at the classic FHS locations (/lib, /lib64)
      # so that binaries that still carry the stock Ubuntu interpreter
      # (or that dlopen via FHS paths) can run inside the environment.
      glibc
      # Common runtime deps that enterprise agents often pull in
      stdenv.cc.cc.lib
      zlib
      curl
      openssl
      # Add more here if the agent complains about missing .so at runtime
    ];
    extraInstallCommands = ''
      # Provide a mixed /opt/nessus_agent view inside the FHS rootfs, mirroring the
      # host tmpfiles structure (ro symlinks for code, real dirs for state).
      # At runtime the bwrap --bind for host /opt will overlay the host's (writable
      # state) view, but having a consistent structure in the rootfs helps for any
      # early lookups or interactive `nessus-agent-fhs` sessions.
      mkdir -p $out/opt/nessus_agent
      ln -s ${realPackage}/opt/nessus_agent/bin $out/opt/nessus_agent/bin
      ln -s ${realPackage}/opt/nessus_agent/sbin $out/opt/nessus_agent/sbin
      ln -s ${realPackage}/opt/nessus_agent/lib $out/opt/nessus_agent/lib
      ln -s ${realPackage}/opt/nessus_agent/etc $out/opt/nessus_agent/etc

      mkdir -p $out/opt/nessus_agent/com/nessus/CA
      mkdir -p $out/opt/nessus_agent/var/nessus
      # (state subdirs like logs/ etc. will be empty in the rootfs; host bind provides the real ones)

      # Convenience wrappers so "nessuscli" and "nessus-service" just work
      # when users enter the FHS or when we invoke them from systemd.
      mkdir -p $out/bin
      cat > $out/bin/nessuscli << 'WRAPPER'
#!/usr/bin/env bash
exec /opt/nessus_agent/sbin/nessuscli "$@"
WRAPPER
      chmod +x $out/bin/nessuscli

      cat > $out/bin/nessus-service << 'WRAPPER'
#!/usr/bin/env bash
exec /opt/nessus_agent/sbin/nessus-service "$@"
WRAPPER
      chmod +x $out/bin/nessus-service
    '';
    runScript = "bash";
    extraOutputsToInstall = [ "out" ];
  };

  # NOTE on invocation:
  # Because we use runScript = "bash", the generated `nessus-agent-fhs` wrapper
  # ultimately does `exec bash "$@"` (after bwrap + profile).
  # Passing a path as the first argument (old style) makes bash treat that path
  # as a *shell script to execute*, which fails for a binary with
  # "cannot execute binary file".
  # The correct way to run an arbitrary program is with -c:
  #   nessus-agent-fhs -c 'exec /the/command args...'
  # We use the in-FHS convenience names (/bin/nessus-service etc.) that
  # extraInstallCommands installs; they in turn exec the real /opt tree.


  # Script used by the registration service
  registerScript = pkgs.writeShellScript "nessus-agent-register" ''
    set -euo pipefail

    export PATH="${fhsEnv}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.systemd}/bin:$PATH"
    NESSUS_PREFIX="/opt/nessus_agent"
    NESSUSCLI="$NESSUS_PREFIX/sbin/nessuscli"

    # Wait for the main service to be ready
    for i in $(seq 1 30); do
      if "$NESSUSCLI" agent status >/dev/null 2>&1; then
        break
      fi
      echo "Waiting for Nessus Agent to become ready... ($i/30)"
      sleep 2
    done

    # Check if already linked
    if "$NESSUSCLI" agent status 2>&1 | grep -qiE "(linked|already linked|status:.*ok)"; then
      echo "Nessus Agent is already linked. Skipping registration."
      exit 0
    fi

    echo "Linking Nessus Agent..."

    LINK_ARGS=(
      --key="@KEY@"
      --host="@HOST@"
      --port="@PORT@"
    )

    ${optionalString (cfg.registration.name != null) ''
      LINK_ARGS+=( --name="@NAME@" )
    ''}

    ${optionalString (cfg.registration.groups != []) ''
      LINK_ARGS+=( --groups="@GROUPS@" )
    ''}

    ${optionalString (cfg.registration.proxyHost != null) ''
      LINK_ARGS+=( --proxy-host="@PROXY_HOST@" )
      ${optionalString (cfg.registration.proxyPort != null) ''
        LINK_ARGS+=( --proxy-port="@PROXY_PORT@" )
      ''}
    ''}

    ${optionalString (cfg.registration.proxyUsername != null) ''
      LINK_ARGS+=( --proxy-username="@PROXY_USER@" )
    ''}

    # Note: proxy password is passed via environment (see below) or the
    # password file mechanism if Tenable supports it in your version.
    # Most versions accept --proxy-password on the command line.

    ${optionalString (cfg.registration.proxyPasswordFile != null) ''
      # Read password from file into the command line (agent will redact in logs)
      PROXY_PASS="$(cat "@PROXY_PASSWORD_FILE@")"
      LINK_ARGS+=( --proxy-password="$PROXY_PASS" )
    ''}

    ${optionalString cfg.registration.cloud ''
      LINK_ARGS+=( --cloud )
    ''}

    # Source any additional environment (for proxy passwords etc.)
    ${optionalString (cfg.environmentFile != null) ''
      set -a
      source "@ENV_FILE@"
      set +a
    ''}

    # Perform the link (idempotent guard is above)
    "$NESSUSCLI" agent link "''${LINK_ARGS[@]}"

    echo "Nessus Agent registration complete."
  '';

  # Substitute placeholders in the register script for this config.
  # Uses replaceVarsWith (successor to the removed substituteAll) with
  # a conditionally-built replacements set so that we only provide
  # entries for @PLACEHOLDER@s that actually appear in the generated
  # script text (the script template uses optionalString to include
  # some @VAR@ lines only for certain config values). This satisfies
  # replaceVarsWith's strict --replace-fail + leftover-@ check.
  registerScriptFinal = pkgs.replaceVarsWith {
    src = registerScript;
    replacements =
      {
        KEY =
          if cfg.registration.keyFile != null
          then "$(cat ${cfg.registration.keyFile})"
          else cfg.registration.key;
        HOST = cfg.registration.host;
        PORT = toString cfg.registration.port;
      }
      // optionalAttrs (cfg.registration.name != null) {
        NAME = cfg.registration.name;
      }
      // optionalAttrs (cfg.registration.groups != []) {
        GROUPS = concatStringsSep "," cfg.registration.groups;
      }
      // optionalAttrs (cfg.registration.proxyHost != null) (
        {
          PROXY_HOST = cfg.registration.proxyHost;
        }
        // optionalAttrs (cfg.registration.proxyPort != null) {
          PROXY_PORT = toString cfg.registration.proxyPort;
        }
      )
      // optionalAttrs (cfg.registration.proxyUsername != null) {
        PROXY_USER = cfg.registration.proxyUsername;
      }
      // optionalAttrs (cfg.registration.proxyPasswordFile != null) {
        PROXY_PASSWORD_FILE = cfg.registration.proxyPasswordFile;
      }
      // optionalAttrs (cfg.environmentFile != null) {
        ENV_FILE = cfg.environmentFile;
      };
    isExecutable = true;
  };

  # The actual systemd unit for the agent daemon
  serviceConfig = {
    Description = "Tenable Nessus Agent";
    After = [ "network-online.target" ];
    Wants = [ "network-online.target" ];

    # Use -c so bash (our runScript) executes the string as a command rather
    # than treating the first token as a "script file" name. See the long
    # comment next to the fhsEnv definition.
    ExecStart = "${fhsEnv}/bin/nessus-agent-fhs -c 'exec /bin/nessus-service -q'";

    Restart = "on-abort";
    RestartSec = "10s";

    # The agent performs system inventory and may need broad access.
    # It is common to run it as root (matching the .deb behavior).
    # You can override with serviceConfig.User / SupplementaryGroups if you
    # create a dedicated user and adjust permissions on /opt/nessus_agent.
    User = "root";

    # Hardening (tune to your environment)
    PrivateTmp = true;
    ProtectSystem = "full";
    ProtectHome = "read-only";
    NoNewPrivileges = true;

    # The agent (and its registration) need to create state under the install prefix
    # (var/nessus/* for logs/state, com/ for comms). Whitelist it so ProtectSystem/ProtectHome
    # don't make the prefix ro for this service. The tmpfiles above ensure the state subdirs
    # are real (rw) dirs while code subdirs are symlinks into the store.
    ReadWritePaths = [ "/opt/nessus_agent" ];

    # Give it the FHS environment variables if needed
    Environment = [
      "NESSUS_PREFIX=/opt/nessus_agent"
      "LD_LIBRARY_PATH=/opt/nessus_agent/lib/nessus"
    ];
  };

in
{
  options.services.nessus-agent = {
    enable = mkEnableOption "Tenable Nessus Agent";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../pkgs/nessus-agent { };
      defaultText = literalExpression "pkgs.callPackage ./pkgs/nessus-agent { }";
      description = ''
        The Nessus Agent package to use. This should be the result of
        `pkgs.callPackage ./pkgs/nessus-agent { debSrc = ...; }` or an override.
      '';
    };

    # Convenience options for corporate firewall / internal mirror use case
    debUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://artifacts.internal.company.com/nessus/NessusAgent-11.2.0-ubuntu1804_aarch64.deb";
      description = ''
        When set, the module will fetch the .deb from this URL (instead of
        requiring you to pass a full package via `package`).
        Use together with `debHash`.
      '';
    };

    debHash = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=";
      description = "Hash of the .deb file when using `debUrl`.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to open the firewall for the Nessus Agent.
        The agent primarily initiates outbound connections, so this is
        usually not required unless you are using a non-standard listening port.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/agenix/nessus-agent.env";
      description = ''
        Environment file containing secrets (e.g. proxy passwords).
        Loaded by both the main service and the registration service.
        Format: KEY=VALUE lines.
      '';
    };

    registration = {
      host = mkOption {
        type = types.str;
        example = "sensor.cloud.tenable.com";
        description = ''
          The hostname or IP of the Tenable.io instance, Tenable.sc, or
          Nessus Manager / broker that this agent should link to.
          For Tenable.io cloud this is usually `sensor.cloud.tenable.com` or `cloud.tenable.com`.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 443;
        description = "TCP port for the registration host (usually 443).";
      };

      key = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The agent registration key (also called "linking key" or "group key").
          **Prefer `keyFile`** for secret hygiene. The value ends up in the Nix store.
        '';
      };

      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/agenix/nessus-agent-key";
        description = ''
          Path to a file containing only the registration key.
          Recommended for production (works with sops-nix, agenix, etc.).
        '';
      };

      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "web-server-03";
        description = ''
          Optional friendly name for this agent in the Tenable console.
          Defaults to the system's hostname if unset.
        '';
      };

      groups = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "production" "linux-servers" "pci" ];
        description = "Optional list of agent groups to assign the agent to.";
      };

      cloud = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to use Tenable.io cloud linking semantics (`--cloud` flag).
          Set to false when linking to an on-premises Tenable.sc or Nessus Manager.
        '';
      };

      proxyHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "proxy.corp.example.com";
        description = "HTTP(S) proxy hostname for registration (and subsequent communication).";
      };

      proxyPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        example = 8080;
        description = "Proxy port.";
      };

      proxyUsername = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Username for authenticated proxy.";
      };

      proxyPasswordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          File containing the proxy password (one line).
          The password is read at registration time.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.debUrl != null) -> (cfg.debHash != null);
        message = "services.nessus-agent: `debHash` is required when `debUrl` is set.";
      }
      {
        assertion = (cfg.registration.key != null) || (cfg.registration.keyFile != null);
        message = "services.nessus-agent: either `registration.key` or `registration.keyFile` must be provided.";
      }
      {
        assertion = cfg.registration.host != "";
        message = "services.nessus-agent: `registration.host` must be set.";
      }
    ];

    # If the user gave debUrl + debHash, synthesize the package for them.
    services.nessus-agent.package = mkIf (cfg.debUrl != null) (
      pkgs.callPackage ../pkgs/nessus-agent {
        debSrc = pkgs.fetchurl {
          url = cfg.debUrl;
          hash = cfg.debHash;
        };
      }
    );

    # The agent binary tree must be present at the path it was compiled for.
    # We create a mixed /opt/nessus_agent tree via systemd-tmpfiles:
    # - real directory for the prefix (on the host root fs, which is rw)
    # - L+ symlinks only for the immutable code/config subtrees (bin, sbin, lib, etc.)
    #   so they come from the current store package and update on upgrade
    # - d (and L+ for static initial content) for the state subtrees (var/nessus/* and com/*)
    #   so the agent can create/write its logs, state (master.key, users, etc.), tmp, etc.
    # This replaces the previous full L+ symlink (which pointed the entire tree at the ro store).
    # The FHS bwrap binds the host /opt (rw for the state parts), so the agent inside sees
    # a writable prefix for the parts it needs while code remains immutable.
    systemd.tmpfiles.rules = [
      "d /opt/nessus_agent 0755 root root -"
      "L+ /opt/nessus_agent/bin - - - - ${realPackage}/opt/nessus_agent/bin"
      "L+ /opt/nessus_agent/sbin - - - - ${realPackage}/opt/nessus_agent/sbin"
      "L+ /opt/nessus_agent/lib - - - - ${realPackage}/opt/nessus_agent/lib"
      "L+ /opt/nessus_agent/etc - - - - ${realPackage}/opt/nessus_agent/etc"
      "d /opt/nessus_agent/com 0755 root root -"
      "d /opt/nessus_agent/com/nessus 0755 root root -"
      "d /opt/nessus_agent/com/nessus/CA 0755 root root -"
      "d /opt/nessus_agent/var 0755 root root -"
      "d /opt/nessus_agent/var/nessus 0755 root root -"
      # Static initial resources from the package (updated on upgrade via new ${realPackage})
      "L+ /opt/nessus_agent/var/nessus/icudt77l.dat - - - - ${realPackage}/opt/nessus_agent/var/nessus/icudt77l.dat"
      "L+ /opt/nessus_agent/var/nessus/nessus_org.pem - - - - ${realPackage}/opt/nessus_agent/var/nessus/nessus_org.pem"
      "L+ /opt/nessus_agent/var/nessus/nessus-services - - - - ${realPackage}/opt/nessus_agent/var/nessus/nessus-services"
      "L+ /opt/nessus_agent/var/nessus/tools - - - - ${realPackage}/opt/nessus_agent/var/nessus/tools"
      # Writable state subdirs (agent creates logs, tmp files, user state, modules, etc. here)
      "d /opt/nessus_agent/var/nessus/logs 0755 root root -"
      "d /opt/nessus_agent/var/nessus/tmp 0755 root root -"
      "d /opt/nessus_agent/var/nessus/users 0755 root root -"
      "d /opt/nessus_agent/var/nessus/mod 0755 root root -"
    ];

    systemd.services.nessusagent = {
      description = "Tenable Nessus Agent";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = serviceConfig // {
        # Allow the service to read the environment file (if any)
        EnvironmentFile = mkIf (cfg.environmentFile != null) [ cfg.environmentFile ];
      };
    };

    # One-shot service that performs (idempotent) agent linking/registration.
    # Runs after the main daemon is up.
    systemd.services.nessus-agent-register = {
      description = "Register Tenable Nessus Agent (one-time linking)";
      after = [ "nessusagent.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      requires = [ "nessusagent.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = registerScriptFinal;
        EnvironmentFile = mkIf (cfg.environmentFile != null) [ cfg.environmentFile ];

        # Give the registration step a reasonable timeout
        TimeoutStartSec = "5min";
      };
    };

    # Make nessuscli easily available for manual operations
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "nessuscli" ''
        # Use -c + the forwarding trick so bash runs the command instead of
        # treating the path as a script file. The first token after the -c
        # string becomes $0 inside the -c code; the rest become $@.
        exec ${fhsEnv}/bin/nessus-agent-fhs -c 'exec /bin/nessuscli "$@"' nessuscli "$@"
      '')
    ];

    # Optional firewall (rarely needed)
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.registration.port ];
  };
}
