{
  description = "Complete LC-3 toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    zon2nix = {
      url = "github:jcollie/zon2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zon2nix, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          zig = pkgs.zig_0_16;
          zigDeps = pkgs.callPackage ./build.zig.zon.nix { };
        in
        {
          elk = pkgs.stdenvNoCC.mkDerivation {
            pname = "elk";
            version = "0.1.10";

            src = pkgs.lib.cleanSource ./.;

            nativeBuildInputs = [ zig.hook ];


            zigBuildFlags = [
              "--system"
              "${zigDeps}"
            ];

            doCheck = true;

            zigCheckFlags = [
              "--system"
              "${zigDeps}"
            ];

            meta = {
              description = "Complete LC-3 toolchain";
              homepage = "https://codeberg.org/dxrcy/elk";
              mainProgram = "elk";
              platforms = systems;
            };
          };

          default = self.packages.${system}.elk;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.elk}/bin/elk";
          meta.description = "Complete LC-3 toolchain";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.zig_0_16
              pkgs.zls
              zon2nix.packages.${system}.zon2nix
            ];
          };
        });
    };
}
