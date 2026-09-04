{
  description = "Development and test environment for tes3cmd";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
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
    in
    {
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [ (testPerl pkgs) ];
          };
        }
      );

      checks = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          tests =
            pkgs.runCommand "tes3cmd-tests"
              {
                nativeBuildInputs = [ (testPerl pkgs) ];
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
