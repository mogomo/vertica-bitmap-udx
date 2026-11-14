# vbitmap Makefile.
# UDx flags follow /opt/vertica/sdk/examples/makefile (Vertica 26.x): -shared -fPIC,
# _GLIBCXX_USE_CXX11_ABI=1, Vertica.cpp compiled in. Difference: -std=c++17.
# Never -march=native: one .so must run on every node of a cluster. CRoaring picks its
# AVX2 / AVX-512 kernels at run time.
#
#   make                build build/libvbitmap.so (the UDx library)
#   make deploy         install it (schema vbitmap); FENCED=yes|no (default yes)
#   make undeploy       remove it
#   make test           engine unit tests (no Vertica needed)
#   make asan           the same tests with address and undefined-behavior sanitizers
#   make fuzz           coverage-guided fuzzing (clang, libFuzzer): FUZZ_TARGET=fuzz_payload
#                       (default) or fuzz_expr; FUZZ_SECONDS=600 by default
#   make probe          build build/libvbitmap_probe.so (M0 ground probes, tests/probe)
#   make probe-deploy   install the probe functions (schema bitmap_probe), FENCED=yes|no
#   make probe-undeploy remove them
#   make clean

SDK_HOME ?= /opt/vertica/sdk
CXX      ?= g++
CC       ?= gcc
CLANGXX  ?= clang++
CLANG    ?= clang
OPT      ?= -O3
FENCED   ?= yes
FUZZ_SECONDS ?= 600

# Same C++ ABI as the Vertica server. Always 1 since Vertica 24.1.
VERTICA_CXX11_ABI ?= 1

BUILD_DIR := build
INCLUDES  := -I src/engine -I third_party/croaring

