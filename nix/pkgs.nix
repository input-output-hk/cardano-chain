
# our packages overlay
pkgs: _: with pkgs; {
  cardanoLedgerHaskellPackages = import ./haskell.nix {
    inherit config
      lib
      stdenv
      haskell-nix
      buildPackages
      ;
  };
}
