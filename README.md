# Snap

A minimalist iOS camera. Black screen, square frame, one button.

Every photo is 1:1, and every photo is graded through a single built-in film
look before it reaches the camera roll — what you see in the viewfinder is
what gets saved.

## Requirements

- Xcode 16 or later
- iOS 17 or later, on a real device (the simulator has no camera)

## Running it

Open `Snap.xcodeproj`, set your own team under **Signing & Capabilities**,
and run.

The bundle identifier is `com.laffan.snapsquarecamera`. Apple requires it to
be globally unique, so if it ever collides with something already registered,
change `PRODUCT_BUNDLE_IDENTIFIER` in both the Debug and Release
configurations. Anything under a reverse-DNS prefix you control works;
`com.example.*` does not, as Apple will not register it to anyone.

## How it works

The preview is not `AVCaptureVideoPreviewLayer`. A preview layer shows the raw
sensor feed, which would mean composing against one image and saving another.
Instead `AVCaptureVideoDataOutput` hands each frame to Core Image, the look is
applied, and the result is drawn into an `MTKView`. Stills come from
`AVCapturePhotoOutput` and go through the same crop and the same look at full
resolution.

| File | Role |
| --- | --- |
| `Look/PositiveFilmProfile.swift` | The look, written in Lightroom slider units. **Edit this to change the grade.** |
| `Look/PositiveFilmFilter.swift` | Bakes the profile into a 3D LUT and applies the Core Image chain |
| `Look/ColorMath.swift` | HSV conversion, tone curves, vibrance |
| `Camera/CameraModel.swift` | Capture session, shutter, save |
| `Camera/CIImage+Square.swift` | The centred 1:1 crop shared by preview and capture |
| `Views/PreviewRenderer.swift` | Draws graded frames into Metal |

### The look

An approximation of the Ricoh GR II *Positive Film* image control: punchy
midtone contrast, recovered highlights, slightly lifted matte blacks, crushed
yellows and greens shifted toward aqua, reds and blues held or pushed, and
magentas taken almost out.

Everything that is a pure function of colour — camera calibration, contrast,
vibrance, the eight-band HSL mixer, the tone curve — is baked once into a 64³
lookup table at launch. That collapses the whole grade into one texture fetch
per pixel, so it costs the same whether the chain is simple or elaborate, and
it guarantees the preview and the saved file are doing identical maths.

The two stages that are *not* per-pixel stay as real filters either side of the
LUT: highlight/shadow recovery, and clarity as a wide, low-amplitude unsharp
mask. The unsharp radius is a fraction of the image's short edge rather than a
fixed pixel count, which is what keeps the 1080px preview and the
full-resolution capture looking like the same photograph.

One deliberate deviation from the source profile: it lists Green as Hue −35 but
annotates it *"shift toward aqua/blue"*, and in Lightroom a negative green hue
moves toward yellow. The teal-shifted foliage is the defining half of this
look, so the stated intent wins. See the comment in `PositiveFilmProfile.swift`.

## Deliberately not here

Front camera, flash, zoom, focus tap, grid, gallery, settings. The capture
screen is a preview and a button.

RAW capture is the next thing.
