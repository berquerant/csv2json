.PHONY: build
build: clean tidy
	zig build -Drelease-fast=true

.PHONY: build-safe
build-debug:
	zig build

.PHONY: run
run:
	zig build run

.PHONY: test
test:  # Run unit tests
	zig test build.zig
	zig build test

.PHONY: test-all
test-all: # Run all tests
	zig test build.zig
	find src -type f | xargs -n 1 -P 4 zig test

tidy: requirements.txt  # Reinstall libs
	./package.sh clean
	./package.sh update

.PHONY: clean
clean:
	rm -rf zig-cache zig-out
