{
  description = "Example system using nessus-nix locally";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nessus-nix.url = "path:../..";
  };

  outputs = { self, nixpkgs, nessus-nix }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";   # or x86_64-linux
        modules = [
          nessus-nix.nixosModules.nessus-agent
          ./configuration.nix
          # your normal hardware-configuration.nix, networking, users, etc.
        ];
      };
    };
}
