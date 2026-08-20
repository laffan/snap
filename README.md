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
| `Views/FilterPanel.swift` | The slider editor, its menu, and the handle that resizes it |
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

Below the frame sit the lens dots, the exposure modes and **B&W** stacked down
the left, the shutter centred, and exposure on the right, with **Filter**
centred under all of it. The dots widen left to right the way the lenses do,
filled for the one in use, and sit above the modes because which lens is
looking comes before how it is metered; exposure steps in whole stops
and is the same value as the panel's Exposure slider — one setting reachable
two ways. It is a develop setting rather than a camera one, so it re-applies
when a negative is re-filtered and travels to Lightroom as `crs:Exposure2012`.

Tap a thumbnail to open it in the viewer, where the shutter becomes an **X**
that returns to the live preview. The camera controls go with the exposure
stepper while a saved frame is up: lens, mode and B&W all decide how the *next*
photograph is taken, and none of them applies to one that already exists.
Long-press for **Use Filter Data** (puts that shot's settings back on the
sliders), **Share JPEG**, **Share RAW** (only when the capture was RAW), or
**Delete Image**.

Two kinds of frame are marked in the corner of their thumbnail: a dot for one
taken with **PS**, and a square for one made in the filter screen — a
re-filtered negative, or a capture from the panel's own menu. Everything else
came off the shutter.

## Exposure

Two of the three classic modes mean something on a phone. An iPhone lens has a
fixed iris — `AVCaptureDevice.lensAperture` is read-only because there is
nothing to move — so aperture priority would be indistinguishable from auto,
and nothing sits where that button would be. The f-number was shown there for a
while as a readout; a number that never changes doesn't earn a place among
controls that do.

**S** pins the shutter and lets ISO follow. iOS has no shutter-priority mode of
its own: `setExposureModeCustom(duration:iso:)` fixes both. So priority is
built on top of it — the shutter is held and ISO is nudged toward the meter,
using `exposureTargetOffset`, which reports its error in stops, exactly the
units ISO scales in.

**M** pins both and lets the meter drift. Selecting it borrows whatever ISO the
camera had arrived at rather than jumping to an arbitrary number.

Tapping the lit mode returns to auto. The rows of values appear under the frame
for whichever mode is deciding them — S shows shutter, M shows both — and the
offered stops are trimmed to what the active lens and format actually accept.
ISO also has a readout under the exposure stepper, with AUTO at the top of its
list; it and the M row edit the same value.

### The meter, and what the preview can't tell you

Exposure itself needs no simulating. There is one session and one device input,
and `setExposureModeCustom` is set on the *device*, so the preview stream and
the still are exposed identically — choosing a fast shutter at low ISO in dim
light darkens the preview by exactly the amount it darkens the photograph.

Two things still differ, and neither can be previewed away. The preview is a
binned frame that has been through Apple's video noise reduction, while the
still is full-resolution RAW with every noise-reduction knob at zero — so a
high-ISO frame will be grainier than the preview promises. And the still is
one exposure where the preview is a stream, so a slow shutter's blur only
partly shows.

Rather than guess at those, Snap does what a camera does and meters. The EV
readout under the frame is `exposureTargetOffset`: how far the chosen settings
sit from what the meter wants, in stops, negative for under. It appears only
when the exposure is being driven by hand, since auto holds it at zero. Past
half a stop it brightens; past a stop and a half it turns yellow.

Video HDR is switched off for the same reason. Left on, the video stream gets
local tone mapping the still explicitly does not, so the preview would show
recovered highlights and lifted shadows the negative never had.

Holding to focus moves focus only. Choosing what is sharp and choosing what is
bright are separate decisions, and the exposure controls own the second.

A rule-of-thirds guide sits over the live preview. Holding anywhere on it for
a second pins focus to that point and marks it with a yellow ring; any tap lets
it go again. Switching lens releases the point too, since it
means nothing on another lens.

A monochrome frame stays monochrome. Loading one for re-filtering switches
B&W on and locks it: the colour it was rendered without isn't in the JPEG, and
re-filtering it back to colour would quietly produce a different photograph
from the one that was taken. Exporting the DNG still gets you the colour.
Ending the session only puts B&W back the way it was if loading the negative
is what turned it on.

Preview frames have no negative, so they can't be re-filtered — they show
dimmed in the panel's roll and don't respond to a tap. Their menu still works;
they can be shared, deleted, or have their settings borrowed.

**PS** beside the shutter saves the preview frame itself, skipping the RAW loop
entirely — no sensor round trip, no demosaic, no full-resolution grade, since
the graded frame is already on screen. It is as close to zero shutter lag as
the app gets, at the cost of coming out at preview resolution with no negative
behind it.

