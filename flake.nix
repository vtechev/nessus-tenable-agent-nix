{
  description = "NixOS module and package for Tenable Nessus Agent (corporate / air-gapped friendly)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; config.allowUnfree = true; })
      );
    in
    {
      # The package (for use in overlays or `nix build`)
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./pkgs/nessus-agent { };
        nessus-agent = pkgs.callPackage ./pkgs/nessus-agent { };
      });

      # Overlay for easy consumption
      overlays.default = final: prev: {
        nessus-agent = final.callPackage ./pkgs/nessus-agent { };
      };

      # The main deliverable: the NixOS module
      nixosModules = {
        default = self.nixosModules.nessus-agent;
        nessus-agent = import ./modules/nessus-agent.nix;
      };

      # Example usage (see examples/ directory)
      templates.default = {
        path = ./examples/basic;
        description = "Basic Nessus Agent configuration example";
      };
    };
}
