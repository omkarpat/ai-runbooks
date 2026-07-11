APP     := Runbooks
BUNDLE  := $(APP).app
CONFIG  ?= debug
BINPATH := .build/$(CONFIG)/$(APP)

.PHONY: build bundle run open clean

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BINPATH) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)
	@echo "Built ./$(BUNDLE)"

# Run in the foreground so logs print to the terminal (Ctrl-C to quit).
run: bundle
	./$(BUNDLE)/Contents/MacOS/$(APP)

# Launch detached like a normal app (menu-bar only, no dock icon).
open: bundle
	open $(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)
