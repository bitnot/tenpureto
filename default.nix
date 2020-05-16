let
  haskellNix = import (builtins.fetchTarball
    "https://github.com/input-output-hk/haskell.nix/archive/3c54d5781cc2d165d948114f0479d58cf1c74f07.tar.gz")
    { };
  nixpkgsSrc = haskellNix.sources.nixpkgs-default;
  nixpkgsArgs = haskellNix.nixpkgsArgs;

  pkgs = import nixpkgsSrc nixpkgsArgs;
  pkgsMusl = pkgs.pkgsCross.musl64;

  modules = haskellPackages: [
    { reinstallableLibGhc = true; }
    { packages.ghc.patches = [ ./ghc.patch ]; }
    { packages.terminal-size.patches = [ ./terminal-size.patch ]; }
    {
      packages.tenpureto.components.tests.tenpureto-test.build-tools =
        [ haskellPackages.tasty-discover ];
    }
    {
      packages.tenpureto.components.tests.tenpureto-test.testWrapper =
        [ "echo" ];
    }
  ];
in {
  default = with pkgs;
    haskell-nix.stackProject {
      src = haskell-nix.haskellLib.cleanGit {
        src = ./.;
        name = "tenpureto";
      };
      modules = modules haskell-nix.haskellPackages;
    };
  static = with pkgsMusl;
    let
      libffi-static = libffi.overrideAttrs (oldAttrs: {
        dontDisableStatic = true;
        configureFlags = (oldAttrs.configureFlags or [ ])
          ++ [ "--enable-static" "--disable-shared" ];
      });
    in haskell-nix.stackProject {
      src = haskell-nix.haskellLib.cleanGit {
        src = ./.;
        name = "tenpureto";
      };
      modules = (modules haskell-nix.haskellPackages) ++ [
        { doHaddock = false; }
        ({ pkgs, ... }: {
          ghc.package =
            pkgs.buildPackages.haskell-nix.compiler.ghc883.override {
              enableIntegerSimple = true;
              enableShared = true;
              extra-passthru = {
                buildGHC =
                  pkgs.buildPackages.haskell-nix.compiler.ghc883.override {
                    enableIntegerSimple = true;
                    enableShared = true;
                  };
              };
            };
        })
        { packages.ghc.flags.terminfo = false; }
        { packages.bytestring.flags.integer-simple = true; }
        { packages.text.flags.integer-simple = true; }
        { packages.scientific.flags.integer-simple = true; }
        { packages.integer-logarithms.flags.integer-gmp = false; }
        { packages.cryptonite.flags.integer-gmp = false; }
        { packages.hashable.flags.integer-gmp = false; }
        {
          packages.tenpureto.components.exes.tenpureto.configureFlags = [
            "--disable-executable-dynamic"
            "--disable-shared"
            "--ghc-option=-optl=-pthread"
            "--ghc-option=-optl=-static"
            "--ghc-option=-optl=-L${libffi-static}/lib"
          ];
        }
      ];
    };
  inherit pkgs;
}
