all:
	rm -r bin || true
	mkdir bin
	stack build --copy-bins --local-bin-path bin

.PHONY: all
