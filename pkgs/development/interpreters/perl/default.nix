{ config, lib, stdenv, fetchurl, fetchpatch, fetchFromGitHub, pkgs, buildPackages
, callPackage
, enableThreading ? true, coreutils, makeWrapper
}:

# Note: this package is used for bootstrapping fetchurl, and thus
# cannot use fetchpatch! All mutable patches (generated by GitHub or
# cgit) that are needed here should be included directly in Nixpkgs as
# files.

with lib;

let

  libc = if stdenv.cc.libc or null != null then stdenv.cc.libc else "/usr";
  libcInc = lib.getDev libc;
  libcLib = lib.getLib libc;
  crossCompiling = stdenv.buildPlatform != stdenv.hostPlatform;

  common = { perl, buildPerl, version, sha256 }: stdenv.mkDerivation (rec {
    inherit version;

    name = "perl-${version}";

    src = fetchurl {
      url = "mirror://cpan/src/5.0/${name}.tar.gz";
      inherit sha256;
    };

    # TODO: Add a "dev" output containing the header files.
    outputs = [ "out" "man" "devdoc" ] ++
      optional crossCompiling "mini";
    setOutputFlags = false;

    disallowedReferences = [ stdenv.cc ];

    patches =
      [
        # Do not look in /usr etc. for dependencies.
        ./no-sys-dirs-5.31.patch
      ]
      ++ optional stdenv.isSunOS ./ld-shared.patch
      ++ optionals stdenv.isDarwin [ ./cpp-precomp.patch ./sw_vers.patch ]
      ++ optionals crossCompiling [
        ./MakeMaker-cross.patch
        # https://github.com/arsv/perl-cross/pull/120
        (fetchpatch {
          url = "https://github.com/arsv/perl-cross/commit/3c318ae6572f8b36cb077c8b49c851e2f5fe181e.patch";
          sha256 = "0cmcy8bams3c68f6xadl52z2w378wcpdjzi3qi4pcyvcfs011l6g";
        })
      ];

    # This is not done for native builds because pwd may need to come from
    # bootstrap tools when building bootstrap perl.
    postPatch = (if crossCompiling then ''
      substituteInPlace dist/PathTools/Cwd.pm \
        --replace "/bin/pwd" '${coreutils}/bin/pwd'
      substituteInPlace cnf/configure_tool.sh --replace "cc -E -P" "cc -E"
    '' else ''
      substituteInPlace dist/PathTools/Cwd.pm \
        --replace "/bin/pwd" "$(type -P pwd)"
    '') +
    # Perl's build system uses the src variable, and its value may end up in
    # the output in some cases (when cross-compiling)
    ''
      unset src
    '';

    # Build a thread-safe Perl with a dynamic libperl.so.  We need the
    # "installstyle" option to ensure that modules are put under
    # $out/lib/perl5 - this is the general default, but because $out
    # contains the string "perl", Configure would select $out/lib.
    # Miniperl needs -lm. perl needs -lrt.
    configureFlags =
      (if crossCompiling
       then [ "-Dlibpth=\"\"" "-Dglibpth=\"\"" "-Ddefault_inc_excludes_dot" ]
       else [ "-de" "-Dcc=cc" ])
      ++ [
        "-Uinstallusrbinperl"
        "-Dinstallstyle=lib/perl5"
      ] ++ lib.optional (!crossCompiling) "-Duseshrplib" ++ [
        "-Dlocincpth=${libcInc}/include"
        "-Dloclibpth=${libcLib}/lib"
      ]
      ++ optionals ((builtins.match ''5\.[0-9]*[13579]\..+'' version) != null) [ "-Dusedevel" "-Uversiononly" ]
      ++ optional stdenv.isSunOS "-Dcc=gcc"
      ++ optional enableThreading "-Dusethreads"
      ++ optional stdenv.hostPlatform.isStatic "--all-static"
      ++ optionals (!crossCompiling) [
        "-Dprefix=${placeholder "out"}"
        "-Dman1dir=${placeholder "out"}/share/man/man1"
        "-Dman3dir=${placeholder "out"}/share/man/man3"
      ];

    configureScript = optionalString (!crossCompiling) "${stdenv.shell} ./Configure";

    dontAddStaticConfigureFlags = true;

    dontAddPrefix = !crossCompiling;

    enableParallelBuilding = !crossCompiling;

    preConfigure = ''
        substituteInPlace ./Configure --replace '`LC_ALL=C; LANGUAGE=C; export LC_ALL; export LANGUAGE; $date 2>&1`' 'Thu Jan  1 00:00:01 UTC 1970'
        substituteInPlace ./Configure --replace '$uname -a' '$uname --kernel-name --machine --operating-system'
      '' + optionalString stdenv.isDarwin ''
        substituteInPlace hints/darwin.sh --replace "env MACOSX_DEPLOYMENT_TARGET=10.3" ""
      '' + optionalString (!enableThreading) ''
        # We need to do this because the bootstrap doesn't have a static libpthread
        sed -i 's,\(libswanted.*\)pthread,\1,g' Configure
      '';

    # Default perl does not support --host= & co.
    configurePlatforms = [];

    setupHook = ./setup-hook.sh;

    passthru = rec {
      interpreter = "${perl}/bin/perl";
      libPrefix = "lib/perl5/site_perl";
      pkgs = callPackage ../../../top-level/perl-packages.nix {
        inherit perl buildPerl;
        overrides = config.perlPackageOverrides or (p: {}); # TODO: (self: super: {}) like in python
      };
      buildEnv = callPackage ./wrapper.nix {
        inherit perl;
        inherit (pkgs) requiredPerlModules;
      };
      withPackages = f: buildEnv.override { extraLibs = f pkgs; };
    };

    doCheck = false; # some tests fail, expensive

    # TODO: it seems like absolute paths to some coreutils is required.
    postInstall =
      ''
        # Remove dependency between "out" and "man" outputs.
        rm "$out"/lib/perl5/*/*/.packlist

        # Remove dependencies on glibc and gcc
        sed "/ *libpth =>/c    libpth => ' '," \
          -i "$out"/lib/perl5/*/*/Config.pm
        # TODO: removing those paths would be cleaner than overwriting with nonsense.
        substituteInPlace "$out"/lib/perl5/*/*/Config_heavy.pl \
          --replace "${libcInc}" /no-such-path \
          --replace "${
              if stdenv.hasCC then stdenv.cc.cc else "/no-such-path"
            }" /no-such-path \
          --replace "${stdenv.cc}" /no-such-path \
          --replace "$man" /no-such-path
      '' + optionalString crossCompiling
      ''
        mkdir -p $mini/lib/perl5/cross_perl/${version}
        for dir in cnf/{stub,cpan}; do
          cp -r $dir/* $mini/lib/perl5/cross_perl/${version}
        done

        mkdir -p $mini/bin
        install -m755 miniperl $mini/bin/perl

        export runtimeArch="$(ls $out/lib/perl5/site_perl/${version})"
        # wrapProgram should use a runtime-native SHELL by default, but
        # it actually uses a buildtime-native one. If we ever fix that,
        # we'll need to fix this to use a buildtime-native one.
        #
        # Adding the arch-specific directory is morally incorrect, as
        # miniperl can't load the native modules there. However, it can
        # (and sometimes needs to) load and run some of the pure perl
        # code there, so we add it anyway. When needed, stubs can be put
        # into $mini/lib/perl5/cross_perl/${version}.
        wrapProgram $mini/bin/perl --prefix PERL5LIB : \
          "$mini/lib/perl5/cross_perl/${version}:$out/lib/perl5/${version}:$out/lib/perl5/${version}/$runtimeArch"
      ''; # */

    meta = {
      homepage = "https://www.perl.org/";
      description = "The standard implementation of the Perl 5 programmming language";
      license = licenses.artistic1;
      maintainers = [ maintainers.eelco ];
      platforms = platforms.all;
      priority = 6; # in `buildEnv' (including the one inside `perl.withPackages') the library files will have priority over files in `perl`
    };
  } // optionalAttrs (stdenv.buildPlatform != stdenv.hostPlatform) rec {
    crossVersion = "393821c7cf53774233aaf130ff2c8ccec701b0a9"; # Sep 22, 2021

    perl-cross-src = fetchFromGitHub {
      name = "perl-cross-${crossVersion}";
      owner = "arsv";
      repo = "perl-cross";
      rev = crossVersion;
      sha256 = "1fn35b1773aibi2z54m0mar7114737mvfyp81wkdwhakrmzr5nv1";
    };

    depsBuildBuild = [ buildPackages.stdenv.cc makeWrapper ];

    postUnpack = ''
      unpackFile ${perl-cross-src}
      chmod -R u+w ${perl-cross-src.name}
      cp -R ${perl-cross-src.name}/* perl-${version}/
    '';

    configurePlatforms = [ "build" "host" "target" ];

    # TODO merge setup hooks
    setupHook = ./setup-hook-cross.sh;
  });
in {
  # Maint version
  perl532 = common {
    perl = pkgs.perl532;
    buildPerl = buildPackages.perl532;
    version = "5.32.1";
    sha256 = "0b7brakq9xs4vavhg391as50nbhzryc7fy5i65r81bnq3j897dh3";
  };

  # Maint version
  perl534 = common {
    perl = pkgs.perl534;
    buildPerl = buildPackages.perl534;
    version = "5.34.0";
    sha256 = "16mywn5afpv1mczv9dlc1w84rbgjgrr0pyr4c0hhb2wnif0zq7jm";
  };

  # the latest Devel version
  perldevel = common {
    perl = pkgs.perldevel;
    buildPerl = buildPackages.perldevel;
    version = "5.35.4";
    sha256 = "1ss2r0qq5li6d2qghfv1iah5nl6nraymd7b7ib1iy1395rwyhl4q";
  };
}
