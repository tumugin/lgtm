# The wasm the browser uses to make LGTM images: our bindings (wasm/lgtm.cpp)
# over libwebp and giflib, with wasm SIMD on, and HEIF in a module of its own
# (the heif stage below). Built here rather than committed;
# scripts/build-wasm.sh builds the wasm-out stage to get the same files for
# local development.
#
# -msimd128 enables wasm SIMD, and -msse2/-msse4.1 make libwebp compile its
# SSE code paths, which Emscripten turns into wasm SIMD. libwebp's CMake check
# finds SSE4.1 under Emscripten but not SSE2, and the SSE4.1 code needs the SSE2
# helpers, so both are switched on explicitly. Sources are pinned to exact
# commits.
FROM emscripten/emsdk:7.0.1 AS wasm
WORKDIR /tmp
ENV FLAGS="-O3 -msimd128 -msse2 -msse4.1"
# The libraries are built before wasm/ is copied in, so they stay cached while
# lgtm.cpp changes and an edit there re-runs only the final link.
# libwebp v1.6.0.
RUN git clone -q https://github.com/webmproject/libwebp.git libwebp \
	&& git -C libwebp checkout -q 4fa21912338357f89e4fd51cf2368325b59e9bd9 \
	&& emcmake cmake -S libwebp -B libwebp/build \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_FLAGS="$FLAGS -DWEBP_HAVE_SSE2 -DWEBP_HAVE_SSE41" \
		-DCMAKE_DISABLE_FIND_PACKAGE_Threads=1 \
		-DWEBP_ENABLE_SIMD=ON \
		-DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
		-DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF \
		-DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_EXTRAS=OFF \
		-DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_ANIM_UTILS=OFF >/dev/null \
	&& make -s -C libwebp/build -j"$(nproc)" webp sharpyuv webpmux webpdemux >/dev/null
# giflib 6.1.3, only its decoding half.
RUN git clone -q https://git.code.sf.net/p/giflib/code giflib \
	&& git -C giflib checkout -q edff4aed17f857442ab0cac31566572ba08f93d3 \
	&& for f in dgif_lib gifalloc gif_err gif_hash openbsd-reallocarray; do \
		emcc -c $FLAGS -I giflib -o giflib/$f.o giflib/$f.c || exit 1; \
	done
