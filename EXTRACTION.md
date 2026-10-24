# How we extracted the data from the video

This file documents exactly how we turned a YouTube video into the two data
sources that the README was written from: **spoken audio** (transcribed) and
**on-screen text** (frames + OCR). Combining both is what lets us recover the
complete instructions — the audio explains *why*, while the frames capture the
exact terminal commands, code, and Xcode UI that the audio only references.

Source video: **WWDC26: "Run local agentic AI on the Mac using MLX" — Apple**
<https://www.youtube.com/watch?v=wykPErJ8M-8> (13:37, Apple Developer)

---

## Pipeline overview

```
YouTube URL
   │
   ├─(1) yt-dlp ──────────────► audio (m4a) ──(2) whisper ──► wwdc26_mlx.txt  (spoken words)
   │
   └─(1) yt-dlp ──────────────► video (mp4) ─(3) ffmpeg ───► 817 frames (jpg)
                                                                   │
                                                        (4) Apple Vision OCR (Swift)
                                                                   │
                                                                   ▼
                                                        frames_ocr.txt   (on-screen text)
```

## Step 1 — Download

**Tool:** [`yt-dlp`](https://github.com/yt-dlp/yt-dlp)

```bash
# Update to latest (YouTube changed its streaming protocol; the bundled
# 2025.06.30 version failed with "not available on this app"):
pip3 install -U --user yt-dlp

# Audio only (for transcription):
yt-dlp -f "bestaudio[ext=m4a]/bestaudio" -o "wwdc26_mlx.%(ext)s" \
  "https://www.youtube.com/watch?v=wykPErJ8M-8"

# Full video at up to 1080p (for frame extraction):
yt-dlp -f "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080]" \
  --merge-output-format mp4 -o "wwdc26_mlx.mp4" \
  "https://www.youtube.com/watch?v=wykPErJ8M-8"
```

Outputs: `wwdc26_mlx.m4a` (12.6 MB) and `wwdc26_mlx.mp4` (33 MB).

## Step 2 — Transcribe audio

**Tool:** OpenAI [`whisper`](https://github.com/openai/whisper) (installed via
Homebrew; the system also has `mlx-whisper`, which runs the same models locally
on Apple Silicon and is faster — swap `whisper` for `mlx_whisper` if you prefer
fully-local transcription).

```bash
whisper --model small --language en --output_format txt --output_dir . wwdc26_mlx.m4a
```

Notes:
- `--model small` is a good speed/accuracy balance for clear English speech.
  Use `--model medium` or `large` for higher accuracy (slower, more RAM).
- The result (`wwdc26_mlx.txt`) is timestamped line-by-line. Whisper
  mis-heard a few product names (e.g. "MLXLamp" → **MLX-LM**, "endcups" →
  endcaps); the OCR pass below disambiguated these.

## Step 3 — Extract frames

**Tool:** [`ffmpeg`](https://ffmpeg.org) (Homebrew)

```bash
mkdir -p frames
ffmpeg -y -i wwdc26_mlx.mp4 -vf "fps=1" -q:v 2 frames/frame_%04d.jpg
```

- `fps=1` → one frame per second (817 frames for 13:37).
- `-q:v 2` → high-quality JPEG (visually lossless for OCR, far smaller than PNG).

## Step 4 — OCR the frames (read on-screen text)

**Tool:** Apple's **Vision** framework (built into macOS — the engine behind
Live Text). It's the most accurate local OCR for terminal/code/Xcode text and
requires no install. We drive it from a small Swift CLI that OCRs a whole
directory in one process (compile once, loop over files — much faster than
invoking `swift` per image).

`scripts/ocr_all.swift` (compiled with `swiftc -O`):

```swift
import Foundation
import Vision
import ImageIO

func ocr(_ path: String) -> String {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
    var lines: [String] = []
    let req = VNRecognizeTextRequest { request, _ in
        guard let obs = request.results as? [VNRecognizedTextObservation] else { return }
        for o in obs { if let c = o.topCandidates(1).first { lines.append(c.string) } }
    }
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false   // keep code/paths verbatim
    req.recognitionLanguages = ["en-US"]
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    return lines.joined(separator: "\n")
}
// ... list *.jpg in a directory, OCR each, print "=== frame_XXXX.jpg ===" then text
```

Run:

```bash
swiftc -O scripts/ocr_all.swift -o scripts/ocr_all
scripts/ocr_all video/frames > video/frames_ocr.txt
```

Key settings:
- `recognitionLevel = .accurate` — use the slow, accurate mode (we want exact code).
- `usesLanguageCorrection = false` — critical for code/paths; autocorrect would mangle them.

### Alternative OCR paths (not used, for reference)

- **Tesseract** (`brew install tesseract`) — free, cross-platform, but noticeably
  worse than Vision on antialiased UI text.
- **A local vision-language model** (e.g. `mlx-community/Qwen3-VL-8B-Instruct-4bit`
  served through `mlx-vlm`) — would *describe* screenshots in natural language
  rather than transcribe exact text, so it's the wrong tool for recovering exact
  commands; keep Vision for that.

## Output files

| File | What it is |
|------|------------|
| `video/wwdc26_mlx.m4a` | Downloaded audio |
| `video/wwdc26_mlx.mp4` | Downloaded video (1080p) |
| `video/wwdc26_mlx.txt` | Whisper transcript (spoken words, timestamped) |
| `video/frames/frame_0001.jpg` … `frame_0817.jpg` | 1 fps frames |
| `video/frames_ocr.txt` | Vision OCR of every frame (18k+ lines) |
| `scripts/ocr_all.swift` | The Swift Vision OCR CLI |

## What each source contributed to the README

- **Audio transcript** gave the conceptual structure: the 4-layer stack
  (MLX → MLX-LM → MLX-LM server → agent), the "three steps" framing, the
  hardware story (neural accelerators, continuous batching, distributed
  inference), and the Xcode *steps* (Settings → Intelligence → Add Sub Provider
  → locally hosted → port 8080).
- **Frame OCR** gave the exact, copy-pasteable bits the audio did not spell out:
  the `pip install mlx-lm` / `mlx_lm.server --model …` commands, the `curl`
  smoke-test, the full OpenCode `opencode.json` (provider + `baseURL` +
  model id), and confirmation that the demo ran `mlx_lm.server` on port 8080.
