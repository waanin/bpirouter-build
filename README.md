# bpirouter-build

BpiRouter Firmware Build System. Based on OpenWrt 25.12.2, not a fork of the mainline.

## Build Methods

- Full Build: ./scripts/build-full.sh
- Quick Pack: ./scripts/build-image.sh (repacks only the application layer, does not recompile the kernel)

## Directory Structure

- config/       OpenWrt .config
- patches/      Kernel / U-Boot / base-files patches (quilt format)
- scripts/      Build scripts
- imagebuilder/ ImageBuilder quick-pack related files
