/// <reference lib="webworker" />
/**
 * First half of turning a picture into an LGTM image: decode it, fit it within
 * 960px, and lay the LGTM mark over every frame. Each finished frame goes
 * straight to the encoding worker, which compresses it while this one is
 * already making the next.
 *
 * GIFs and animated WebP are decoded by giflib and libwebp (wasm); anything
 * else by the browser's own createImageBitmap, which also honours the EXIF
 * orientation of a photo. A HEIF (an iPhone photo) that the browser cannot
 * read -- Chrome and Firefox cannot, Safari can -- goes to libheif (wasm).
 * Resizing and the overlay are plain canvas drawing.
 */
import lgtmUrl from "../assets/lgtm.webp?url";
import type { Ack, Connect, Job, ToEncoder } from "./protocol";
import heifFactory, { type HeifWasm } from "./vendor/heif-wasm.js";
import heifWasmUrl from "./vendor/heif-wasm.wasm?url";
import { loadWasm } from "./wasm";

/** Longest side of what gets stored. */
const MAX_SIDE = 960;
/**
 * Frames sent but not yet taken by the encoder. Decoding outruns encoding, and
 * without a limit a long animation would pile up in the encoder's queue at
 * about 1MB a frame.
 */
const WINDOW = 4;

let port: MessagePort | undefined;
let inFlight = 0;
let freed: (() => void) | undefined;

const send = (msg: ToEncoder, transfer: Transferable[] = []) =>
  port?.postMessage(msg, transfer);

async function sendFrame(
  id: number,
  rgba: Uint8Array<ArrayBuffer>,
  duration: number,
) {
  while (inFlight >= WINDOW) await new Promise<void>((r) => (freed = r));
  inFlight += 1;
  send({ type: "frame", id, rgba: rgba.buffer, duration }, [rgba.buffer]);
}

let lgtm: Promise<ImageBitmap> | undefined;
const loadLgtm = () => {
  lgtm ??= fetch(lgtmUrl)
    .then((r) => r.blob())
    .then((b) => createImageBitmap(b));
  return lgtm;
};

// Downloaded only when a HEIF turns up that the browser cannot read.
let heif: Promise<HeifWasm> | undefined;
const loadHeif = () => {
  heif ??= heifFactory({ locateFile: () => heifWasmUrl });
  return heif;
};

/** Fits the source within MAX_SIDE and draws the mark on top. */
class Stamper {
  readonly width: number;
  readonly height: number;
  #ctx: OffscreenCanvasRenderingContext2D;
  #mark: ImageBitmap;

  constructor(srcWidth: number, srcHeight: number, mark: ImageBitmap) {
    const scale = Math.min(1, MAX_SIDE / srcWidth, MAX_SIDE / srcHeight);
    this.width = Math.max(1, Math.round(srcWidth * scale));
    this.height = Math.max(1, Math.round(srcHeight * scale));
    const ctx = new OffscreenCanvas(this.width, this.height).getContext("2d", {
      willReadFrequently: true,
    });
    if (!ctx) throw new Error("no 2d context");
    ctx.imageSmoothingQuality = "high";
    this.#ctx = ctx;
    this.#mark = mark;
  }

  stamp(source: CanvasImageSource): Uint8Array<ArrayBuffer> {
    const { width, height } = this;
    const ctx = this.#ctx;
    ctx.clearRect(0, 0, width, height);
    ctx.drawImage(source, 0, 0, width, height);
    // The mark is scaled to fit the picture and centred, keeping its own
    // proportions: what sharp's resize(fit: "contain") then composite did.
    const mark = this.#mark;
    const k = Math.min(width / mark.width, height / mark.height);
    const w = mark.width * k;
    const h = mark.height * k;
    ctx.drawImage(mark, (width - w) / 2, (height - h) / 2, w, h);
    const { data } = ctx.getImageData(0, 0, width, height);
    return new Uint8Array(data.buffer);
  }
}

