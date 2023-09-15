{
  inputs = {
    nixpkgs = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
    };
    zig.url = "github:mitchellh/zig-overlay";
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
      zigc = zig.packages.${system}."0.10.1";
      socat = pkgs.socat;
    in {
      devShell = pkgs.mkShell {
        buildInputs = [zigc socat];
      };
      defaultPackage = pkgs.mkShell {
        buildInputs = [zigc socat];
      };
    });
}
