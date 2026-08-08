BUILD_DIR=build
BUILDTYPE?=Release
MIMALLOC?=ON
TJS_ZIG_TARGET?=

ifneq ($(TJS_ZIG_TARGET),)
TJS_ZIG_TARGET_ARG=-DTJS_ZIG_TARGET=$(TJS_ZIG_TARGET)
endif

JOBS?=$(shell getconf _NPROCESSORS_ONLN)
ifeq ($(JOBS),)
JOBS := $(shell sysctl -n hw.ncpu)
endif
ifeq ($(JOBS),)
JOBS := $(shell nproc)
endif
ifeq ($(JOBS),)
JOBS := 4
endif

TJS=$(BUILD_DIR)/tjs
TJSC=$(BUILD_DIR)/tjsc
STDLIB_MODULES=$(wildcard src/js/stdlib/*.js)
POLYFILLS_SOURCES=src/js/polyfills/*.js src/js/polyfills/**/*.js src/js/stdlib/utils.js
ESBUILD?=npx esbuild
ESBUILD_PARAMS_COMMON=--target=esnext --platform=neutral --format=esm --main-fields=main,module
ESBUILD_PARAMS_MINIFY=--minify --keep-names
POLYFILLS_URL_ON=--alias:@tjs/polyfill-url=./src/js/polyfills/url.js --alias:@tjs/worker-url=./src/js/polyfills/worker-url.js
POLYFILLS_URL_OFF=--alias:@tjs/polyfill-url=./src/js/polyfills/noop.js --alias:@tjs/worker-url=./src/js/polyfills/worker-url-disabled.js
POLYFILLS_WEBCRYPTO_ON=--alias:@tjs/polyfill-crypto=./src/js/polyfills/crypto/crypto.js
POLYFILLS_WEBCRYPTO_OFF=--alias:@tjs/polyfill-crypto=./src/js/polyfills/crypto/rng.js
TJSC_PARAMS_STIP=-s
JS_NO_STRIP?=0

ifeq ($(JS_NO_STRIP),1)
	ESBUILD_PARAMS_MINIFY=
	TJSC_PARAMS_STIP=
endif

all: $(TJS)

$(BUILD_DIR)/CMakeCache.txt:
	cmake -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(BUILDTYPE) -DBUILD_WITH_MIMALLOC=$(MIMALLOC) $(TJS_ZIG_TARGET_ARG)

$(TJS): $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) -j $(JOBS)

$(TJSC): $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) --target tjsc -j $(JOBS)

src/bundles/js/core/polyfills.js: $(POLYFILLS_SOURCES)
	@mkdir -p $(dir $@)
	$(ESBUILD) src/js/polyfills/index.js \
		--bundle \
		--metafile=$@.json \
		--outfile=$@ \
		--external:tjs:* \
		$(POLYFILLS_URL_ON) \
		$(POLYFILLS_WEBCRYPTO_ON) \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/js/core/no-ada/polyfills.js: $(POLYFILLS_SOURCES)
	@mkdir -p $(dir $@)
	$(ESBUILD) src/js/polyfills/index.js \
		--bundle \
		--metafile=$@.json \
		--outfile=$@ \
		--external:tjs:* \
		$(POLYFILLS_URL_OFF) \
		$(POLYFILLS_WEBCRYPTO_ON) \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/js/core/no-webcrypto/polyfills.js: $(POLYFILLS_SOURCES)
	@mkdir -p $(dir $@)
	$(ESBUILD) src/js/polyfills/index.js \
		--bundle \
		--metafile=$@.json \
		--outfile=$@ \
		--external:tjs:* \
		$(POLYFILLS_URL_ON) \
		$(POLYFILLS_WEBCRYPTO_OFF) \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/js/core/minimal/polyfills.js: $(POLYFILLS_SOURCES)
	@mkdir -p $(dir $@)
	$(ESBUILD) src/js/polyfills/index.js \
		--bundle \
		--metafile=$@.json \
		--outfile=$@ \
		--external:tjs:* \
		$(POLYFILLS_URL_OFF) \
		$(POLYFILLS_WEBCRYPTO_OFF) \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/c/core/polyfills.c: $(TJSC) src/bundles/js/core/polyfills.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:internal/polyfills" \
		-p tjs__ \
		src/bundles/js/core/polyfills.js

src/bundles/c/core/%/polyfills.c: $(TJSC) src/bundles/js/core/%/polyfills.js
	@mkdir -p $(dir $@)
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:internal/polyfills" \
		-p tjs__ \
		src/bundles/js/core/$*/polyfills.js

