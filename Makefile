CXX := g++
CXXFLAGS := \
    -std=c++20 \
    -Wall \
    -Wextra \
    -Wpedantic \
    -g

BUILD_DIR := _build

ifeq ($(RELEASE),1)
CXXFLAGS += -O2 -DNDEBUG
BUILD_DIR := _build_release
else
CXXFLAGS += -fsanitize=address -fno-omit-frame-pointer
LDFLAGS += -fsanitize=address
endif

SDL2_CFLAGS := $(shell pkg-config --cflags sdl2)
SDL2_LIBS   := $(shell pkg-config --libs sdl2)

TARGET := vm
CHIP8  := chip8
CODEGEN := codegen
GEN_DIR := gen

# Core VM: no display, no codegen
SRCS := $(filter-out src/codegen.cpp, $(wildcard src/*.cpp))
HDRS := $(wildcard src/*.h) $(wildcard src/*.hpp)
OBJS := $(SRCS:src/%.cpp=$(BUILD_DIR)/%.o)

CODEGEN_OBJS := $(BUILD_DIR)/codegen.o $(BUILD_DIR)/vm.o

# Chip8 example
CHIP8_DIR  := examples/chip8
CHIP8_OBJS := $(BUILD_DIR)/chip8_main.o $(BUILD_DIR)/chip8_ext.o \
              $(BUILD_DIR)/chip8_display.o $(BUILD_DIR)/chip8_sound.o \
              $(BUILD_DIR)/vm.o

all: $(TARGET) $(CHIP8) $(GEN_DIR)/gen.pl

.PHONY: release
release:
	@$(MAKE) RELEASE=1 all

$(TARGET): $(OBJS)
	$(CXX) $(LDFLAGS) $(OBJS) -o $@

$(CHIP8): $(CHIP8_OBJS)
	$(CXX) $(LDFLAGS) $(CHIP8_OBJS) $(SDL2_LIBS) -o $@

$(CODEGEN): $(CODEGEN_OBJS)
	$(CXX) $(LDFLAGS) $(CODEGEN_OBJS) -o $@

$(GEN_DIR)/gen.pl: $(CODEGEN) | $(GEN_DIR)
	./$(CODEGEN) > $@

$(BUILD_DIR)/%.o: src/%.cpp $(HDRS) | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/chip8_main.o: $(CHIP8_DIR)/main.cpp $(HDRS) $(CHIP8_DIR)/chip8_ext.h | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/chip8_ext.o: $(CHIP8_DIR)/chip8_ext.cpp $(HDRS) $(CHIP8_DIR)/chip8_ext.h | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/chip8_display.o: $(CHIP8_DIR)/display.cpp $(HDRS) $(CHIP8_DIR)/display.h | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(SDL2_CFLAGS) -c $< -o $@

$(BUILD_DIR)/chip8_sound.o: $(CHIP8_DIR)/sound.cpp $(CHIP8_DIR)/sound.h | $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(SDL2_CFLAGS) -c $< -o $@

$(BUILD_DIR):
	mkdir -p $@

$(GEN_DIR):
	mkdir -p $@

.PHONY: clean
clean:
	rm -rf _build _build_release $(GEN_DIR) $(TARGET) $(CHIP8) $(CODEGEN)

.PHONY: format
format:
	clang-format -i $(wildcard src/*.cpp) $(wildcard src/*.h) \
	             $(wildcard $(CHIP8_DIR)/*.cpp) $(wildcard $(CHIP8_DIR)/*.h)

.PHONY: format-check
format-check:
	clang-format --dry-run --Werror $(wildcard src/*.cpp) $(wildcard src/*.h) \
	             $(wildcard $(CHIP8_DIR)/*.cpp) $(wildcard $(CHIP8_DIR)/*.h)

.PHONY: test
test: quad bats

.PHONY: quad
quad:
	@cd compiler && for mod in parser typecheck codegen; do \
		scryer-prolog -f -g "use_module(library('numerics/quadtests')), check_module_quads($$mod, _), halt." < /dev/null; \
	done

.PHONY: bats
bats: $(TARGET) $(GEN_DIR)/gen.pl
	bats tests/

# Compile .sets programs to .bin
programs/%.bin: programs/%.sets $(GEN_DIR)/gen.pl
	@cd compiler && scryer-prolog -f -g "use_module(compiler), compile_file('../$<', '../$@'), halt." < /dev/null

examples/chip8/chip8.bin: examples/chip8/chip8.sets $(GEN_DIR)/gen.pl
	@cd compiler && scryer-prolog -f compiler.pl -g "compile_file('../examples/chip8/chip8.sets', '../examples/chip8/chip8.bin'), halt." < /dev/null

examples/forth/forth.bin: examples/forth/forth.sets examples/forth/reader.sets examples/forth/primitives.sets examples/forth/compile.sets $(GEN_DIR)/gen.pl
	@cd compiler && scryer-prolog -f compiler.pl -g "compile_file('../examples/forth/forth.sets', '../examples/forth/forth.bin'), halt." < /dev/null