const isGif = (b: Uint8Array) =>
  b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38; // "GIF8"

/** Extended-format WebP with the animation flag set in its VP8X header. */
const isAnimatedWebP = (b: Uint8Array) => {
  const tag = (at: number) => String.fromCharCode(...b.subarray(at, at + 4));
  return (
    b.length > 21 &&
    tag(0) === "RIFF" &&
    tag(8) === "WEBP" &&
    tag(12) === "VP8X" &&
    (b[20] & 0x02) !== 0
  );
};

/**
 * HEIF holding HEVC, as iPhones save photos: an ISO BMFF file whose leading
 * `ftyp` box lists "heic" or "heix" among its brands.
 */
const isHeic = (b: Uint8Array) => {
  const tag = (at: number) => String.fromCharCode(...b.subarray(at, at + 4));
  if (b.length < 16 || tag(4) !== "ftyp") return false;
  // The box: its size, "ftyp", the major brand, a version, then compatible
  // brands to the end of the box.
  const size = new DataView(b.buffer, b.byteOffset, b.byteLength).getUint32(0);
  const brands = [tag(8)];
  for (let at = 16; at + 4 <= Math.min(size, b.length); at += 4)
    brands.push(tag(at));
  return brands.some((brand) => brand === "heic" || brand === "heix");
};

/** A HEIF decoded by libheif, for a browser that cannot read it itself. */
async function decodeHeic(bytes: Uint8Array) {
  const image = (await loadHeif()).decode(bytes);
  if (!image) throw new Error("undecodable image");
  return createImageBitmap(
    new ImageData(
      new Uint8ClampedArray(image.data.buffer),
      image.width,
      image.height,
    ),
  );
}

async function convert({ id, file }: Job) {
  const mark = await loadLgtm();
  const bytes = new Uint8Array(await file.arrayBuffer());

  if (isGif(bytes) || isAnimatedWebP(bytes)) {
    const wasm = await loadWasm();
    const dec = isGif(bytes)
      ? new wasm.GifDecoder(bytes)
      : new wasm.WebPDecoder(bytes);
    try {
      if (!dec.ok()) throw new Error("undecodable image");
      const width = dec.width();
      const height = dec.height();
      const stamper = new Stamper(width, height, mark);
      send({
        type: "begin",
        id,
        width: stamper.width,
        height: stamper.height,
        frames: dec.frameCount(),
      });
      const ctx = new OffscreenCanvas(width, height).getContext("2d");
      if (!ctx) throw new Error("no 2d context");
      for (let f = dec.next(); f; f = dec.next()) {
        ctx.putImageData(
          new ImageData(new Uint8ClampedArray(f.data.buffer), width, height),
          0,
          0,
        );
        await sendFrame(id, stamper.stamp(ctx.canvas), f.duration);
      }
    } finally {
      dec.delete();
    }
  } else {
    const bitmap = await createImageBitmap(file).catch((e) => {
      if (!isHeic(bytes)) throw e;
      return decodeHeic(bytes);
    });
    const stamper = new Stamper(bitmap.width, bitmap.height, mark);
    send({
      type: "begin",
      id,
      width: stamper.width,
      height: stamper.height,
      frames: 1,
    });
    const rgba = stamper.stamp(bitmap);
    bitmap.close();
    await sendFrame(id, rgba, 0);
  }
  send({ type: "end", id });
}

// Jobs one after another, in the order they came.
let queue = Promise.resolve();

self.onmessage = ({ data }: MessageEvent<Connect | Job>) => {
  if (data.type === "connect") {
    port = data.port;
    port.onmessage = ({ data: ack }: MessageEvent<Ack>) => {
      if (ack.type !== "ack") return;
      inFlight -= 1;
      freed?.();
      freed = undefined;
    };
    return;
  }
  queue = queue.then(() =>
    convert(data).catch((e) =>
      send({
        type: "fail",
        id: data.id,
        error: e instanceof Error ? e.message : String(e),
      }),
    ),
  );
};
