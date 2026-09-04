{
  description = "Command-line tool for examining and modifying TES3 plugins";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      version = "0.40-PRE-RELEASE-2";
      testPerl =
        pkgs:
        pkgs.perl.withPackages (
          perlPackages: with perlPackages; [
            DevelCover
            IPCRun3
            PerlCritic
            Test2Suite
          ]
        );
      testPackages = pkgs: [
        (testPerl pkgs)
        pkgs.git
      ];
      packageFor =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "tes3cmd";
          inherit version;
          src = self;
          dontBuild = true;
          nativeBuildInputs = [ pkgs.perl ];

          installPhase = ''
            runHook preInstall
            install -Dm755 tes3cmd $out/bin/tes3cmd
            patchShebangs $out/bin/tes3cmd
            runHook postInstall
          '';

          meta = {
            description = "Command-line tool for examining and modifying TES3 plugins";
            homepage = "https://github.com/danneu/tes3cmd";
            license = pkgs.lib.licenses.mit;
            mainProgram = "tes3cmd";
            platforms = systems;
          };
        };
    in
    {
      formatter = nixpkgs.lib.genAttrs systems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          tes3cmd = packageFor pkgs;
        in
        {
          inherit tes3cmd;
          default = tes3cmd;
        }
      );

      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = testPackages pkgs;
          };
        }
      );

      checks = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          package =
            pkgs.runCommand "tes3cmd-package-check"
              {
                nativeBuildInputs = [ self.packages.${system}.default ];
              }
              ''
                test "$(tes3cmd --version)" = "tes3cmd ${version}"
                touch "$out"
              '';
          tests =
            pkgs.runCommand "tes3cmd-tests"
              {
                nativeBuildInputs = testPackages pkgs;
                src = self;
              }
              ''
                cp -R "$src" source
                chmod -R u+w source
                cd source
                prove -lr t
                touch "$out"
              '';
        }
      );
    };
}
