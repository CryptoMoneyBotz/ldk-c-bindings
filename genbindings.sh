#!/usr/bin/env bash

set -e
set -x

if [ ! -d "$1/lightning" ]; then
	echo "USAGE: $0 path-to-rust-lightning"
	exit 1
fi

# On reasonable systems, we can use realpath here, but OSX is a diva with 20-year-old software.
ORIG_PWD="$(pwd)"
cd "$1/lightning"
LIGHTNING_PATH="$(pwd)"
cd "$ORIG_PWD"

# Generate (and reasonably test) C bindings

# First build the latest c-bindings-gen binary
cd c-bindings-gen && cargo build --release && cd ..

# Then wipe all the existing C bindings (because we're being run in the right directory)
# note that we keep the few manually-generated files first:
mv lightning-c-bindings/src/c_types/mod.rs ./
mv lightning-c-bindings/src/bitcoin ./

rm -rf lightning-c-bindings/src

mkdir -p lightning-c-bindings/src/c_types/
mv ./mod.rs lightning-c-bindings/src/c_types/
mv ./bitcoin lightning-c-bindings/src/

# Finally, run the c-bindings-gen binary, building fresh bindings.
OUT="$(pwd)/lightning-c-bindings/src"
OUT_TEMPL="$(pwd)/lightning-c-bindings/src/c_types/derived.rs"
OUT_F="$(pwd)/lightning-c-bindings/include/rust_types.h"
OUT_CPP="$(pwd)/lightning-c-bindings/include/lightningpp.hpp"
BIN="$(pwd)/c-bindings-gen/target/release/c-bindings-gen"

pushd "$LIGHTNING_PATH"
RUSTC_BOOTSTRAP=1 cargo rustc --profile=check -- -Zunstable-options --pretty=expanded |
	RUST_BACKTRACE=1 "$BIN" "$OUT/" lightning "$OUT_TEMPL" "$OUT_F" "$OUT_CPP"
popd

HOST_PLATFORM="$(rustc --version --verbose | grep "host:")"
if [ "$HOST_PLATFORM" = "host: x86_64-apple-darwin" ]; then
	# OSX sed is for some reason not compatible with GNU sed
	sed -i '' 's|lightning = { .*|lightning = { path = "'"$LIGHTNING_PATH"'" }|' lightning-c-bindings/Cargo.toml
else
	sed -i 's|lightning = { .*|lightning = { path = "'"$LIGHTNING_PATH"'" }|' lightning-c-bindings/Cargo.toml
fi

# Now cd to lightning-c-bindings, build the generated bindings, and call cbindgen to build a C header file
PATH="$PATH:~/.cargo/bin"
cd lightning-c-bindings
cargo build
cbindgen -v --config cbindgen.toml -o include/lightning.h >/dev/null 2>&1

# cbindgen is relatively braindead when exporting typedefs -
# it happily exports all our typedefs for private types, even with the
# generics we specified in C mode! So we drop all those types manually here.
if [ "$HOST_PLATFORM" = "host: x86_64-apple-darwin" ]; then
	# OSX sed is for some reason not compatible with GNU sed
	sed -i '' 's/typedef LDKnative.*Import.*LDKnative.*;//g' include/lightning.h

	# stdlib.h doesn't exist in clang's wasm sysroot, and cbindgen
	# doesn't actually use it anyway, so drop the import.
	sed -i '' 's/#include <stdlib.h>//g' include/lightning.h
else
	sed -i 's/typedef LDKnative.*Import.*LDKnative.*;//g' include/lightning.h

	# stdlib.h doesn't exist in clang's wasm sysroot, and cbindgen
	# doesn't actually use it anyway, so drop the import.
	sed -i 's/#include <stdlib.h>//g' include/lightning.h
fi

# Finally, sanity-check the generated C and C++ bindings with demo apps:

CFLAGS="-Wall -Wno-nullability-completeness -pthread"

# Naively run the C demo app:
gcc $CFLAGS -Wall -g -pthread demo.c target/debug/libldk.a -ldl
./a.out

# And run the C++ demo app in valgrind to test memory model correctness and lack of leaks.
g++ $CFLAGS -std=c++11 -Wall -g -pthread demo.cpp -Ltarget/debug/ -lldk -ldl
if [ -x "`which valgrind`" ]; then
	LD_LIBRARY_PATH=target/debug/ valgrind --error-exitcode=4 --memcheck:leak-check=full --show-leak-kinds=all ./a.out
	echo
