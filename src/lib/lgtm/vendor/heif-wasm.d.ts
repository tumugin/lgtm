// Types for heif-wasm.js beside this file, built from wasm/heif.cpp by the
// Dockerfile's heif stage (locally: scripts/build-wasm.sh). Written by hand:
// keep in step with the bindings there.

/** A still image as one RGBA canvas. */
export type DecodedImage = {
  width: number;
  height: number;
  data: Uint8Array<ArrayBuffer>;
};

export type HeifWasm = {
  /** The primary image, turned the way the file says, or null if unreadable. */
  decode(bytes: Uint8Array): DecodedImage | null;
};

declare const factory: (options?: {
  locateFile?: (path: string) => string;
}) => Promise<HeifWasm>;
export default factory;
