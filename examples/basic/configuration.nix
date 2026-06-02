# Example NixOS configuration using the nessus-agent module
# with a local .deb (for testing) or a corporate URL.

{ config, pkgs, ... }:

{
  imports = [
    # When consumed as a flake input:
    # nessus-nix.nixosModules.nessus-agent
    ../../modules/nessus-agent.nix
  ];

  services.nessus-agent = {
    enable = true;

    # === Option A: Corporate / firewall-friendly remote .deb ===
    # (pick the _amd64 or _aarch64 build that matches the target machines)
    # debUrl = "https://repo.internal.company.com/tenable/NessusAgent-11.2.0-ubuntu1804_amd64.deb";
    # debHash = "sha256-...=";

    # === Option B: Local .deb (development) ===
    # IMPORTANT: the .deb must be for the same architecture as the machine
    # you are deploying to (amd64 on x86_64, aarch64 on arm64).  Using the
    # wrong one produces a package that will later fail with
    # "cannot execute binary file".
    package = pkgs.callPackage ../../pkgs/nessus-agent {
      debSrc = ../../NessusAgent-11.2.0-ubuntu1604_amd64.deb;  # use the _aarch64 variant on arm64
    };

    registration = {
      # For Tenable.io / Tenable One
      host = "sensor.cloud.tenable.com";
      port = 443;
      cloud = true;

      # For on-prem Tenable.sc or Nessus Manager, use:
      # host = "tenablesc.internal.company.com";
      # port = 8834;
      # cloud = false;

      # Never put the real key in git. Use sops-nix / agenix / Vault + environmentFile.
      key = "YOUR-AGENT-LINKING-KEY-HERE";   # <-- only for quick tests

      name = config.networking.hostName;
      groups = [ "nixos" "example" ];
    };
  };

  # The module already puts a working `nessuscli` in PATH.
  # You can also run it directly:
  #   /run/current-system/sw/bin/nessuscli agent status
}