else
	echo "WARNING: Please install valgrind for more testing"
fi

# Test a statically-linked C++ version, tracking the resulting binary size and runtime
# across debug, LTO, and cross-language LTO builds (using the same compiler each time).
clang++ $CFLAGS -std=c++11 demo.cpp target/debug/libldk.a -ldl
strip ./a.out
echo " C++ Bin size and runtime w/o optimization:"
ls -lha a.out
time ./a.out > /dev/null

# Then, check with memory sanitizer, if we're on Linux and have rustc nightly
if [ "$HOST_PLATFORM" = "host: x86_64-unknown-linux-gnu" ]; then
	if cargo +nightly --version >/dev/null 2>&1; then
		LLVM_V=$(rustc +nightly --version --verbose | grep "LLVM version" | awk '{ print substr($3, 0, 2); }')
		if [ -x "$(which clang-$LLVM_V)" ]; then
			cargo +nightly clean
			cargo +nightly rustc -Zbuild-std --target x86_64-unknown-linux-gnu -v -- -Zsanitizer=memory -Zsanitizer-memory-track-origins -Cforce-frame-pointers=yes
			mv target/x86_64-unknown-linux-gnu/debug/libldk.* target/debug/

			# Sadly, std doesn't seem to compile into something that is memsan-safe as of Aug 2020,
			# so we'll always fail, not to mention we may be linking against git rustc LLVM which
			# may differ from clang-llvm, so just allow everything here to fail.
			set +e

			# First the C demo app...
			clang-$LLVM_V $CFLAGS -fsanitize=memory -fsanitize-memory-track-origins -g demo.c target/debug/libldk.a -ldl
			./a.out

			# ...then the C++ demo app
			clang++-$LLVM_V $CFLAGS -std=c++11 -fsanitize=memory -fsanitize-memory-track-origins -g demo.cpp target/debug/libldk.a -ldl
			./a.out >/dev/null

			# restore exit-on-failure
			set -e
		else
			echo "WARNING: Can't use memory sanitizer without clang-$LLVM_V"
		fi
	else
		echo "WARNING: Can't use memory sanitizer without rustc nightly"
	fi
else
	echo "WARNING: Can't use memory sanitizer on non-Linux, non-x86 platforms"
fi

RUSTC_LLVM_V=$(rustc --version --verbose | grep "LLVM version" | awk '{ print substr($3, 0, 2); }' | tr -d '.')

if [ "$HOST_PLATFORM" = "host: x86_64-apple-darwin" ]; then
	# Apple is special, as always, and decided that they must ensure that there is no way to identify
	# the LLVM version used. Why? Just to make your life hard.
	# This list is taken from https://en.wikipedia.org/wiki/Xcode
	APPLE_CLANG_V=$(clang --version | head -n1 | awk '{ print $4 }')
	if [ "$APPLE_CLANG_V" = "10.0.0" ]; then
		CLANG_LLVM_V="6"
	elif [ "$APPLE_CLANG_V" = "10.0.1" ]; then
		CLANG_LLVM_V="7"
	elif [ "$APPLE_CLANG_V" = "11.0.0" ]; then
		CLANG_LLVM_V="8"
	elif [ "$APPLE_CLANG_V" = "11.0.3" ]; then
		CLANG_LLVM_V="9"
	elif [ "$APPLE_CLANG_V" = "12.0.0" ]; then
		CLANG_LLVM_V="10"
	else
		echo "WARNING: Unable to identify Apple clang LLVM version"
		CLANG_LLVM_V="0"
	fi
else
	CLANG_LLVM_V=$(clang --version | head -n1 | awk '{ print substr($4, 0, 2); }' | tr -d '.')
fi

if [ "$CLANG_LLVM_V" = "$RUSTC_LLVM_V" ]; then
	CLANG=clang
	CLANGPP=clang++
elif [ "$(which clang-$RUSTC_LLVM_V)" != "" ]; then
	CLANG="$(which clang-$RUSTC_LLVM_V)"
	CLANGPP="$(which clang++-$RUSTC_LLVM_V)"
fi

