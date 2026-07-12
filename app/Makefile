APP     := Runbooks
BUNDLE  := $(APP).app
CONFIG  ?= debug
BINPATH := .build/$(CONFIG)/$(APP)

# Signing identity. Ad-hoc ("-") is the default but does NOT persist TCC grants
# (Screen Recording / Mic) across rebuilds — macOS sees each build as a new app.
# For grants that stick, create a stable self-signed cert and pass it here:
#   make bundle SIGN_IDENTITY="ai-runbooks-dev"
# See `make signing-cert` to create one.
SIGN_IDENTITY ?= -

.PHONY: build bundle run open clean signing-cert icon

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BINPATH) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	[ -f Resources/Runbooks.icns ] && cp Resources/Runbooks.icns $(BUNDLE)/Contents/Resources/Runbooks.icns || true
	codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE)
	@echo "Built ./$(BUNDLE) (signed: $(SIGN_IDENTITY))"

# Run in the foreground so logs print to the terminal (Ctrl-C to quit).
run: bundle
	./$(BUNDLE)/Contents/MacOS/$(APP)

# Launch detached like a normal app (menu-bar only, no dock icon).
open: bundle
	open $(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)

# Regenerate Resources/Runbooks.icns from scripts/generate-icon.swift.
icon:
	swift scripts/generate-icon.swift /tmp/rb-icon.png
	rm -rf /tmp/rb.iconset && mkdir -p /tmp/rb.iconset
	sips -z 16 16     /tmp/rb-icon.png --out /tmp/rb.iconset/icon_16x16.png      >/dev/null
	sips -z 32 32     /tmp/rb-icon.png --out /tmp/rb.iconset/icon_16x16@2x.png   >/dev/null
	sips -z 32 32     /tmp/rb-icon.png --out /tmp/rb.iconset/icon_32x32.png      >/dev/null
	sips -z 64 64     /tmp/rb-icon.png --out /tmp/rb.iconset/icon_32x32@2x.png   >/dev/null
	sips -z 128 128   /tmp/rb-icon.png --out /tmp/rb.iconset/icon_128x128.png    >/dev/null
	sips -z 256 256   /tmp/rb-icon.png --out /tmp/rb.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   /tmp/rb-icon.png --out /tmp/rb.iconset/icon_256x256.png    >/dev/null
	sips -z 512 512   /tmp/rb-icon.png --out /tmp/rb.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   /tmp/rb-icon.png --out /tmp/rb.iconset/icon_512x512.png    >/dev/null
	sips -z 1024 1024 /tmp/rb-icon.png --out /tmp/rb.iconset/icon_512x512@2x.png >/dev/null
	mkdir -p Resources && iconutil -c icns /tmp/rb.iconset -o Resources/Runbooks.icns
	@echo "Wrote Resources/Runbooks.icns"

# Make Screen Recording / Mic grants persist across rebuilds by signing with a
# stable self-signed identity (ad-hoc signing does not persist TCC grants).
signing-cert:
	@echo "Create a stable self-signed code-signing certificate (one time):"
	@echo "  1. Open 'Keychain Access' -> menu Certificate Assistant -> Create a Certificate..."
	@echo "  2. Name: ai-runbooks-dev   Identity Type: Self Signed Root   Certificate Type: Code Signing"
	@echo "  3. Create it (login keychain)."
	@echo ""
	@echo "Then build signed with it:"
	@echo "  make bundle SIGN_IDENTITY=\"ai-runbooks-dev\"   (or: make run SIGN_IDENTITY=\"ai-runbooks-dev\")"
	@echo ""
	@echo "One-time cleanup of the stale ad-hoc grant:"
	@echo "  System Settings -> Privacy & Security -> Screen Recording -> remove 'ai-runbooks' (the - button),"
	@echo "  then launch the signed app and grant once. It will stick from then on."
