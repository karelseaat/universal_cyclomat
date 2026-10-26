.PHONY: build test clean install uninstall help

BINARY_NAME=cyclomat
SRC=src/cyclomat.nim
TEST_SRC=tests/test_cyclomat.nim
INSTALL_DIR=/usr/local/bin

help:
	@echo "Usage:"
	@echo "  make build      - Compile the tool (release mode)"
	@echo "  make test       - Run the unit test suite"
	@echo "  make clean      - Remove build artifacts"
	@echo "  make install    - Install to $(INSTALL_DIR) (may require sudo)"
	@echo "  make uninstall  - Remove from $(INSTALL_DIR)"

build:
	nim c -d:release --opt:speed -o:$(BINARY_NAME) $(SRC)

test:
	nim c -r -d:testing $(TEST_SRC)

pylib:
	nim c --app:lib -d:release -d:python --out:cyclomat.so $(SRC)

clean:
	rm -f $(BINARY_NAME)
	rm -f src/$(BINARY_NAME)
	rm -f cyclomat.so
	rm -f tests/test_cyclomat

install: build
	cp $(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)

uninstall:
	rm -f $(INSTALL_DIR)/$(BINARY_NAME)
