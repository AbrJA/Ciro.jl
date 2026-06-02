# Build script for BinaryBuilder.jl
# Run with: julia build_tarballs.jl --deploy=local
#
# See: https://docs.binarybuilder.org

using BinaryBuilder

name = "Ciro"
version = v"0.1.0"

sources = [
    DirectorySource("./lib"),
]

script = raw"""
cd ${WORKSPACE}/srcdir
make install prefix=${prefix} DLEXT=${dlext} CC=${CC}
"""

platforms = supported_platforms(; exclude = p -> !Sys.islinux(p))

products = [
    LibraryProduct("libciro", :libciro),
]

dependencies = [
    Dependency("liburing_jll"),
]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               julia_compat="1.10")
