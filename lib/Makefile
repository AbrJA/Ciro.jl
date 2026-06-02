# ══════════════════════════════════════════════════════════════════════════════
# Ciro.jl — C library Makefile
#
# Targets:
#   make          → build lib/ciro.so (optimised, release)
#   make debug    → build with -g -O0 and address sanitizer
#   make clean    → remove build artefacts
#   make install  → copy to $(prefix)/lib/  (used by BinaryBuilder.jl)
#
# BinaryBuilder usage:
#   The `install` target follows the BinaryBuilder convention:
#     prefix  — set by BB (e.g. /workspace/destdir)
#     DLEXT   — set by BB (so / dylib / dll)
#   Example: make install prefix=/workspace/destdir DLEXT=so
# ══════════════════════════════════════════════════════════════════════════════

CC      := gcc
SRC     := ciro.c
LIB     := ciro.so

# ── Compiler flags ───────────────────────────────────────────────────────────
CFLAGS_COMMON := -fPIC -std=c11 -Wall -Wextra -Wpedantic
CFLAGS_RELEASE := -O3 -march=native -DNDEBUG
CFLAGS_DEBUG   := -O0 -g3 -fsanitize=address,undefined

# ── liburing linkage ─────────────────────────────────────────────────────────
# Use pkg-config when available; fall back to plain -luring.
URING_CFLAGS := $(shell pkg-config --cflags liburing 2>/dev/null)
URING_LIBS   := $(shell pkg-config --libs   liburing 2>/dev/null || echo -luring)

# ── BinaryBuilder install path ───────────────────────────────────────────────
prefix  ?= $(abspath ..)
DLEXT   ?= so
DESTLIB  = $(prefix)/lib/libciro.$(DLEXT)

# ══════════════════════════════════════════════════════════════════════════════
# Rules
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: all debug clean install check-deps

all: check-deps $(LIB)

$(LIB): $(SRC)
	$(CC) $(CFLAGS_COMMON) $(CFLAGS_RELEASE) $(URING_CFLAGS) \
	      -shared -o $@ $< $(URING_LIBS)
	@echo "Built: lib/$(LIB)"

debug: check-deps
	$(CC) $(CFLAGS_COMMON) $(CFLAGS_DEBUG) $(URING_CFLAGS) \
	      -shared -o ciro_debug.so $(SRC) $(URING_LIBS)
	@echo "Built: lib/ciro_debug.so (debug + asan)"

install: all
	@mkdir -p $(prefix)/lib
	cp $(LIB) $(DESTLIB)
	@echo "Installed: $(DESTLIB)"

clean:
	rm -f $(LIB) ciro_debug.so

# Verify liburing headers are available before trying to compile
check-deps:
	@command -v $(CC) >/dev/null 2>&1 || \
	  { echo "ERROR: gcc not found. Install: apt install gcc"; exit 1; }
	@$(CC) -x c - -luring -o /dev/null </dev/null 2>/dev/null || \
	  { echo "ERROR: liburing not found. Install: apt install liburing-dev"; exit 1; }
