{
  inputs = {
    nixpkgs = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
      ref = "12417777b226eff91efee8b03578daa76c8178a3";
    };
    zig.url = "github:arqv/zig-overlay";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    flake-compat,
  }: let
    pkgs = nixpkgs.legacyPackages.aarch64-darwin;
    zig091 = zig.packages.aarch64-darwin."0.9.1";
  in
    {
      devShell.aarch64-darwin = pkgs.mkShell {
        buildInputs = [zig091 nixpkgs.legacyPackages.aarch64-darwin.socat];
      };
    };
}
