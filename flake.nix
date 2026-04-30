{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
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
      zig = pkgs.zig_0_16;
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
      sigexec = build_zig {
        pname = "sigexec";
        version = "0.0.3";
        src = ./.;

        meta = with pkgs.lib; {
          homepage = "https://github.com/fiddlerwoaroof/sigexec";
          description = "A simple utility that runs a command with each line sent over a socket.";
          license = licenses.mit;
          platforms = platforms.linux ++ platforms.darwin;
          mainProgram = "sigexec";
        };
      };
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = [zig socat];
      };
      devShell = self.devShells.${system}.default;
      packages.default = sigexec;
      packages.sigexec = sigexec;
      packages.sigexec-sendfd = sigexec;
      apps.sigexec = {
        type = "app";
        program = "${sigexec}/bin/sigexec";
      };
      apps.sigexec-sendfd = {
        type = "app";
        program = "${sigexec}/bin/sigexec-sendfd";
      };
      apps.do-test = {
        type = "app";
        program = toString (writeZsh "test.zsh" ''
          PATH="$PATH:${sigexec}/bin:${socat}/bin"
          ${(builtins.readFile ./test.zsh)}
        '');
      };
    });
}
