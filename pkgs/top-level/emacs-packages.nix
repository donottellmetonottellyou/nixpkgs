# package.el-based emacs packages

## FOR USERS
#
# Recommended: simply use `emacsWithPackages` with the packages you want.
#
# Alternative: use `emacs`, install everything to a system or user profile
# and then add this at the start your `init.el`:
/*
  (require 'package)

  ;; optional. makes unpure packages archives unavailable
  (setq package-archives nil)

  ;; optional. use this if you install emacs packages to the system profile
  (add-to-list 'package-directory-list "/run/current-system/sw/share/emacs/site-lisp/elpa")

  ;; optional. use this if you install emacs packages to user profiles (with nix-env)
  (add-to-list 'package-directory-list "~/.nix-profile/share/emacs/site-lisp/elpa")

  (package-initialize)
*/

## FOR CONTRIBUTORS
#
# When adding a new package here please note that
# * please use `elpaBuild` for pre-built package.el packages and
#   `melpaBuild` or `trivialBuild` if the package must actually
#   be built from the source.
# * lib.licenses are `with`ed on top of the file here
# * both trivialBuild and melpaBuild will automatically derive a
#   `meta` with `platforms` and `homepage` set to something you are
#   unlikely to want to override for most packages

{ pkgs', makeScope, makeOverridable, emacs }:

let

  mkElpaPackages = { pkgs, lib }: import ../applications/editors/emacs-modes/elpa-packages.nix {
    inherit (pkgs) stdenv texinfo writeText;
    inherit lib;
  };

  # Contains both melpa stable & unstable
  melpaGeneric = { pkgs, lib }: import ../applications/editors/emacs-modes/melpa-packages.nix {
    inherit lib pkgs;
  };

  mkOrgPackages = { lib }: import ../applications/editors/emacs-modes/org-packages.nix {
    inherit lib;
  };

  mkManualPackages = { pkgs, lib }: import ../applications/editors/emacs-modes/manual-packages.nix {
    inherit lib pkgs;
  };

  emacsWithPackages = { pkgs, lib }: import ../build-support/emacs/wrapper.nix {
    inherit (pkgs) makeWrapper runCommand;
    inherit (pkgs.xorg) lndir;
    inherit lib;
  };

in makeScope pkgs'.newScope (self: makeOverridable ({
  pkgs ? pkgs'
  , lib ? pkgs.lib
  , elpaPackages ? mkElpaPackages { inherit pkgs lib; } self
  , melpaStablePackages ? melpaGeneric { inherit pkgs lib; } "stable" self
  , melpaPackages ? melpaGeneric { inherit pkgs lib; } "unstable" self
  , orgPackages ? mkOrgPackages { inherit lib; } self
  , manualPackages ? mkManualPackages { inherit pkgs lib; } self
}: ({}
  // elpaPackages // { inherit elpaPackages; }
  // melpaStablePackages // { inherit melpaStablePackages; }
  // melpaPackages // { inherit melpaPackages; }
  // orgPackages // { inherit orgPackages; }
  // manualPackages // { inherit manualPackages; }
  // {

    inherit emacs;

    trivialBuild = pkgs.callPackage ../build-support/emacs/trivial.nix {
      inherit (self) emacs;
    };

    melpaBuild = pkgs.callPackage ../build-support/emacs/melpa.nix {
      inherit (self) emacs;
    };

    emacsWithPackages = emacsWithPackages { inherit pkgs lib; } self;
    withPackages = emacsWithPackages { inherit pkgs lib; } self;
  })
) {})