**B&W** renders the frame monochrome, and the conversion happens at the *end*
of the grade rather than the start — so the colour mixer still shapes it, the
way a black-and-white mixer does: desaturating a band changes that band's
luminance. The negative keeps its colour data, since this is how the frame is
rendered rather than what was recorded, but peeking at it behind a monochrome
look shows it desaturated so the two are comparable.

Storing full-resolution copies is what makes Bundle and Share work on the
original file rather than a thumbnail; it also means the app's storage grows
with use, and Delete is the way to reclaim it.

## Re-filtering a negative

The roll also lives inside the filter panel. Tapping a frame there loads its
negative under the sliders in place of the live camera, and moving a slider
regrades it as you go — the label under the frame reads VERSION while this is
happening, and holding the frame peeks at the ungraded development the same way
the saved-frame viewer does. Tapping the same frame again hands the viewer back to the camera.

**Snap** becomes **Version** while a negative is loaded, and runs the same
pipeline the shutter does — develop, crop, grade, encode, square the DNG,
embed the settings — over the stored sensor data instead of the sensor. The
result is a new shot in its own right, not an edit of the old one, which is
why both share `prepareNegative`: a captured file and a re-filtered one should
be indistinguishable apart from where the photons came from.

Re-grading is cheap because the negative is demosaiced once at viewer size and
kept; only the **Apple Tone Curve** slider feeds the RAW pipeline itself, so
only that one costs a re-develop.

## The filter editor

**Filter**, centred under the shutter, replaces the lower half of the screen
with every knob the look exposes, grouped the way Lightroom groups them —
Basic, Tone Curve, Color Mixer, Calibration, RAW. Moving a slider regrades the
live preview. Double-tap any slider to return it to neutral.

The panel's own actions hang off a menu beside the **Filter** title:

| Item | Does |
| --- | --- |
| **Snap** / **Version** | Same as the shutter, or re-filters the loaded negative |
| **Save** | The same, then asks for a title (defaults to the timestamp) and notes |
| **Load** | Every shot as a card, newest first. Tap to put its settings back on the sliders; swipe to delete |
| **Bundle** | Zips every image and settings file and hands it to the share sheet |

Snap and Save both capture, store, and save to the camera roll — the only
difference is that Save ends at the naming sheet. Both mark the frame as made
in the filter screen, so the roll shows where it came from.

These four were a bar across the bottom of the panel. They are pressed once or
twice a session, and forty sliders wanted the row more than they did.

### Trading preview for panel

A handle sits at the centre of the panel's header. Dragging it up pulls the
panel over the preview, and the square gives up exactly what the panel gains,
which keeps the frame square while it shrinks. The drag stops at 45% of the
width — past that the viewfinder has stopped being one. Closing the panel hands
the whole square back.

### Copy Adjustments

At the foot of the sliders, **Copy Adjustments** puts everything that has moved
off the built-in look on the clipboard, one setting per line, each named the way
its slider is. Settings still sitting at their default are left out, so what
lands in a note is the *difference* — which is what a look is, and what would be
pasted back into `PositiveFilmProfile.swift` to make it the new default. The
button reads Nothing Adjusted while there is no difference to copy.

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

## Lock screen

`SnapWidgets` is a widget extension carrying two ways onto the lock screen,
because iOS grew a second one:

- **A circular accessory widget** that sits under the clock. Long-press the
  lock screen ▸ Customise ▸ Lock Screen, tap the row under the time, and add
  Snap. Works from iOS 16.
- **A control**, from iOS 18, which can take the place of the camera or
  flashlight button in the bottom corners — the fastest route from a dark
  screen to a photograph. Long-press the lock screen ▸ Customise ▸ Lock
  Screen, tap the button you want to replace, and pick Snap. It also appears
  in Control Centre and can be bound to the Action Button.

Neither does anything but launch the app. The control's `OpenSnapIntent` has
no body: `openAppWhenRun` is the whole mechanism, carrying the tap from the
extension to the app.

The extension ships inside the app, so there is nothing extra to install — its
bundle identifier is the app's with `.widgets` on the end, and it has to share
the same signing team.

Its `Info.plist` lives in `Config/`, not beside the sources. A
`PBXFileSystemSynchronizedRootGroup` sweeps in *every* file under its folder,
so a plist left in `SnapWidgets/` gets copied as a bundle resource as well as
processed as the target's Info.plist — two build tasks writing the same output.
Keeping it outside the synchronised folder is what stops that; the same applies
to anything else added there that isn't source.

## Deliberately not here

Front camera, flash, zoom, focus tap, grid. The capture screen is a preview, a
button, and the roll.

Film noise is coming back later.
