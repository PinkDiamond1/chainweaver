{ system ? builtins.currentSystem }:
let self = import ./. {};

    mac   = { inherit (self) mac; };
    linux = { };
    cross = { inherit (self) exe; };
in
  cross
  // (if system == "x86_64-darwin" then mac else {})
  // (if system == "x86_64-linux" then linux else {})
