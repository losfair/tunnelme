all:
	rm -r bin || true
	mkdir bin
	stack build --profile --copy-bins --local-bin-path bin

.PHONY: all
