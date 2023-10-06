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
  }: let
  in
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
      };
      build_zig = deriv @ {nativeBuildInputs ? [], ...}:
        pkgs.stdenv.mkDerivation ({
            dontConfigure = true;

            preBuild = ''
              export HOME=$TMPDIR
            '';

            installPhase = ''
              runHook preInstall
              zig build -Drelease-safe -Dcpu=baseline --prefix $out install
              runHook postInstall
            '';
          }
          // deriv
          // {
            nativeBuildInputs = [pkgs.zig_0_10] ++ nativeBuildInputs;
          });
      socat = pkgs.socat;
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = [pkgs.zig_0_10 socat];
      };
      devShell = self.devShells.default;
      packages.default = build_zig {
        pname = "sigexec";
        version = "0.0.2";
        src = ./.;

        meta = with pkgs.lib; {
          homepage = "https://github.com/fiddlerwoaroof/sigexec";
          description = "A simple utility that runs a command with each line sent over a socket.";
          license = licenses.mit;
          platforms = platforms.linux ++ platforms.darwin;
        };
      };
    });
}
