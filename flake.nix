{
  inputs = {
    nixpkgs = {
      type = "github";
      owner = "nixos";
      repo = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };
      socat = pkgs.socat;
    in rec {
      devShells.default = pkgs.mkShell {
        buildInputs = [pkgs.zig_0_10 socat];
      };
      devShell = devShells.default;
      packages.default = pkgs.stdenv.mkDerivation {
        pname = "sigexec";
        version = "0.0.2";
        src = ./.;

        nativeBuildInputs = [pkgs.zig_0_10.hook];
      };
      apps.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/sigexec";
      };
    });
}
