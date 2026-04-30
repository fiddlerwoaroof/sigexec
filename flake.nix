{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
  }: let
  in
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };
      zigPkgs = zig-overlay.packages.${system};
      zig = zigPkgs."0.16.0" or zigPkgs.master;
      build_zig = deriv @ {nativeBuildInputs ? [], ...}:
        pkgs.stdenv.mkDerivation ({
            dontConfigure = true;

            preBuild = ''
              export HOME=$TMPDIR
            '';

            installPhase = ''
              runHook preInstall
              zig build --release=safe -Dcpu=baseline --prefix $out install
              runHook postInstall
            '';
          }
          // deriv
          // {
            nativeBuildInputs = [zig] ++ nativeBuildInputs;
          });
      writeZsh = pkgs.writers.makeScriptWriter {interpreter = "${pkgs.zsh}/bin/zsh";};
      socat = pkgs.socat;
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = [zig socat];
      };
      devShell = self.devShells.default;
      packages.default = build_zig {
        pname = "sigexec";
        version = "0.0.3";
        src = ./.;

        meta = with pkgs.lib; {
          homepage = "https://github.com/fiddlerwoaroof/sigexec";
          description = "A simple utility that runs a command with each line sent over a socket.";
          license = licenses.mit;
          platforms = platforms.linux ++ platforms.darwin;
        };
      };
      apps.do-test = {
        type = "app";
        program = toString (writeZsh "test.zsh" ''
          PATH="$PATH:${self.packages.${system}.default}/bin:${socat}/bin"
          ${(builtins.readFile ./test.zsh)}
        '');
      };
    });
}
