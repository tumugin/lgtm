// HEIF, the format iPhones save photos in, for the browsers that cannot read
// it themselves (Chrome and Firefox; Safari can): libheif over libde265,
// compiled to wasm by the Dockerfile's heif stage. A module of its own rather
// than part of lgtm.cpp, so that only a HEIF that needs it downloads it.

#include <emscripten/bind.h>
#include <emscripten/val.h>
#include <libheif/heif.h>

#include <string>

using namespace emscripten;

// The primary image as one RGBA canvas, rotated, mirrored and cropped the way
// the file says (as a browser shows it), or null when it cannot be read. The
// pixels are a fresh Uint8Array, copied out of the wasm heap.
val decode(const std::string& bytes) {
	val out = val::null();
	heif_context* ctx = heif_context_alloc();
	heif_image_handle* handle = nullptr;
	heif_image* image = nullptr;
	heif_decoding_options* options = heif_decoding_options_alloc();
	// 10-bit photos come out as 8 bits a channel like everything else.
	options->convert_hdr_to_8bit = 1;
	if (heif_context_read_from_memory_without_copy(ctx, bytes.data(), bytes.size(), nullptr).code == heif_error_Ok &&
	    heif_context_get_primary_image_handle(ctx, &handle).code == heif_error_Ok &&
	    heif_decode_image(handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, options).code == heif_error_Ok) {
		const int width = heif_image_get_width(image, heif_channel_interleaved);
		const int height = heif_image_get_height(image, heif_channel_interleaved);
		size_t stride = 0;
		const uint8_t* rgba = heif_image_get_plane_readonly2(image, heif_channel_interleaved, &stride);
		const size_t row = size_t(width) * 4;
		if (rgba && width > 0 && height > 0 && stride >= row) {
			// Rows may be padded in libheif's buffer; the copy is not.
			val data = val::global("Uint8Array").new_(row * height);
			for (int y = 0; y < height; y++)
				data.call<void>("set", val(typed_memory_view(row, rgba + y * stride)), y * row);
			out = val::object();
			out.set("width", width);
			out.set("height", height);
			out.set("data", data);
		}
	}
	heif_decoding_options_free(options);
	if (image) heif_image_release(image);
	if (handle) heif_image_handle_release(handle);
	heif_context_free(ctx);
	return out;
}

EMSCRIPTEN_BINDINGS(heif) {
	function("decode", &decode);
}
