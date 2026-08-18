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
| `Camera/PhotoEncoder.swift` | JPEG encoding, and the settings embedded in EXIF |
| `Camera/RAWDeveloper.swift` | Demosaics RAW with Apple's processing switched off |
| `Library/ShotStore.swift` | Every shot on disk, and the zip bundle |
| `Views/FilmStrip.swift` | The app's own roll along the bottom edge |
| `Views/FilterPanel.swift` | The slider editor and its action bar |
| `Views/PreviewRenderer.swift` | Draws graded frames into Metal |

## RAW

With **Capture RAW** on, Snap asks the sensor for Bayer RAW and develops it
itself through `CIRAWFilter`, with Apple's cosmetic processing switched off —
luminance and colour noise reduction, sharpening, detail enhancement, contrast,
moiré reduction, local tone mapping and gamut mapping all set to zero. The look
is then applied to *that*, rather than to a JPEG Apple has already finished.

Bayer rather than Apple ProRAW on purpose: ProRAW arrives demosaiced and
already carrying Apple's rendering, which is the thing being stepped around.

Worth being clear about what RAW can and can't mean here. A DNG holds
undemosaiced sensor data, so there is no way to write a grade *into* one — the
look would have to survive being re-mosaiced, which throws away most of what it
did. So the grade moves to the other end of the pipeline instead: the sensor
data is developed here, graded here, and written out as JPEG.

The DNG is kept in the app's store next to the JPEG, where the roll can share
it and Bundle carries it.

### The negative opens cropped and graded

A `.xmp` sidecar is written beside every DNG carrying Camera Raw settings, so
the negative opens in Lightroom already square and already wearing the look.

This is the payoff for keeping the profile in Lightroom slider units from the
start: `crs:` properties take those numbers directly. Contrast 28 becomes
`crs:Contrast2012="28"`, the Green band's teal shift becomes
`crs:HueAdjustmentGreen="35"`, the blue primary becomes `crs:BlueHue` and
`crs:BlueSaturation`. Only two stages need converting — the tone curve is
sampled into `crs:ToneCurvePV2012` control points, and the square becomes the
`crs:Crop*` fractions.

**Share RAW sends the DNG and its sidecar together.** Apart they mean nothing;
Adobe finds the sidecar by matching base names in the same folder.

Snap still tries to write the square into the DNG itself first, by narrowing
its `DefaultCropOrigin`/`DefaultCropSize` — that holds in every converter, not
just Adobe's, and no pixel moves. Whether iOS will author a DNG container is
not something to assume, so the write is attempted and the *outcome* reported
in the RAW section of the filter panel. When it fails, the crop rides in the
sidecar instead and the two never both apply, which would otherwise crop twice.

What the sidecar cannot do is reach a reader that doesn't look for one. Apple
Photos and Preview show the full frame, and Lightroom mobile expects settings
embedded in the DNG rather than beside it. Lightroom Classic, Camera Raw,
Bridge and Capture One all read it; in Classic, *Metadata ▸ Read Metadata from
File* forces the issue if an import misses it.

The rendering will be close but not identical to the JPEG — same slider values,
but Adobe's demosaic, camera profile and slider implementations are their own. Only the graded JPEG goes to the camera
roll. Attaching the negative to the camera-roll asset as an alternate resource
would be the tidier arrangement, but `PHAssetCreationRequest` will not accept a
RAW alternate as raw bytes — it returns `PHPhotosError.invalidResource` — and
writing a second copy of tens of megabytes per shot to work around that isn't
worth it. **A DNG runs to tens of megabytes, so with RAW on the store grows
quickly; Delete on a thumbnail is how to reclaim it.**

### The one control that isn't zeroed

**Apple Tone Curve** maps onto `CIRAWFilter.boostAmount`, and it defaults to 0
— the fullest bypass the API offers, giving a linear response to the scene.

That has a visible consequence: the live preview is fed by
`AVCaptureVideoDataOutput`, which has no RAW equivalent, so the preview always
shows Apple-processed frames. At a boost of 0 a RAW capture therefore starts
flatter than what the preview showed. Raising the slider trades bypass for
agreement with the preview; 100 is Apple's own rendering. Everything else on
the list above stays off regardless.

## Every photo carries its settings

Captures are JPEG, and each one is written with the profile that made it in
the EXIF user comment (about 750 bytes of JSON, ~1% of what an EXIF block
holds), alongside the camera's own exposure and lens metadata. That happens on
every shot whether or not the filter editor was ever opened, so any file
leaving the app — camera roll, share sheet, bundle — describes itself.

The profile decodes leniently: a key that isn't in the JSON keeps its default
instead of failing the whole decode, so shots saved by an older build still
load after new knobs are added.

## The roll

Every capture is written twice: to the camera roll, and to the app's own store
in `Documents/Snaps` as a matched `<uuid>.jpg` and `<uuid>.json`. The strip
along the bottom edge reads the store, which is why it shows only frames Snap
took. It holds 20 at a time with **Load More** for the rest.

Tap a thumbnail to open it in the viewer, where the shutter becomes an **X**
that returns to the live preview. Long-press for **Use Filter Data** (puts that
shot's settings back on the sliders), **Share JPEG**, **Share RAW** (only when
the capture was RAW), or **Delete Image**.

Storing full-resolution copies is what makes Bundle and Share work on the
original file rather than a thumbnail; it also means the app's storage grows
with use, and Delete is the way to reclaim it.

## The filter editor

**Filter** (bottom right) replaces the lower half of the screen with every knob
the look exposes, grouped the way Lightroom groups them — Basic, Tone Curve,
Color Mixer, Calibration, RAW. Moving a slider regrades the live preview.
Double-tap any slider to return it to neutral.

A sticky bar sits under the sliders:

| Button | Does |
| --- | --- |
| **Snap** | Same as the shutter |
| **Save** | Takes a shot and then asks for a title (defaults to the timestamp) and notes |
| **Load** | Every shot as a card, newest first. Tap to put its settings back on the sliders; swipe to delete |
| **Bundle** | Zips every image and settings file and hands it to the share sheet |

Snap and Save both capture, store, and save to the camera roll — the only
difference is that Save ends at the naming sheet.

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
pushed, and magentas taken almost out.

Everything that is a pure function of colour — camera calibration, contrast,
vibrance, the eight-band HSL mixer, the tone curve — is baked once into a 64³
lookup table at launch. That collapses the whole grade into one texture fetch
per pixel, so it costs the same whether the chain is simple or elaborate, and
it guarantees the preview and the saved file are doing identical maths.

The stages that are *not* per-pixel stay as real filters around the LUT:
highlight/shadow recovery, and clarity as a wide low-amplitude unsharp mask.
The unsharp radius is a fraction of the image's short edge rather than a fixed
pixel count, which is what keeps the 1080px preview and the full-resolution
capture looking like the same photograph.


One deliberate deviation from the source profile: it lists Green as Hue −35 but
annotates it *"shift toward aqua/blue"*, and in Lightroom a negative green hue
moves toward yellow. The teal-shifted foliage is the defining half of this
look, so the stated intent wins. See the comment in `PositiveFilmProfile.swift`.

## Deliberately not here

Front camera, flash, zoom, focus tap, grid. The capture screen is a preview, a
button, and the roll.

Film noise is coming back later.
