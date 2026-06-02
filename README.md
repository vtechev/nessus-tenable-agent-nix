# nessus-nix

NixOS module + package for the Tenable Nessus Agent, designed for corporate / firewall-restricted environments.

## Features

- Installs the agent from a **custom .deb URL** (your internal artifact server, Artifactory, Nexus, S3, etc.)
- No dependency on Tenable's public download site
- Proper declarative systemd service (not the .deb's postinst scripts)
- Idempotent registration / linking via a dedicated oneshot service
- Supports proxy settings, agent groups, custom names, on-prem Tenable.sc, etc.
- Provides a working `nessuscli` wrapper in `PATH`
- Uses an FHS environment so the vendored binaries and libraries "just work"

## Quick start (corporate mirror)

```nix
# flake.nix
{
  inputs.nessus-nix.url = "github:yourorg/nessus-nix";

  outputs = { self, nixpkgs, nessus-nix, ... }: {
    nixosConfigurations.myserver = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        nessus-nix.nixosModules.nessus-agent
        ({ config, ... }: {
          services.nessus-agent = {
            enable = true;

            # Point at your internal, firewall-approved location
            # Use the _amd64 or _aarch64 build that matches the target machines.
            debUrl  = "https://artifacts.internal.company.com/tenable/NessusAgent-11.2.0-ubuntu1804_amd64.deb";
            debHash = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=";

            registration = {
              host = "sensor.cloud.tenable.com";   # or your Tenable.sc / broker
              port = 443;
              keyFile = config.sops.secrets.nessus-agent-key.path;  # recommended
              # key = "....";  # only for testing – ends up in the store
              name = config.networking.hostName;
              groups = [ "production" "aarch64" ];
              cloud = true;   # set false for on-prem Nessus Manager / Tenable.sc
            };

            # If you need a proxy just for the initial link (or always)
            # registration.proxyHost = "proxy.corp.example.com";
            # registration.proxyPort = 8080;
          };

          # Example with sops-nix
          sops.secrets.nessus-agent-key = {};
        })
      ];
    };
  };
}
```

Then:

```bash
nixos-rebuild switch
journalctl -u nessusagent -u nessus-agent-register -f
nessuscli agent status
```

## Manual linking (debugging)

The module installs a wrapper so this works from a normal shell:

```bash
nessuscli agent link --help
nessuscli agent status
```

If you ever need to re-link, stop the registration service, delete the link state, and restart it:

```bash
systemctl stop nessus-agent-register
rm -f /opt/nessus_agent/var/nessus/master.key   # or whatever state files exist
systemctl start nessus-agent-register
```

## Using a local .deb (development / testing)

```nix
services.nessus-agent = {
  enable = true;
  package = pkgs.callPackage ./pkgs/nessus-agent {
    # Must match the architecture of the machine you will deploy to.
    debSrc = ./NessusAgent-11.2.0-ubuntu1604_amd64.deb; # or the _aarch64 variant
  };

  registration = { ... };
};
```

## Architecture notes

- The agent is distributed only as `.deb`/`.rpm`/`.dmg`/`.exe`. We extract the deb with `dpkg-deb`.
- All important paths inside the agent are hard-coded to `/opt/nessus_agent`. We satisfy this with a full recursive copy (via systemd-tmpfiles R+C) into a mutable location + an FHS wrapper (`buildFHSEnv`).
- The core plugins bundle is extracted at build time (equivalent to what the `.deb`'s `postinst` does with `nessuscli install`).
- Registration is performed by a separate oneshot unit so it can be retried independently of the main daemon and can read secrets from `environmentFile` or `keyFile`.

## Supported platforms

The example `.deb`s in this repo are Ubuntu baseline builds for amd64 and aarch64. The derivation is generic — you **must** feed it a .deb whose architecture matches the target system (`x86_64-linux` vs `aarch64-linux`), otherwise the service will fail at start with "cannot execute binary file".

See the warning in the examples and the architecture guard in `pkgs/nessus-agent`.

## License

The Nessus Agent itself is proprietary / commercial software from Tenable. This repository only contains Nix packaging glue.
