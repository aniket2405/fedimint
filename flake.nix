{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-kitman.url = "github:jkitman/nixpkgs/add-esplora-pkg";
    crane.url = "github:ipetkov/crane?ref=master&ref=953b70da2813fb882c39890f2514e7db76fc8843";
    crane.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixpkgs-kitman, flake-utils, flake-compat, fenix, crane, advisory-db }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        pkgs-kitman = import nixpkgs-kitman {
          inherit system;
        };

        pkgs-unstable = import nixpkgs-unstable {
          inherit system;
        };

        lib = pkgs.lib;

        stdenv = pkgs.stdenv;

        clightning-dev = pkgs.clightning.overrideAttrs (oldAttrs: {
          configureFlags = [ "--enable-developer" "--disable-valgrind" ];
        } // pkgs.lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
          NIX_CFLAGS_COMPILE = "-Wno-stringop-truncation";
        });

        # `moreutils/bin/parallel` and `parallel/bin/parallel` conflict, so just use
        # the binary we need from `moreutils`
        ts = pkgs.writeShellScriptBin "ts" "exec ${pkgs.moreutils}/bin/ts \"$@\"";

        isArch64Darwin = stdenv.isAarch64 || stdenv.isDarwin;

        # Env vars we need for wasm32 cross compilation
        wasm32CrossEnvVars = ''
          export CC_wasm32_unknown_unknown="${pkgs.llvmPackages_14.clang-unwrapped}/bin/clang-14"
          export CFLAGS_wasm32_unknown_unknown="-I ${pkgs.llvmPackages_14.libclang.lib}/lib/clang/14.0.6/include/"
        '' + (if isArch64Darwin then
          ''
            export AR_wasm32_unknown_unknown="${pkgs.llvmPackages_14.llvm}/bin/llvm-ar"
          '' else
          ''
          '');

        # The following hack makes fedimint compile on android:
        #
        # From https://github.com/rust-mobile/cargo-apk/commit/4956b87f56f2854e2b3452b83b65b00224757d41
        # > Rust still searches for libgcc even though [85806] replaces internal use
        # > with libunwind, especially now that the Android NDK (since r23-beta3)
        # > doesn't ship with any of gcc anymore.  The apparent solution is to build
        # > your application with nightly and compile std locally (`-Zbuild-std`),
        # > but that is not desired for the majority of users.  [7339] suggests to
        # > provide a local `libgcc.a` as linker script, which simply redirects
        # > linking to `libunwind` instead - and that has proven to work fine so
        # > far.
        # >
        # > Intead of shipping this file with the crate or writing it to an existing
        # > link-search directory on the system, we write it to a new directory that
        # > can be easily passed or removed to `rustc`, say in the event that a user
        # > switches to an older NDK and builds without cleaning.  For this we need
        # > to switch from `cargo build` to `cargo rustc`, but the existing
        # > arguments and desired workflow remain identical.
        # >
        # > [85806]: rust-lang/rust#85806
        # > [7339]: termux/termux-packages#7339 (comment)

        fake-libgcc-gen = arch: pkgs.stdenv.mkDerivation {
          pname = "fake-libgcc";
          version = "0.1.0";

          dontUnpack = true;

          installPhase = ''
            mkdir -p $out/lib
            ln -s ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk/24.0.8215888/toolchains/llvm/prebuilt/linux-x86_64/lib64/clang/14.0.1/lib/linux/${arch}/libunwind.a $out/lib/libgcc.a
          '';
        };

        fake-libgcc-x86_64 = fake-libgcc-gen "x86_64";
        fake-libgcc-aarch64 = fake-libgcc-gen "aarch64";
        fake-libgcc-arm = fake-libgcc-gen "arm";
        fake-libgcc-i386 = fake-libgcc-gen "i386";

        # All the environment variables we need for all android cross compilation targets
        androidCrossEnvVars = ''
          # Note: rockdb seems to require uint128_t, which is not supported on 32-bit Android: https://stackoverflow.com/a/25819240/134409 (?)
          export LLVM_CONFIG_PATH="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-config"

          export CC_armv7_linux_androideabi="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
          export CXX_armv7_linux_androideabi="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
          export LD_armv7_linux_androideabi="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/ld"
          export LDFLAGS_armv7_linux_androideabi="-L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/arm-linux-androideabi/30/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/lib/gcc/arm-linux-androideabi/4.9.x/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/arm-linux-androideabi/ -L ${fake-libgcc-arm}/lib"

          export CC_aarch64_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
          export CXX_aarch64_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
          export LD_aarch64_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/ld"
          export LDFLAGS_aarch64_linux_android="-L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/30/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/lib/gcc/aarch64-linux-android/4.9.x/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/ -L ${fake-libgcc-aarch64}/lib"

          export CC_x86_64_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
          export CXX_x86_64_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
          export LD_x86_64_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/ld"
          export LDFLAGS_x86_64_linux_android="-L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/30/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/lib/gcc/x86_64-linux-android/4.9.x/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/ -L ${fake-libgcc-x86_64}/lib"

          export CC_i686_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
          export CXX_i686_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"
          export LD_i686_linux_android="${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/bin/ld"
          export LDFLAGS_i686_linux_android="-L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/i686-linux-android/30/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/lib/gcc/i686-linux-android/4.9.x/ -L ${androidComposition.ndk-bundle}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/i686-linux-android/ -L ${fake-libgcc-i386}/lib"
        '';

        # NDK we use for android cross compilation
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          includeNDK = true;
        };

        # Definitions of all the cross-compilation targets we support.
        # Later mapped over to conveniently loop over all posibilities.
        crossTargets =
          builtins.mapAttrs
            (attr: target: { name = attr; extraEnvs = ""; } // target)
            {
              "wasm32-unknown-unknown" = {
                extraEnvs = wasm32CrossEnvVars;
              };
              "armv7-linux-androideabi" = {
                extraEnvs = androidCrossEnvVars;
              };
              "aarch64-linux-android" = {
                extraEnvs = androidCrossEnvVars;
              };
              "i686-linux-android" = {
                extraEnvs = androidCrossEnvVars;
              };
              "x86_64-linux-android" = {
                extraEnvs = androidCrossEnvVars;
              };
            };

        fenixChannel = fenix.packages.${system}.stable;
        fenixChannelNightly = fenix.packages.${system}.latest;

        fenixToolchain = (fenixChannel.withComponents [
          "rustc"
          "cargo"
          "clippy"
          "rust-analysis"
          "rust-src"
          "llvm-tools-preview"
        ]);

        fenixToolchainRustfmt = (fenixChannelNightly.withComponents [
          "rustfmt"
        ]);

        fenixToolchainCargoFmt = (fenixChannelNightly.withComponents [
          "cargo"
          "rustfmt"
        ]);

        fenixToolchainCrossAll = with fenix.packages.${system}; combine ([
          stable.cargo
          stable.rustc
        ] ++ (lib.attrsets.mapAttrsToList
          (attr: target: targets.${target.name}.stable.rust-std)
          crossTargets));

        fenixToolchainCrossWasm = with fenix.packages.${system}; combine ([
          stable.cargo
          stable.rustc
          targets.wasm32-unknown-unknown.stable.rust-std
        ]);

        fenixToolchainCross = builtins.mapAttrs
          (attr: target: with fenix.packages.${system}; combine [
            stable.cargo
            stable.rustc
            targets.${target.name}.stable.rust-std
          ])
          crossTargets
        ;

        craneLibNative = crane.lib.${system}.overrideToolchain fenixToolchain;

        craneLibCross = builtins.mapAttrs
          (name: target: crane.lib.${system}.overrideToolchain fenixToolchainCross.${name})
          crossTargets
        ;


        # filter source code at path `src` to include only the list of `modules`
        filterModules = modules: src:
          let
            basePath = toString src + "/";
            relPathAllCargoTomlFiles = builtins.filter
              (pathStr: lib.strings.hasSuffix "/Cargo.toml" pathStr)
              (builtins.map (path: lib.removePrefix basePath (toString path)) (lib.filesystem.listFilesRecursive src));
          in
          lib.cleanSourceWith {
            filter = (path: type:
              let
                relPath = lib.removePrefix basePath (toString path);
                includePath =
                  # traverse only into directories that somewhere in there contain `Cargo.toml` file, or were explicitily whitelisted
                  (type == "directory" && lib.any (cargoTomlPath: lib.strings.hasPrefix relPath cargoTomlPath) relPathAllCargoTomlFiles) ||
                  lib.any
                    (re: builtins.match re relPath != null)
                    ([ "Cargo.lock" "Cargo.toml" ".cargo" ".cargo/.*" ".*/Cargo.toml" ".*/proto/.*" ] ++ builtins.concatLists (map (name: [ name "${name}/.*" ]) modules));
              in
              # uncomment to debug:
                # builtins.trace "${relPath}: ${lib.boolToString includePath}"
              includePath
            );
            inherit src;
          };

        # Filter only files needed to build project dependencies
        #
        # To get good build times it's vitally important to not have to
        # rebuild derivation needlessly. The way Nix caches things
        # is very simple: if any input file changed, derivation needs to
        # be rebuild.
        #
        # For this reason this filter function strips the `src` from
        # any files that are not relevant to the build.
        #
        # Lile `filterWorkspaceFiles` but doesn't even need *.rs files
        # (because they are not used for building dependencies)
        filterWorkspaceDepsBuildFiles = src: filterSrcWithRegexes [ "Cargo.lock" "Cargo.toml" ".cargo" ".cargo/.*" ".*/Cargo.toml" ".*/proto/.*" ] src;

        # Filter only files relevant to building the workspace
        filterWorkspaceFiles = src: filterSrcWithRegexes [ "Cargo.lock" "Cargo.toml" ".cargo" ".cargo/.*" ".*/Cargo.toml" ".*\.rs" ".*\.html" ".*/proto/.*" ] src;

        # Like `filterWorkspaceFiles` but with `./scripts/` and `./misc/test/` included
        filterWorkspaceTestFiles = src: filterSrcWithRegexes [ "Cargo.lock" "Cargo.toml" ".cargo" ".cargo/.*" ".*/Cargo.toml" ".*\.rs" ".*\.html" ".*/proto/.*" "scripts/.*" "misc/test/.*" ] src;

        filterSrcWithRegexes = regexes: src:
          let
            basePath = toString src + "/";
          in
          lib.cleanSourceWith {
            filter = (path: type:
              let
                relPath = lib.removePrefix basePath (toString path);
                includePath =
                  (type == "directory") ||
                  lib.any
                    (re: builtins.match re relPath != null)
                    regexes;
              in
              # uncomment to debug:
                # builtins.trace "${relPath}: ${lib.boolToString includePath}"
              includePath
            );
            inherit src;
          };

        craneBuild = craneLib: rec {

          cargo-llvm-cov = craneLib.buildPackage rec {
            pname = "cargo-llvm-cov";
            version = "0.4.14";
            buildInputs = commonArgs.buildInputs;

            src = pkgs.fetchCrate {
              inherit pname version;
              sha256 = "sha256-DY5eBSx/PSmKaG7I6scDEbyZQ5hknA/pfl0KjTNqZlo=";
            };
            doCheck = false;
          };

          commonArgsBase = {
            pname = "fedimint-workspace";

            buildInputs = with pkgs; [
              clang
              gcc
              openssl
              pkg-config
              perl
              pkgs.llvmPackages.bintools
              rocksdb
              protobuf
            ] ++ lib.optionals stdenv.isDarwin [
              libiconv
              darwin.apple_sdk.frameworks.Security
              zld
            ] ++ lib.optionals (!(stdenv.isAarch64 || stdenv.isDarwin)) [
              # mold is currently broken on ARM and MacOS
              mold
            ];

            nativeBuildInputs = with pkgs; [
              pkg-config
              ts

              # tests
              (hiPrio pkgs.bashInteractive)
              bc
              bitcoind
              clightning-dev
              electrs
              jq
              lnd
              netcat
              perl
              pkgs-kitman.esplora
              procps
              which
            ];


            # https://github.com/ipetkov/crane/issues/76#issuecomment-1296025495
            installCargoArtifactsMode = "use-zstd";

            LIBCLANG_PATH = "${pkgs.libclang.lib}/lib/";
            ROCKSDB_LIB_DIR = "${pkgs.rocksdb}/lib/";
            PROTOC = "${pkgs.protobuf}/bin/protoc";
            PROTOC_INCLUDE = "${pkgs.protobuf}/include";
            CI = "true";
            HOME = "/tmp";
          };

          commonArgs = commonArgsBase // {
            src = filterWorkspaceFiles ./.;
          };

          commonArgsDepsOnly = commonArgsBase // {
            cargoVendorDir = craneLib.vendorCargoDeps {
              src = filterWorkspaceFiles ./.;
            };
            # copy over the linker/ar wrapper scripts which by default would get
            # stripped by crane
            dummySrc = craneLib.mkDummySrc {
              src = filterWorkspaceDepsBuildFiles ./.;
              extraDummyScript = ''
                cp -ar ${./.cargo} --no-target-directory $out/.cargo
              '';
            };
          };

          commonCliTestArgs = commonArgs // {
            pname = "fedimint-test";
            version = "0.0.1";
            src = filterWorkspaceTestFiles ./.;
            # there's no point saving the `./target/` dir
            doInstallCargoArtifacts = false;
            # the build command will be the test
            doCheck = true;
          };

          workspaceDeps = craneLib.buildDepsOnly (commonArgsDepsOnly // {
            version = "0.0.1";
            buildPhaseCargoCommand = "cargo doc --profile $CARGO_PROFILE ; cargo check --profile $CARGO_PROFILE --all-targets ; cargo build --profile $CARGO_PROFILE --all-targets";
            doCheck = false;
          });

          workspaceBuild = craneLib.cargoBuild (commonArgs // {
            version = "0.0.1";
            cargoArtifacts = workspaceDeps;
            doCheck = false;
          });

          workspaceTest = craneLib.cargoTest (commonArgs // {
            version = "0.0.1";
            cargoArtifacts = workspaceDeps;
          });

          workspaceTestDoc = craneLib.cargoTest (commonArgs // {
            version = "0.0.1";
            cargoTestExtraArgs = "--doc";
            cargoArtifacts = workspaceDeps;
          });

          workspaceClippy = craneLib.cargoClippy (commonArgs // {
            version = "0.0.1";
            cargoArtifacts = workspaceDeps;

            cargoClippyExtraArgs = "--all-targets --no-deps -- --deny warnings";
            doInstallCargoArtifacts = false;
          });

          workspaceDoc = craneLib.cargoDoc (commonArgs // {
            version = "0.0.1";
            cargoArtifacts = workspaceDeps;
            preConfigure = ''
              export RUSTDOCFLAGS='-D rustdoc::broken_intra_doc_links'
            '';
            cargoDocExtraArgs = "--no-deps --document-private-items";
            doInstallCargoArtifacts = false;
            postInstall = ''
              cp -a target/doc $out
            '';
            doCheck = false;
          });

          workspaceAudit = craneLib.cargoAudit (commonArgs // {
            version = "0.0.1";
            pname = commonArgs.pname + "-audit";
            inherit advisory-db;
          });

          # Build only deps, but with llvm-cov so `workspaceCov` can reuse them cached
          workspaceDepsCov = craneLib.buildDepsOnly (commonArgsDepsOnly // {
            pnameSuffix = "-lcov-deps";
            version = "0.0.1";
            buildPhaseCargoCommand = "cargo llvm-cov --workspace --profile $CARGO_PROFILE --no-report";
            cargoBuildCommand = "dontuse";
            cargoCheckCommand = "dontuse";
            nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ cargo-llvm-cov ];
            doCheck = false;
          });

          workspaceCov = craneLib.buildPackage (commonArgs // {
            pnameSuffix = "-lcov";
            version = "0.0.1";
            cargoArtifacts = workspaceDepsCov;
            buildPhaseCargoCommand = "mkdir -p $out ; cargo llvm-cov --workspace --profile $CARGO_PROFILE --lcov --all-targets --tests --output-path $out/lcov.info";
            installPhaseCommand = "true";
            nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ cargo-llvm-cov ];
            doCheck = false;
          });

          cliTestReconnect = craneLib.mkCargoDerivation (commonCliTestArgs // {
            pname = "${commonCliTestArgs.pname}-reconnect";
            version = "0.0.1";
            cargoArtifacts = workspaceBuild;
            buildPhaseCargoCommand = "patchShebangs ./scripts ; ./scripts/reconnect-test.sh";
          });

          cliTestLatency = craneLib.mkCargoDerivation (commonCliTestArgs // {
            pname = "${commonCliTestArgs.pname}-latency";
            version = "0.0.1";
            cargoArtifacts = workspaceBuild;
            buildPhaseCargoCommand = "patchShebangs ./scripts ; ./scripts/latency-test.sh";
          });

          cliTestCli = craneLib.mkCargoDerivation (commonCliTestArgs // {
            pname = "${commonCliTestArgs.pname}-cli";
            version = "0.0.1";
            cargoArtifacts = workspaceBuild;
            buildPhaseCargoCommand = "patchShebangs ./scripts ; ./scripts/cli-test.sh";
          });

          cliRustTests = craneLib.mkCargoDerivation (commonCliTestArgs // {
            pname = "${commonCliTestArgs.pname}-rust-tests";
            version = "0.0.1";
            cargoArtifacts = workspaceBuild;
            buildPhaseCargoCommand = "patchShebangs ./scripts ; ./scripts/rust-tests.sh";
          });

          cliTestAlwaysFail = craneLib.mkCargoDerivation (commonCliTestArgs // {
            pname = "${commonCliTestArgs.pname}-always-fail";
            version = "0.0.1";
            cargoArtifacts = workspaceBuild;
            buildPhaseCargoCommand = "patchShebangs ./scripts ; ./scripts/always-fail-test.sh";
          });


          # Compile a group of packages together
          #
          # This unifies their cargo features and avoids building common dependencies mulitple
          # times, but will produce a derivation with all listed packages.
          pkgsBuild = { name, pkgs, dirs, defaultBin ? null }:
            let
              # "--package x --package y" args passed to cargo
              pkgsArgs = lib.strings.concatStringsSep " " (lib.mapAttrsToList (name: value: "--package ${name}") pkgs);
              deps = craneLib.buildDepsOnly (commonArgsDepsOnly // {
                pname = name;
                version = "0.0.1";
                buildPhaseCargoCommand = "cargo build --profile $CARGO_PROFILE ${pkgsArgs}";
                doCheck = false;
              });

            in

            craneLib.buildPackage (commonArgs // {
              meta = { mainProgram = defaultBin; };
              pname = "${name}";
              version = "0.0.1";
              cargoArtifacts = deps;

              src = filterModules dirs ./.;
              cargoExtraArgs = pkgsArgs;

              # if needed we will check the whole workspace at once with `workspaceBuild`
              doCheck = false;
            });


          # Cross-compile a group of packages together.
          #
          # This unifies their cargo features and avoids building common dependencies mulitple
          # times, but will produce a derivation with all listed packages.
          pkgsCrossBuild = { name, pkgs, dirs, target }:
            if target == null then
              pkgsBuild { inherit name pkgs dirs; }
            else
              let
                # "--package x --package y" args passed to cargo
                pkgsArgs = lib.strings.concatStringsSep " " (lib.mapAttrsToList (name: value: "--package ${name}") pkgs);
                craneLib = craneLibCross.${target.name};
                deps = craneLib.buildDepsOnly (commonArgsDepsOnly // {
                  pname = "${name}-${target.name}";
                  version = "0.0.1";
                  # workaround: on wasm, we can't compile all deps, so narrow dependency build
                  # to ones used by the client package only
                  buildPhaseCargoCommand = "cargo build --profile $CARGO_PROFILE --target ${target.name} ${pkgsArgs}";
                  doCheck = false;

                  preBuild = ''
                    patchShebangs .cargo/
                  '' + target.extraEnvs;
                });

              in
              craneLib.buildPackage (commonArgs // {
                pname = "${name}-${target.name}";
                version = "0.0.1";
                cargoArtifacts = deps;

                src = filterModules dirs ./.;
                cargoExtraArgs = "--target ${target.name} ${pkgsArgs}";

                # if needed we will check the whole workspace at once with `workspaceBuild`
                doCheck = false;
                preBuild = ''
                  patchShebangs .cargo/
                '' + target.extraEnvs;
              });

          fedimint-pkgs = pkgsBuild {
            name = "fedimint-pkgs";

            pkgs = {
              fedimintd = { };
              fedimint-cli = { };
              fedimint-tests = { };
            };

            defaultBin = "fedimintd";
            dirs = [
              "client/client-lib"
              "client/cli"
              "crypto/aead"
              "crypto/derive-secret"
              "crypto/hkdf"
              "crypto/tbs"
              "fedimintd"
              "fedimint-bitcoind"
              "fedimint-build"
              "fedimint-client"
              "fedimint-core"
              "fedimint-derive"
              "fedimint-dbtool"
              "fedimint-rocksdb"
              "fedimint-server"
              "fedimint-logging"
              "gateway/ln-gateway"
              "modules"
            ];
          };

          ln-gateway-pkgs = pkgsBuild {
            name = "ln-gateway-pkgs";

            pkgs = {
              ln-gateway = { };
              gateway-cli = { };
              gateway-tests = { };
            };

            dirs = [
              "crypto/aead"
              "crypto/derive-secret"
              "crypto/tbs"
              "crypto/hkdf"
              "client/client-lib"
              "modules/fedimint-ln"
              "fedimint-bitcoind"
              "fedimint-client"
              "fedimint-core"
              "fedimint-derive"
              "fedimint-dbtool"
              "fedimint-rocksdb"
              "fedimint-build"
              "fedimint-logging"
              "gateway/ln-gateway"
              "gateway/cli"
              "modules"
            ];
          };

          client-pkgs = { target ? null }: pkgsCrossBuild {
            name = "client-pkgs";
            inherit target;

            pkgs = {
              mint-client = { };
            } // lib.optionalAttrs (target == null || target.name != "wasm32-unknown-unknown") {
              # broken on wasm32
              fedimint-sqlite = { };
            };
            dirs = [
              "client/client-lib"
              "crypto/aead"
              "crypto/derive-secret"
              "crypto/tbs"
              "crypto/hkdf"
              "fedimint-bitcoind"
              "fedimint-client"
              "fedimint-core"
              "fedimint-derive"
              "fedimint-dbtool"
              "fedimint-rocksdb"
              "fedimint-sqlite"
              "fedimint-logging"
              "modules"
            ];
          };
        };

        craneBuildNative = craneBuild craneLibNative;
        craneBuildCross = target: craneBuild craneLibCross.${target};

        # Replace placeholder git hash in a binary
        #
        # To avoid impurity, we use a git hash placeholder when building binaries
        # and then replace them with the real git hash in the binaries themselves.
        replaceGitHash = { package, name }:
          let
            # the git hash placeholder we use in `build.rs` scripts when
            # building in Nix (to preserve purity)
            hash-placeholder = "01234569afbe457afa1d2683a099c7af48a523c1";
            # the hash we will set if the tree is dirty;
            dirty-hash = "0000000000000000000000000000000000000000";
            # git hash to set (passed by Nix if the tree is clean, or `dirty-hash` when dirty)
            git-hash = if (self ? rev) then self.rev else dirty-hash;
          in
          stdenv.mkDerivation {
            inherit system;
            inherit name;

            dontUnpack = true;

            installPhase = ''
              cp -a ${package} $out
              for path in `find $out -type f -executable`; do
                # need to use a temporary file not to overwrite source as we are reading it
                bbe -e 's/${hash-placeholder}/${git-hash}/' $path -o ./tmp || exit 1
                chmod +w $path
                # use cat to keep all the original permissions etc as they were
                cat ./tmp > "$path"
                chmod -w $path
              done
            '';

            buildInputs = [ pkgs.bbe ];
          };

        # outputs that do something over the whole workspace
        outputsWorkspace = {
          workspaceDeps = craneBuildNative.workspaceDeps;
          workspaceBuild = craneBuildNative.workspaceBuild;
          workspaceClippy = craneBuildNative.workspaceClippy;
          workspaceTest = craneBuildNative.workspaceTest;
          workspaceTestDoc = craneBuildNative.workspaceTestDoc;
          workspaceDoc = craneBuildNative.workspaceDoc;
          workspaceCov = craneBuildNative.workspaceCov;
          workspaceAudit = craneBuildNative.workspaceAudit;
        };

        # outputs that build a particular package
        outputsPackages = {
          default = craneBuildNative.fedimint-pkgs;

          fedimint-pkgs = craneBuildNative.fedimint-pkgs;
          ln-gateway-pkgs = craneBuildNative.ln-gateway-pkgs;
          client-pkgs = craneBuildNative.client-pkgs { };
        };

        packages = outputsWorkspace //
          # replace git hash in the final binaries
          (builtins.mapAttrs (name: package: replaceGitHash { inherit name package; }) outputsPackages)
        ;

        devShells =

          let
            shellCommon = craneLib:
              let
                build = craneBuild craneBuild;
                commonArgs = build.commonArgs;
              in
              {
                buildInputs = commonArgs.buildInputs;
                nativeBuildInputs = with pkgs; commonArgs.nativeBuildInputs ++ [
                  fenix.packages.${system}.rust-analyzer
                  fenixToolchainRustfmt
                  cargo-llvm-cov
                  cargo-udeps
                  pkgs.parallel
                  pkgs.just
                  cargo-spellcheck

                  (pkgs.writeShellScriptBin "git-recommit" "exec git commit --edit -F <(cat \"$(git rev-parse --git-path COMMIT_EDITMSG)\" | grep -v -E '^#.*') \"$@\"")

                  # This is required to prevent a mangled bash shell in nix develop
                  # see: https://discourse.nixos.org/t/interactive-bash-with-nix-develop-flake/15486
                  (hiPrio pkgs.bashInteractive)
                  tmux
                  tmuxinator
                  docker-compose
                  pkgs.tokio-console
                  ts

                  # Nix
                  pkgs.nixpkgs-fmt
                  pkgs.shellcheck
                  pkgs.rnix-lsp
                  pkgs-unstable.convco
                  pkgs.nodePackages.bash-language-server
                ] ++ lib.optionals (!stdenv.isAarch64 || !stdenv.isDarwin) [
                  pkgs.semgrep
                ];
                RUST_SRC_PATH = "${fenixChannel.rust-src}/lib/rustlib/src/rust/library";
                LIBCLANG_PATH = "${pkgs.libclang.lib}/lib/";
                ROCKSDB_LIB_DIR = "${pkgs.rocksdb}/lib/";

                shellHook = ''
                  # auto-install git hooks
                  dot_git="$(git rev-parse --git-common-dir)"
                  if [[ ! -d "$dot_git/hooks" ]]; then mkdir "$dot_git/hooks"; fi
                  for hook in misc/git-hooks/* ; do ln -sf "$(pwd)/$hook" "$dot_git/hooks/" ; done
                  ${pkgs.git}/bin/git config commit.template misc/git-hooks/commit-template.txt

                  # workaround https://github.com/rust-lang/cargo/issues/11020
                  cargo_cmd_bins=( $(ls $HOME/.cargo/bin/cargo-{clippy,udeps,llvm-cov} 2>/dev/null) )
                  if (( ''${#cargo_cmd_bins[@]} != 0 )); then
                    >&2 echo "⚠️  Detected binaries that might conflict with reproducible environment: ''${cargo_cmd_bins[@]}" 1>&2
                    >&2 echo "   Considering deleting them. See https://github.com/rust-lang/cargo/issues/11020 for details" 1>&2
                  fi

                  # Note: the string escaping necessary here (Nix's multi-line string and shell's) is mind-twisting.
                  if [ -n "$TMUX" ]; then
                    # if [ "$(tmux show-options -A default-command)" == 'default-command* \'\''' ]; then
                    if [ "$(tmux show-options -A default-command)" == 'bla' ]; then
                      echo
                      >&2 echo "⚠️  tmux's 'default-command' not set"
                      >&2 echo " ️  Please add 'set -g default-command \"\''${SHELL}\"' to your '$HOME/.tmux.conf' for tmuxinator test setup to work correctly"
                    fi
                  fi

                  # if runing in direnv
                  if [ -n "''${DIRENV_IN_ENVRC:-}" ]; then
                    # and not set DIRENV_LOG_FORMAT
                    if [ -n "''${DIRENV_LOG_FORMAT:-}" ]; then
                      >&2 echo "💡 Set 'DIRENV_LOG_FORMAT=\"\"' in your shell environment variables for a cleaner output of direnv"
                    fi
                  fi

                  >&2 echo "💡 Run 'just' for a list of available 'just ...' helper recipies"

                  if [ "$(ulimit -Sn)" -lt "1024" ]; then
                      >&2 echo "⚠️  ulimit too small. Run 'ulimit -Sn 1024' to avoid problems running tests"
                  fi
                '';
              };
            shellCommonNative = shellCommon craneLibNative;
            shellCommonCross = shellCommon craneLibCross;

          in
          {
            # The default shell - meant to developers working on the project,
            # so notably not building any project binaries, but including all
            # the settings and tools neccessary to build and work with the codebase.
            default = pkgs.mkShell (shellCommonNative
              // {
              nativeBuildInputs = shellCommonNative.nativeBuildInputs ++ [ fenixToolchain ];
            });


            # Shell with extra stuff to support cross-compilation with `cargo build --target <target>`
            #
            # This will pull extra stuff so to save time and download time to most common developers,
            # was moved into another shell.
            cross = pkgs.mkShell (shellCommonCross // {
              nativeBuildInputs = shellCommonCross.nativeBuildInputs ++ [ fenixToolchainCrossAll ];

              shellHook = shellCommonCross.shellHook +

                # Android NDK not available for Arm MacOS
                (if isArch64Darwin then "" else androidCrossEnvVars)
                + wasm32CrossEnvVars;
            });

            # Like `cross` but only with wasm
            crossWasm = pkgs.mkShell (shellCommonCross // {
              nativeBuildInputs = shellCommonCross.nativeBuildInputs ++ [ fenixToolchainCrossWasm ];

              shellHook = shellCommonCross.shellHook + wasm32CrossEnvVars;
            });

            # this shell is used only in CI, so it should contain minimum amount
            # of stuff to avoid building and caching things we don't need
            lint = pkgs.mkShell {
              nativeBuildInputs = with pkgs; [
                fenixToolchainCargoFmt
                nixpkgs-fmt
                shellcheck
                git
                parallel
                semgrep
                ts
                nix
              ];
            };

            replit = pkgs.mkShell {
              nativeBuildInputs = with pkgs; [
                pkg-config
                openssl
              ];
              LIBCLANG_PATH = "${pkgs.libclang.lib}/lib/";
            };

            bootstrap = pkgs.mkShell {
              nativeBuildInputs = with pkgs; [
                cachix
              ];
            };
          };
      in
      {
        inherit packages devShells;

        lib = {
          inherit replaceGitHash devShells;
          commonArgsBase = craneBuildNative.commonArgsBase;
        };

        # Technically nested sets are not allowed in `packages`, so we can
        # dump the nested things here. They'll work the same way for most
        # purposes (like `nix build`).
        legacyPackages = rec {
          # Debug Builds
          #
          # This works by using `overrideAttrs` on output derivations to set `CARGO_PROFILE`, and importantly
          # recursing into `cargoArtifacts` to do the same. This way a debug build depends on debug build of all dependencies.
          # See https://github.com/ipetkov/crane/discussions/140#discussioncomment-3857137 for more info.
          debug =
            let
              overrideCargoProfileRecursively = deriv: profile: deriv.overrideAttrs (oldAttrs: {
                CARGO_PROFILE = profile;
                cargoArtifacts = if oldAttrs ? "cargoArtifacts" && oldAttrs.cargoArtifacts != null then overrideCargoProfileRecursively oldAttrs.cargoArtifacts profile else null;
              });
            in
            (builtins.mapAttrs (name: deriv: overrideCargoProfileRecursively deriv "dev") outputsWorkspace) //
            (builtins.mapAttrs
              (name: deriv: replaceGitHash {
                inherit name; package = overrideCargoProfileRecursively deriv "dev";
              })
              outputsPackages) // { cli-test = (builtins.mapAttrs (name: deriv: overrideCargoProfileRecursively deriv "dev") cli-test); }
          ;

          cli-test = {
            reconnect = craneBuildNative.cliTestReconnect;
            latency = craneBuildNative.cliTestLatency;
            cli = craneBuildNative.cliTestCli;
            rust-tests = craneBuildNative.cliRustTests;
            always-fail = craneBuildNative.cliTestAlwaysFail;
          };

          cross = builtins.mapAttrs
            (name: target: {
              client-pkgs = (craneBuildCross name).client-pkgs { inherit target; };
            })
            crossTargets;


          container =
            let
              entrypointScript =
                pkgs.writeShellScriptBin "entrypoint" ''
                  exec bash "${./misc/fedimintd-container-entrypoint.sh}" "$@"
                '';
            in
            {
              fedimintd = pkgs.dockerTools.buildLayeredImage {
                name = "fedimintd";
                contents = [
                  packages.fedimint-pkgs
                  pkgs.bash
                  pkgs.coreutils
                ];
                config = {
                  Cmd = [ ]; # entrypoint will handle empty vs non-empty cmd
                  Env = [
                    "FM_DATA_DIR=/data"
                  ];
                  Entrypoint = [
                    "${entrypointScript}/bin/entrypoint"
                  ];
                  WorkDir = "/data";
                  Volumes = {
                    "/data" = { };
                  };
                  ExposedPorts = {
                    "${builtins.toString 8173}/tcp" = { };
                    "${builtins.toString 8174}/tcp" = { };
                    "${builtins.toString 8176}/tcp" = { };
                  };
                };
              };

              ln-gateway =
                let
                  entrypointScript =
                    pkgs.writeShellScriptBin "entrypoint" ''
                      exec bash "${./misc/ln-gateway-container-entrypoint.sh}" "$@"
                    '';
                in
                pkgs.dockerTools.buildLayeredImage {
                  name = "ln-gateway";
                  contents = [ craneBuildNative.ln-gateway-pkgs pkgs.bash pkgs.coreutils ];
                  config = {
                    Cmd = [ ]; # entrypoint will handle empty vs non-empty cmd
                    Entrypoint = [
                      "${entrypointScript}/bin/entrypoint"
                    ];
                    ExposedPorts = {
                      "${builtins.toString 8175}/tcp" = { };
                    };
                  };
                  enableFakechroot = true;
                };

              ln-gateway-clightning =
                let
                  # Will be placed in `/config-example.cfg` by `fakeRootCommands` below
                  config-example = pkgs.writeText "config-example.conf" ''
                    network=signet
                    # bitcoin-datadir=/var/lib/bitcoind

                    always-use-proxy=false
                    bind-addr=0.0.0.0:9735
                    bitcoin-rpcconnect=127.0.0.1
                    bitcoin-rpcport=8332
                    bitcoin-rpcuser=public
                    rpc-file-mode=0660
                    log-timestamps=false

                    plugin=${craneBuildNative.ln-gateway-pkgs}/bin/ln_gateway
                    fedimint-cfg=/var/fedimint/fedimint-gw

                    announce-addr=104.244.73.68:9735
                    alias=fm-signet.sirion.io
                    large-channels
                    experimental-offers
                    fee-base=0
                    fee-per-satoshi=100
                  '';
                in
                pkgs.dockerTools.buildLayeredImage {
                  name = "ln-gateway-clightning";
                  contents = [ craneBuildNative.ln-gateway-pkgs clightning-dev pkgs.bash pkgs.coreutils ];
                  config = {
                    Cmd = [
                      "${craneBuildNative.ln-gateway-pkgs}/bin/ln_gateway"
                    ];
                    ExposedPorts = {
                      "${builtins.toString 9735}/tcp" = { };
                    };
                  };
                  enableFakechroot = true;
                  fakeRootCommands = ''
                    ln -s ${config-example} /config-example.cfg
                  '';
                };

              fedimint-cli = pkgs.dockerTools.buildLayeredImage {
                name = "fedimint-cli";
                contents = [ craneBuildNative.fedimint-pkgs pkgs.bash pkgs.coreutils ];
                config = {
                  Cmd = [
                    "${craneBuildNative.fedimint-pkgs}/bin/fedimint-cli"
                  ];
                };
              };
            };
        };

        checks = {
          workspaceBuild = craneBuildNative.workspaceBuild;
          workspaceClippy = craneBuildNative.workspaceClippy;
        };

      });

  nixConfig = {
    extra-substituters = [ "https://fedimint.cachix.org" ];
    extra-trusted-public-keys = [ "fedimint.cachix.org-1:FpJJjy1iPVlvyv4OMiN5y9+/arFLPcnZhZVVCHCDYTs=" ];
  };


}
