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
| `Look/PositiveFilmProfile.swift` | The look, written in Lightroom slider units. **Edit this to change the defaults.** |
| `Look/PositiveFilmFilter.swift` | Bakes the profile into a 3D LUT and applies the Core Image chain |
| `Look/LookModel.swift` | Holds the live profile and keeps a baked filter in step with it |
| `Look/ColorMath.swift` | HSV conversion, tone curves, black point, vibrance |
| `Camera/CameraModel.swift` | Capture session, shutter, save |
| `Camera/CIImage+Square.swift` | The centred 1:1 crop shared by preview and capture |
| `Presets/PresetStore.swift` | Saved looks on disk, and the zip bundle |
| `Views/FilterPanel.swift` | The slider editor and its action bar |
| `Views/PreviewRenderer.swift` | Draws graded frames into Metal |

## The filter editor

**Filter** (bottom right) replaces the lower half of the screen with every knob
the look exposes, grouped the way Lightroom groups them — Basic, Tone Curve,
Color Mixer, Calibration, Grain. Moving a slider regrades the live preview.
Double-tap any slider to return it to neutral.

A sticky bar sits under the sliders:

| Button | Does |
| --- | --- |
| **Snap** | Same as the shutter — graded photo to the camera roll |
| **Save** | Captures a frame *and* the settings that made it, then asks for a title (defaults to the timestamp) and notes |
| **Load** | Saved looks as cards, newest first. Tap to put one back on the sliders; swipe to delete |
| **Bundle** | Zips every saved image and settings file and hands it to the share sheet |

Save and Snap are deliberately different: Snap goes to the camera roll, Save
goes to the app's own store so Bundle has something to collect. Saved entries
live in `Documents/Snaps` as a matched `<uuid>.json` and `<uuid>.heic` per
entry — flat and readable, which is why Bundle is just a zip of the folder.

### Keeping sliders responsive

Re-baking a 64³ LUT on every frame of a drag is too slow, so a drag bakes at
32³ and releasing the slider commits a 64³ bake; captures always force the full
resolution regardless. The split is measured, not guessed. Against the exact
per-pixel grade, 64³ holds worst-case error to ~1.8/255 (mean 0.1/255) with a
neutral ramp inside 0.3/255; 32³ roughly triples that. The error is a smooth
shift rather than a step, so it shows up as a faint tint on one hue, never as
banding.

Bakes are coalesced: during a drag many requests pile up behind one bake, and
only the newest survives.

### The look

An approximation of the Ricoh GR II *Positive Film* image control: punchy
midtone contrast, recovered highlights, a crushed black point under lifted
shadows, crushed yellows and greens shifted toward aqua, reds and blues held or
pushed, magentas taken almost out, and a fine grain over the whole frame.

Everything that is a pure function of colour — camera calibration, contrast,
vibrance, the eight-band HSL mixer, the tone curve — is baked once into a 64³
lookup table at launch. That collapses the whole grade into one texture fetch
per pixel, so it costs the same whether the chain is simple or elaborate, and
it guarantees the preview and the saved file are doing identical maths.

The stages that are *not* per-pixel stay as real filters around the LUT:
highlight/shadow recovery, clarity as a wide low-amplitude unsharp mask, and
grain. Both the unsharp radius and the grain size are fractions of the image
rather than fixed pixel counts, which is what keeps the 1080px preview and the
full-resolution capture looking like the same photograph.

Grain is blended in `overlay`, which earns its keep: a foreground of exactly
0.5 is a no-op, and the response scales with `2 × backdrop` in the shadows and
`2 × (1 − backdrop)` in the highlights. So grain peaks in the midtones and
fades at both ends the way film does, with no mask. At the default amount that
is 2.4% deviation at midtone against 0.1% at either extreme.

One deliberate deviation from the source profile: it lists Green as Hue −35 but
annotates it *"shift toward aqua/blue"*, and in Lightroom a negative green hue
moves toward yellow. The teal-shifted foliage is the defining half of this
look, so the stated intent wins. See the comment in `PositiveFilmProfile.swift`.

## Deliberately not here

Front camera, flash, zoom, focus tap, grid, gallery. The capture screen is a
preview and a button.

RAW capture is the next thing.