COPY wasm/ /src/
# The prepended line keeps svelte-check out of the generated code; its types
# are src/lib/lgtm/vendor/lgtm-wasm.d.ts, written by hand to follow lgtm.cpp.
RUN mkdir /out \
	&& em++ $FLAGS -std=c++17 -lembind \
		-I libwebp/src -I giflib \
		-s EXPORT_ES6=1 -s MODULARIZE=1 -s ENVIRONMENT=worker \
		-s ALLOW_MEMORY_GROWTH=1 -s MAXIMUM_MEMORY=4GB \
		-o /out/lgtm-wasm.js \
		/src/lgtm.cpp giflib/*.o \
		libwebp/build/libwebp.a libwebp/build/libsharpyuv.a \
		libwebp/build/libwebpmux.a libwebp/build/libwebpdemux.a \
	&& { printf '// @ts-nocheck\n'; cat /out/lgtm-wasm.js; } > /out/lgtm-wasm.js.tmp \
	&& mv /out/lgtm-wasm.js.tmp /out/lgtm-wasm.js

# HEIF (iPhone photos) for the browsers that cannot read it themselves:
# libheif over libde265, bound in wasm/heif.cpp. A module of its own, so that
# converting anything else never downloads it. libde265's SSE code is not
# built: its CMake looks for an x86 target, which wasm is not.
FROM emscripten/emsdk:7.0.1 AS heif
WORKDIR /tmp
ENV FLAGS="-O3 -msimd128"
# libde265 v1.1.3, the library alone.
RUN git clone -q https://github.com/strukturag/libde265.git libde265 \
	&& git -C libde265 checkout -q ba62bf4cfb3242f3bf0a45617ff09e35236e4d82 \
	&& emcmake cmake -S libde265 -B libde265/build \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
		-DCMAKE_INSTALL_PREFIX=/tmp/heif \
		-DBUILD_SHARED_LIBS=OFF -DENABLE_SDL=OFF -DENABLE_DECODER=OFF >/dev/null \
	&& make -s -C libde265/build -j"$(nproc)" install >/dev/null
# libheif v1.23.7, reading HEVC through libde265 and nothing else. Built by
# Emscripten it binds its own JS API into the library; the standalone define
# leaves that out, heif.cpp being the binding here.
RUN git clone -q https://github.com/strukturag/libheif.git libheif \
	&& git -C libheif checkout -q 12a259a5882dd99d45ec5fc77e296a3b620d1e2e \
	&& emcmake cmake -S libheif -B libheif/build \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_FLAGS="$FLAGS -D__EMSCRIPTEN_STANDALONE_WASM__" \
		-DCMAKE_CXX_FLAGS="$FLAGS -D__EMSCRIPTEN_STANDALONE_WASM__" \
		-DCMAKE_INSTALL_PREFIX=/tmp/heif \
		-DBUILD_SHARED_LIBS=OFF -DENABLE_PLUGIN_LOADING=OFF \
		-DENABLE_MULTITHREADING_SUPPORT=OFF \
		-DLIBDE265_INCLUDE_DIR=/tmp/heif/include \
		-DLIBDE265_LIBRARY=/tmp/heif/lib/libde265.a \
		-DWITH_X265=OFF -DWITH_X264=OFF -DWITH_OpenH264_DECODER=OFF \
		-DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_LIBSHARPYUV=OFF \
		-DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF -DBUILD_TESTING=OFF >/dev/null \
	&& make -s -C libheif/build -j"$(nproc)" install >/dev/null
COPY wasm/heif.cpp /src/
RUN mkdir /out \
	&& em++ $FLAGS -std=c++17 -lembind -I /tmp/heif/include \
		-s EXPORT_ES6=1 -s MODULARIZE=1 -s ENVIRONMENT=worker \
		-s ALLOW_MEMORY_GROWTH=1 -s MAXIMUM_MEMORY=4GB \
		-o /out/heif-wasm.js \
		/src/heif.cpp /tmp/heif/lib/libheif.a /tmp/heif/lib/libde265.a \
	&& { printf '// @ts-nocheck\n'; cat /out/heif-wasm.js; } > /out/heif-wasm.js.tmp \
	&& mv /out/heif-wasm.js.tmp /out/heif-wasm.js

# Only lgtm-wasm.{js,wasm} and heif-wasm.{js,wasm}, for
# `--target wasm-out --output ...`.
FROM scratch AS wasm-out
COPY --from=wasm /out/ /
COPY --from=heif /out/ /

FROM oven/bun:1.4.5-slim AS base
WORKDIR /usr/src/app
EXPOSE 3000
ENV BODY_SIZE_LIMIT=100M

FROM base AS builder
ENV NODE_ENV=production
COPY package.json bun.lock ./
RUN bun i --frozen-lockfile
COPY . .
COPY --from=wasm-out / src/lib/lgtm/vendor/
# Declared after the source copy so it can't invalidate the dependency layers.
# Stamps the build into version.json, which open tabs poll to spot a rollout.
ARG APP_VERSION
ENV APP_VERSION=$APP_VERSION
RUN bun run build
# The runtime stage has no shell, so the directories the PVCs mount over are
# made here and copied across with the owner they need.
RUN mkdir -p /out/data /out/images

# Distroless Bun: no shell or package manager, only the runtime and the glibc,
# CA certificates and tzdata it needs. Runs as 1000:1000, the uid of the slim
# image's bun user, so the existing PVCs stay writable.
FROM oven/bun:1.4.5-distroless
WORKDIR /usr/src/app
EXPOSE 3000
ENV BODY_SIZE_LIMIT=100M
USER 1000:1000
# No node_modules: the server has no runtime dependencies left. Images are
# converted in the browser, and everything else is bundled into build/.
COPY --from=builder --chown=1000:1000 /out/ ./
COPY --from=builder --chown=1000:1000 /usr/src/app/package.json ./package.json
COPY --from=builder --chown=1000:1000 /usr/src/app/build ./build
# The entrypoint is bun itself (the base image's too); spelled out so CMD is
# only the arguments.
ENTRYPOINT ["/usr/local/bin/bun"]
CMD ["./build"]
