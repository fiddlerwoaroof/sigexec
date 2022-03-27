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
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    flake-compat,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      zig091 = zig.packages.${system}."0.9.1";
      socat = pkgs.socat;
    in {
      devShell = pkgs.mkShell {
        buildInputs = [zig091 socat];
      };
      defaultPackage = pkgs.mkShell {
        buildInputs = [zig091 socat];
      };
    });
}
