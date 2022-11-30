.PHONY: build
build: clean tidy
	zig build -Drelease-fast=true

.PHONY: build-safe
build-safe:
	zig build

.PHONY: run
run:
	zig build run

.PHONY: test
test:  # Run unit tests
	zig test build.zig
	zig build test
	zig test src/e2e_test.zig

tidy: requirements.txt  # Reinstall libs
	./package.sh clean
	./package.sh update

.PHONY: clean
clean:
	rm -rf zig-cache zig-out
