# tug website — self-contained single-page site for GitHub Pages.
# Independent of the project's top-level Makefile.
#
#   make            build www/index.html (encode images -> AVIF, inline as base64)
#   make serve      build + preview at http://localhost:8000
#   make clean      remove the built index.html
#
# Needs `magick` (ImageMagick w/ AVIF) and `node` to build. The built index.html
# is committed, so GitHub Pages deploys it as-is — no build tools needed in CI.

SOURCES := index.template.html build.mjs tug-docker.png the-tug-way.png less-is-more.jpeg

.PHONY: all serve clean
all: index.html

index.html: $(SOURCES)
	@command -v magick >/dev/null || { echo "need ImageMagick (brew install imagemagick)"; exit 1; }
	@command -v node    >/dev/null || { echo "need node (brew install node)"; exit 1; }
	node build.mjs

serve: index.html
	@echo "serving http://localhost:8000  (Ctrl-C to stop)"
	@python3 -m http.server 8000

clean:
	rm -f index.html build.tmp.avif
