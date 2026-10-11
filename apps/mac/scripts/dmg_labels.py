# Sets the Finder window's background colour in the disk image's .DS_Store, so the icon labels are drawn light.
# dmgbuild leaves the colour at white; with the image background Finder takes the label colour from it, which made
# «Bandito.app» and «Applications» black on the dark background.
# Usage: python3 dmg_labels.py <mounted volume>   (the image must be writable, mounted without Finder)
import sys

from ds_store import DSStore

# The brand background #12100E (see brand/dmg/background.html).
BACKGROUND_RGB = {
    "backgroundColorRed": 0x12 / 255,
    "backgroundColorGreen": 0x10 / 255,
    "backgroundColorBlue": 0x0E / 255,
}

if len(sys.argv) != 2:
    sys.exit("usage: dmg_labels.py <mounted volume>")
path = sys.argv[1].rstrip("/") + "/.DS_Store"
with DSStore.open(path, "r+") as store:
    icvp = dict(store["."]["icvp"])
    icvp.update(BACKGROUND_RGB)
    del store["."]["icvp"]
    store["."]["icvp"] = icvp
print("background colour set in", path)