if [ "$CLANG" != "" -a "$CLANGPP" = "" ]; then
	echo "WARNING: It appears you have a clang-$RUSTC_LLVM_V but not clang++-$RUSTC_LLVM_V. This is common, but leaves us unable to compile C++ with LLVM $RUSTC_LLVM_V"
	echo "You should create a symlink called clang++-$RUSTC_LLVM_V pointing to $CLANG in $(dirname $CLANG)"
fi

# Finally, if we're on OSX or on Linux, build the final debug binary with address sanitizer (and leave it there)
if [ "$HOST_PLATFORM" = "host: x86_64-unknown-linux-gnu" -o "$HOST_PLATFORM" = "host: x86_64-apple-darwin" ]; then
	if [ "$CLANGPP" != "" ]; then
		if [ "$HOST_PLATFORM" = "host: x86_64-apple-darwin" ]; then
			# OSX sed is for some reason not compatible with GNU sed
			sed -i .bk 's/,"cdylib"]/]/g' Cargo.toml
		else
			sed -i.bk 's/,"cdylib"]/]/g' Cargo.toml
		fi
		RUSTC_BOOTSTRAP=1 cargo rustc -v -- -Zsanitizer=address -Cforce-frame-pointers=yes || ( mv Cargo.toml.bk Cargo.toml; exit 1)
		mv Cargo.toml.bk Cargo.toml

		# First the C demo app...
		$CLANG $CFLAGS -fsanitize=address -g demo.c target/debug/libldk.a -ldl
		ASAN_OPTIONS='detect_leaks=1 detect_invalid_pointer_pairs=1 detect_stack_use_after_return=1' ./a.out

		# ...then the C++ demo app
		$CLANGPP $CFLAGS -std=c++11 -fsanitize=address -g demo.cpp target/debug/libldk.a -ldl
		ASAN_OPTIONS='detect_leaks=1 detect_invalid_pointer_pairs=1 detect_stack_use_after_return=1' ./a.out >/dev/null
	else
		echo "WARNING: Please install clang-$RUSTC_LLVM_V and clang++-$RUSTC_LLVM_V to build with address sanitizer"
	fi
else
	echo "WARNING: Can't use address sanitizer on non-Linux, non-OSX non-x86 platforms"
fi

if [ "$(rustc --print target-list | grep wasm32-wasi)" != "" ]; then
	# Test to see if clang supports wasm32 as a target (which is needed to build rust-secp256k1)
	echo "int main() {}" > genbindings_wasm_test_file.c
	clang -nostdlib -o /dev/null --target=wasm32-wasi -Wl,--no-entry genbindings_wasm_test_file.c > /dev/null 2>&1 &&
	# And if it does, build a WASM binary without capturing errors
	cargo rustc -v --target=wasm32-wasi -- -C embed-bitcode=yes &&
	CARGO_PROFILE_RELEASE_LTO=true cargo rustc -v --release --target=wasm32-wasi -- -C opt-level=s -C linker-plugin-lto -C lto ||
	echo "Cannot build WASM lib as clang does not seem to support the wasm32-wasi target"
	rm genbindings_wasm_test_file.c
fi

# Now build with LTO on on both C++ and rust, but without cross-language LTO:
CARGO_PROFILE_RELEASE_LTO=true cargo rustc -v --release -- -C lto
clang++ $CFLAGS -std=c++11 -flto -O2 demo.cpp target/release/libldk.a -ldl
strip ./a.out
echo "C++ Bin size and runtime with only RL (LTO) optimized:"
ls -lha a.out
time ./a.out > /dev/null

if [ "$HOST_PLATFORM" != "host: x86_64-apple-darwin" -a "$CLANGPP" != "" ]; then
	# Finally, test cross-language LTO. Note that this will fail if rustc and clang++
	# build against different versions of LLVM (eg when rustc is installed via rustup
	# or Ubuntu packages). This should work fine on Distros which do more involved
	# packaging than simply shipping the rustup binaries (eg Debian should Just Work
	# here).
	CARGO_PROFILE_RELEASE_LTO=true cargo rustc -v --release -- -C linker-plugin-lto -C lto -C link-arg=-fuse-ld=lld
	$CLANGPP $CFLAGS -flto -fuse-ld=lld -O2 demo.cpp target/release/libldk.a -ldl
	strip ./a.out
	echo "C++ Bin size and runtime with cross-language LTO:"
	ls -lha a.out
	time ./a.out > /dev/null
else
	echo "WARNING: Building with cross-language LTO is not avilable on OSX or without clang-$RUSTC_LLVM_V"
fi