src/bundles/js/core/core.js: src/js/core/*.js src/js/core/**/*.js
	$(ESBUILD) src/js/core/index.js \
		--bundle \
		--metafile=$@.json \
		--outfile=$@ \
		--external:tjs:* \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/c/core/core.c: $(TJSC) src/bundles/js/core/core.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:internal/bootstrap" \
		-p tjs__ \
		src/bundles/js/core/core.js

src/bundles/js/core/run-main.js: src/js/run-main/*.js
	$(ESBUILD) src/js/run-main/index.js \
		--bundle \
		--metafile=$@.json \
		--outfile=$@ \
		--external:tjs:* \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/c/core/run-main.c: $(TJSC) src/bundles/js/core/run-main.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:internal/run-main" \
		-p tjs__ \
		src/bundles/js/core/run-main.js

src/bundles/js/core/run-repl.js: src/js/run-repl/*.js
	$(ESBUILD) src/js/run-repl/repl.js \
		--bundle \
		--metafile=$@.json \
		--outfile=$@ \
		--external:tjs:* \
		--log-override:direct-eval=silent \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/c/core/run-repl.c: $(TJSC) src/bundles/js/core/run-repl.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:internal/run-repl" \
		-p tjs__ \
		src/bundles/js/core/run-repl.js

src/bundles/c/core/worker-bootstrap.c: $(TJSC) src/js/worker/worker-bootstrap.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:internal/worker-bootstrap" \
		-p tjs__ \
		src/js/worker/worker-bootstrap.js

src/bundles/c/internal/path.c: $(TJSC) src/js/internal/path.js
	@mkdir -p $(dir $@)
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:internal/path" \
		-p tjs__internal_ \
		src/js/internal/path.js

core: src/bundles/c/core/polyfills.c src/bundles/c/core/no-ada/polyfills.c src/bundles/c/core/no-webcrypto/polyfills.c src/bundles/c/core/minimal/polyfills.c src/bundles/c/core/core.c src/bundles/c/core/run-main.c src/bundles/c/core/run-repl.c src/bundles/c/core/worker-bootstrap.c src/bundles/c/internal/path.c

# tjs:v8 has no source-level dependencies to bundle. Compile it directly so
# the native bootstrap and its bytecode can be built before npm dependencies
# are installed, while still keeping the generated C file under `make js`.
src/bundles/c/stdlib/v8.c: $(TJSC) src/js/stdlib/v8.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:v8" \
		-p tjs__ \
		src/js/stdlib/v8.js

src/bundles/c/stdlib/%.c: $(TJSC) src/bundles/js/stdlib/%.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:$(basename $(notdir $@))" \
		-p tjs__ \
		src/bundles/js/stdlib/$(basename $(notdir $@)).js

src/bundles/js/stdlib/%.js: src/js/stdlib/*.js src/js/stdlib/ffi/*.js src/js/stdlib/readline/*.js src/js/stdlib/utils.js
	$(ESBUILD) src/js/stdlib/$(notdir $@) \
		--bundle \
		--outfile=$@ \
		--external:tjs:* \
		--external:buffer \
		--external:crypto \
		$(ESBUILD_PARAMS_MINIFY) \
		$(ESBUILD_PARAMS_COMMON)

src/bundles/c/stdlib/%.c: $(TJSC) src/bundles/js/stdlib/%.js
	@mkdir -p $(basename $(dir $@))
	$(TJSC) -m \
		$(TJSC_PARAMS_STIP) \
		-o $@ \
		-n "tjs:$(basename $(notdir $@))" \
		-p tjs__ \
		src/bundles/js/stdlib/$(basename $(notdir $@)).js

stdlib: $(addprefix src/bundles/c/stdlib/, $(patsubst %.js, %.c, $(notdir $(STDLIB_MODULES))))

js: $(TJSC) core stdlib

install: $(TJS)
	cmake --build $(BUILD_DIR) --target install

clean: $(BUILD_DIR)
	cmake --build $(BUILD_DIR) --target clean

debug:
	BUILDTYPE=Debug $(MAKE)

distclean:
	@rm -rf $(BUILD_DIR)
	@rm -rf src/bundles/js/

format:
	clang-format -i src/*.{c,h}

lint:
	npm run lint

test:
	./$(BUILD_DIR)/tjs test tests/

test-advanced:
	cd tests/advanced && npm install
	./$(BUILD_DIR)/tjs --stack-size 10485760 test tests/advanced/

.PRECIOUS: src/bundles/js/core/%.js src/bundles/js/stdlib/%.js
.PHONY: all js debug install clean distclean format lint test test-advanced core stdlib $(TJS) $(TJSC)