ENGINE_SRC := $(wildcard src/engine/*.cpp)
ENGINE_HDR := $(wildcard src/engine/*.h)
ROARING_C  := third_party/croaring/roaring.c
TEST_SRC   := $(wildcard tests/engine/test_*.cpp)
TEST_BIN   := $(patsubst tests/engine/%.cpp,$(BUILD_DIR)/tests/%,$(TEST_SRC))
ASAN_BIN   := $(patsubst tests/engine/%.cpp,$(BUILD_DIR)/asan/%,$(TEST_SRC))

COMMON_FLAGS := -std=c++17 -g $(OPT) -Wall -Wextra -pthread
ROARING_FLAGS := -std=c11 -g $(OPT) -fPIC -w
SAN_FLAGS    := -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
UDX_FLAGS    := $(COMMON_FLAGS) -DNDEBUG -fno-plt -I $(SDK_HOME)/include -Wno-unused-value \
                -Wno-unused-parameter -shared -fPIC -D_GLIBCXX_USE_CXX11_ABI=$(VERTICA_CXX11_ABI)

PROBE_LIB := $(BUILD_DIR)/libvbitmap_probe.so
LIB       := $(BUILD_DIR)/libvbitmap.so
UDX_SRC   := $(wildcard src/udx/*.cpp)
UDX_HDR   := $(wildcard src/udx/*.h)
VERSION   := 0.1.0
BUILD_FLAGS := $(OPT) $(shell uname -m) $(notdir $(CXX))-$(shell $(CXX) -dumpfullversion 2>/dev/null || $(CXX) -dumpversion)

.PHONY: all tools deploy undeploy test asan fuzz probe probe-deploy probe-undeploy clean

all: $(LIB)

# ---- UDx library ----------------------------------------------------------------------------

$(LIB): $(UDX_SRC) $(UDX_HDR) $(ENGINE_SRC) $(ENGINE_HDR) $(BUILD_DIR)/roaring.o $(SDK_HOME)/include/Vertica.cpp Makefile
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(UDX_FLAGS) $(INCLUDES) -I src/udx -DVBITMAP_VERSION='"$(VERSION)"' -DVBITMAP_BUILD_FLAGS='"$(BUILD_FLAGS)"' \
	    -o $@ $(UDX_SRC) $(ENGINE_SRC) $(BUILD_DIR)/roaring.o $(SDK_HOME)/include/Vertica.cpp

tools: $(BUILD_DIR)/bmexpr

$(BUILD_DIR)/bmexpr: tools/bmexpr.cpp $(ENGINE_SRC) $(ENGINE_HDR) $(BUILD_DIR)/roaring.o Makefile
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(COMMON_FLAGS) $(INCLUDES) -o $@ $< $(ENGINE_SRC) $(BUILD_DIR)/roaring.o

deploy: $(LIB) $(BUILD_DIR)/bmexpr
	scripts/deploy.sh --fenced=$(FENCED)

undeploy:
	scripts/deploy.sh --undeploy

# ---- engine tests ---------------------------------------------------------------------------

$(BUILD_DIR)/roaring.o: $(ROARING_C) third_party/croaring/roaring.h
	@mkdir -p $(BUILD_DIR)
	$(CC) $(ROARING_FLAGS) -c -o $@ $<

$(BUILD_DIR)/tests/%: tests/engine/%.cpp tests/engine/test_util.h $(ENGINE_SRC) $(ENGINE_HDR) $(BUILD_DIR)/roaring.o Makefile
	@mkdir -p $(BUILD_DIR)/tests
	$(CXX) $(COMMON_FLAGS) -fPIC $(INCLUDES) -o $@ $< $(ENGINE_SRC) $(BUILD_DIR)/roaring.o

test: $(TEST_BIN)
	@for t in $(TEST_BIN); do $$t || exit 1; done
	@echo "All engine tests passed."

$(BUILD_DIR)/asan/roaring.o: $(ROARING_C) third_party/croaring/roaring.h
	@mkdir -p $(BUILD_DIR)/asan
	$(CC) $(ROARING_FLAGS) -O1 $(SAN_FLAGS) -c -o $@ $<

$(BUILD_DIR)/asan/%: tests/engine/%.cpp tests/engine/test_util.h $(ENGINE_SRC) $(ENGINE_HDR) $(BUILD_DIR)/asan/roaring.o Makefile
	@mkdir -p $(BUILD_DIR)/asan
	$(CXX) $(COMMON_FLAGS) -O1 $(SAN_FLAGS) $(INCLUDES) -o $@ $< $(ENGINE_SRC) $(BUILD_DIR)/asan/roaring.o

asan: $(ASAN_BIN)
	@for t in $(ASAN_BIN); do $$t || exit 1; done
	@echo "All engine tests passed under ASan and UBSan."

# ---- fuzzing (clang) ------------------------------------------------------------------------

FUZZ_DIR := $(BUILD_DIR)/fuzz

$(FUZZ_DIR)/roaring.o: $(ROARING_C) third_party/croaring/roaring.h
	@mkdir -p $(FUZZ_DIR)
	$(CLANG) $(ROARING_FLAGS) -O1 -fsanitize=fuzzer-no-link,address,undefined -c -o $@ $<

$(FUZZ_DIR)/fuzz_%: tests/engine/fuzz_%.cpp $(ENGINE_SRC) $(ENGINE_HDR) $(FUZZ_DIR)/roaring.o Makefile
	$(CLANGXX) -std=c++17 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all \
	    $(INCLUDES) -o $@ $< $(ENGINE_SRC) $(FUZZ_DIR)/roaring.o

$(FUZZ_DIR)/make_corpus: tests/engine/make_corpus.cpp $(ENGINE_SRC) $(ENGINE_HDR) $(BUILD_DIR)/roaring.o Makefile
	@mkdir -p $(FUZZ_DIR)
	$(CXX) $(COMMON_FLAGS) $(INCLUDES) -o $@ $< $(ENGINE_SRC) $(BUILD_DIR)/roaring.o

# FUZZ_TARGET=fuzz_payload (payload reader, seeded with valid payloads) or fuzz_expr (expression
# parser, seeded with a few expressions). Findings are written to build/fuzz/findings_<target>/.
FUZZ_TARGET ?= fuzz_payload

fuzz: $(FUZZ_DIR)/$(FUZZ_TARGET) $(FUZZ_DIR)/make_corpus
	@mkdir -p $(FUZZ_DIR)/corpus_$(FUZZ_TARGET) $(FUZZ_DIR)/findings_$(FUZZ_TARGET)
	@if [ "$(FUZZ_TARGET)" = fuzz_payload ]; then $(FUZZ_DIR)/make_corpus $(FUZZ_DIR)/corpus_$(FUZZ_TARGET); \
	 else printf '%s' 'a & (b | c) - d' > $(FUZZ_DIR)/corpus_$(FUZZ_TARGET)/s1; \
	      printf '%s' '"q ""x""" ^ (t_a | t_b) & c' > $(FUZZ_DIR)/corpus_$(FUZZ_TARGET)/s2; fi
	$(FUZZ_DIR)/$(FUZZ_TARGET) -max_total_time=$(FUZZ_SECONDS) -max_len=70000 -print_final_stats=1 \
	    -artifact_prefix=$(FUZZ_DIR)/findings_$(FUZZ_TARGET)/ $(FUZZ_DIR)/corpus_$(FUZZ_TARGET)

# ---- M0 probes ------------------------------------------------------------------------------

probe: $(PROBE_LIB)

$(PROBE_LIB): tests/probe/probe.cpp $(SDK_HOME)/include/Vertica.cpp Makefile
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(UDX_FLAGS) -o $@ tests/probe/probe.cpp $(SDK_HOME)/include/Vertica.cpp

probe-deploy: $(PROBE_LIB)
	vsql -X -v ON_ERROR_STOP=1 -v "libfile='$(abspath $(PROBE_LIB))'" \
	     -v "fenced=$(if $(filter yes,$(FENCED)),FENCED,NOT FENCED)" -f tests/probe/install.sql

probe-undeploy:
	vsql -X -c "DROP SCHEMA IF EXISTS bitmap_probe CASCADE;"

clean:
	rm -rf $(BUILD_DIR)
