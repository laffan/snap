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
| `Look/SubProfile.swift` | Indoor and Night, laid over the look rather than into it |
| `Look/PositiveFilmFilter.swift` | Bakes the profile into a 3D LUT and applies the Core Image chain |
| `Look/LookModel.swift` | Holds the live profile and keeps a baked filter in step with it |
| `Look/ColorMath.swift` | HSV conversion, tone curves, black point, vibrance |
| `Camera/CameraModel.swift` | Capture session, shutter, save |
| `Camera/CIImage+Square.swift` | The centred 1:1 crop shared by preview and capture |
| `Camera/PhotoEncoder.swift` | JPEG encoding, and the settings embedded in EXIF |
| `Camera/RAWDeveloper.swift` | Demosaics RAW with Apple's processing switched off |
| `Library/ShotStore.swift` | Every shot on disk |
| `Library/SnapshotStore.swift` | The frames the app leaves behind when it goes away |
| `Views/FilmStrip.swift` | The app's own roll along the bottom edge |
| `Views/ShotGrid.swift` | The same roll as a wall, and the frames picked off it |
| `Views/CaptionField.swift` | The line under a frame being reviewed |
| `Views/ShotThumbnail.swift` | One frame as a square, in the roll and in the favourites |
| `Views/ActionBar.swift` | The one row of buttons, and the handle that resizes the panel |
| `Views/DevelopPanel.swift` | The slider editor |
| `Views/FavoritesList.swift` | The kept frames, and the heart that opens them |
| `Library/BackupFolder.swift` | The folder the user picked, and how the app gets back into it |
| `Library/FavoritesBackup.swift` | Keeping every kept frame's files in that folder |
| `Views/BackupStatusLine.swift` | What that folder has of a frame, under its caption |
| `Views/SnapshotGrid.swift` | The background snapshots, and the starburst that opens them |
| `Library/ShotInfo.swift` | When, where and on what a frame was taken, read back out of it |
| `Camera/LocationTagger.swift` | The coordinate AVFoundation never writes |
| `Views/PreviewRenderer.swift` | Draws graded frames into Metal |
| `LaunchRoute.swift` | The one URL the app answers to, and what it means |

## Which way up

The interface is portrait-only and stays that way. The preview is pinned
upright to the screen, so turning the phone turns what is in the frame — which
is what a viewfinder that doesn't rotate looks like, and it isn't going to
change.

**The photograph is not pinned.** The photo output's rotation is read at the
moment the shutter is pressed, off gravity rather than off the interface, so a
frame taken with the phone on its side arrives in the camera roll the right way
up. This is the one place where what you see is not quite what you get, and it
is the one worth the exception: a viewfinder that leans is a viewfinder, and a
photograph that has to be turned in Photos afterwards is a photograph somebody
has to fix.

It is read rather than remembered. `AVCaptureDevice.RotationCoordinator` gives
`videoRotationAngleForHorizonLevelCapture`, which is a reading of where the
phone is now — asked on the press and applied to the connection immediately
before it, since a stale one would be worse than never having asked.
`UIDevice.orientation` would have been the other way to ask, and it answers
`faceUp` and `faceDown`, which are not angles a camera can use; the coordinator
holds the last real reading through both.

Nothing is reframed by this. The square is the *centred* square, and a centred
square is the same square after a quarter turn — the frame is turned, not
recomposed, and the edges of what you saw are the edges of what you get.

### The negative turns by tag rather than by pixel

A DNG holds undemosaiced sensor data, so there is no rotating one: what it
carries is an orientation tag, and the development reads it. That happens
already — `RAWDeveloper` has always taken the file's own orientation and handed
it to `CIRAWFilter` — which is why a negative shot sideways and re-developed
months later comes out the same way up as the JPEG taken beside it.

The square written into the DNG's `DefaultCropOrigin`/`DefaultCropSize` is in
sensor coordinates, which don't move when the tag changes. The crop that goes
in the XMP instead is in Camera Raw's own terms — fractions of the frame *as
displayed* — and swaps its axes on a quarter turn, which it already did.

### PS and the frames left behind

Those two come off the preview rather than off the sensor, and the preview is
pinned. So they are turned by the difference between the two angles, which for
a phone held in portrait is no turn at all. Otherwise **PS** would be the one
button in the app that still produced a photograph on its side.

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
it.

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
in the RAW section of the develop panel. When it fails, the crop rides in the
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
every shot whether or not the develop editor was ever opened, so any file
leaving the app — camera roll, share sheet — describes itself.

The profile decodes leniently: a key that isn't in the JSON keeps its default
instead of failing the whole decode, so shots saved by an older build still
load after new knobs are added.

## The roll

Every capture is written twice: to the camera roll, and to the app's own store
in `Documents/Snaps` as a matched `<uuid>.jpg` and `<uuid>.json`. The strip
along the bottom edge reads the store, which is why it shows only frames Snap
took. It holds 20 at a time with **Load More** for the rest.

The strip is laid once, under the action bar, and goes wherever that bar goes —
the foot of the camera screen, or up under the frame with the sliders beneath
it. It used to be laid twice, once at the foot of the camera screen and once
inside the panel, which is what let the two disagree about where the bottom of
the screen was.

Below the frame sit the exposure column at the left, then black-and-white, the
shutter and **PS** across the middle, the two round buttons equally far from
their own edge of the screen. The develop Exposure stepper sits at the right.
Under the shutter is a row of dots, one per lens, widening left to right
the way the lenses do and filled for the one in use. The exposure controls stand
in a column rather than a row to leave the middle of that row to the buttons.

Exposure steps in whole stops and is the same value as the panel's Exposure
slider — one setting reachable two ways. Holding the number between the two
steps for half a second clears it back to zero, which beats nine taps home from
five stops out. It is a develop setting rather than a camera one, so it
re-applies when a negative is re-developed and travels to Lightroom as
`crs:Exposure2012`.

Tap a thumbnail to open it in the viewer, where the shutter becomes an **X**
that returns to the live preview. The X is half the shutter's size, about as
big as **PS** and the black-and-white disc beside it: the shutter is large
because it is aimed at without looking, and putting a photograph down is
neither urgent nor blind. The row holds the height of the mode column while the
camera is live and only the X's own while a frame is up, and the height it
hands back goes to the caption below it.

**Share** and **Delete** flank it, one either side, as plain glyphs rather than
rings so the X between them stays the one to aim at: the two things left to do
with a photograph you have just looked at and made your mind up about. Both are
also in the long-press menu on its thumbnail, along with Share RAW, which is the
one that needs a menu.

The camera controls go with the exposure stepper while a saved frame is up:
lens, mode and black-and-white all decide how the *next* photograph is taken,
and none of them applies to one that already exists. Long-press for **Add to
Favorites**, **Use Develop Settings** (puts that shot's settings back on the
sliders), **Share JPEG**, **Share RAW** (only when the capture was RAW), or
**Delete Image**.

Under the frame, the row that names what is being shown — **JPEG** or **RAW** —
gains a heart at its other end when the frame is one you kept. It used to sit in
the corner of the photograph; a photograph is worth more undisturbed than a
corner of it is worth as a label. Below that row, in the space the exposure
values hold open, the frame says when and where it was taken and on what — the
same four lines the develop panel opens with, described under [What the frame
is](#what-the-frame-is). Those rows set how the *next* photograph is exposed and
have nothing to say about one already taken, so the room is free.

**Below that is a line to write on.** Whatever is typed there becomes the
frame's caption, saved when the keyboard goes away — Return makes a second line,
and **Done** above the keys is what puts it down. It is the same caption the
naming sheet asks for after a titled capture: one line of text per photograph,
reachable two ways, the way Exposure is one setting reachable two ways.

The caption is written into the frame's own EXIF as well as into its sidecar,
into both of the fields readers call by that name — TIFF `ImageDescription`,
which is what most tools show, and IPTC `Caption-Abstract`, which is what Photos
and the Adobe applications read. No pixel is re-encoded to do it:
`CGImageDestinationCopyImageSource` carries the JPEG across as it stands and
rewrites only the metadata around it, so a caption can be edited as often as you
like without spending a generation of quality, and everything already in the
file — the look in the user comment, the exposure, the coordinate — comes back
with it. Clearing a caption removes the tags rather than writing an empty
string. The camera roll's copy was written at the moment of capture and doesn't
get it; the file in Snap's own store does, and that is the one **Share JPEG**
sends.

Typing hands the bottom of the screen to the keyboard, so the square gives up
the difference — the same trade the develop panel's handle makes — and the
frame, what it says about itself, and the words being written about it all stay
above the keys. It never gives up more than half: a caption is written about a
photograph, and the photograph has to still be there.

**Swipe the frame** left or right to move along the roll. Left carries it the
way the strip runs — newest at the left, older to the right — so a swipe goes
to the older frame and back again, and stops at each end rather than wrapping
round to the other one. The swipe is deliberately long, and gives up the moment
it drifts vertically, so a hold that wandered still peeks at the negative
instead of turning the page. It works the same way over a negative loaded under
the sliders, where it walks only the frames that have a negative to develop.

**The strip follows.** Whatever is in the viewer is centred in the roll below
it — after a swipe, after a frame is opened out of the favourites or the grid,
after a negative is stepped under the sliders. The strip is the map of where you
are in the roll, and a map that stays where you left it is not one. It scrolls
rather than jumps, so which way you went is visible in the going, and it loads
another page first when the frame sits past the end of the one it is showing.

**Delete Image** deletes the photograph rather than only the app's copy of it:
the store's JPEG, its negative and its sidecar go, and so does the asset in the
camera roll that the same capture wrote. iOS puts its own confirmation in front
of that half, and declining it leaves the camera roll's copy standing. Frames
taken before the app started recording which asset it had created have only the
app's copy to remove.

**Deleting the frame you are looking at stays in the viewer**, with the next one
along the roll — the older one, the way a swipe reads — already up, or the one
before it when what went was the last. Clearing out is done a frame at a time,
look and decide and delete and look at the next, and being dropped back at the
live preview after every one of those meant tapping your way back into the roll
to carry on. Only an empty roll puts the camera back, since then there is
nothing left to look at.

Two kinds of frame are marked in the corner of their thumbnail: a dot for one
taken with **PS**, and a square for one made in the develop screen — a
re-developed negative, or a capture from the panel's own menu. Everything else
came off the shutter.

## The action bar

Under all of that, and directly above the roll, is the app's one row of
buttons, and it is split by what its halves are for. At the left, what the app
*is*: **Develop**, and the heart that opens the favourites. At the right, what
is on *screen*: four filled squares that show and hide the roll, and a starburst
for the frames the app left behind while it was away. Neither of the two on the
right changes anything — they only decide what you are looking at — which is why
they keep to their own end.

The bar and the roll are attached. Tapping **Develop** lifts the pair to just
under the frame and fills in the sliders beneath them, while everything to do
with taking a photograph — the shutter, the modes, the lens dots, the caption —
leaves upward and slides in behind the frame. Tapping it again puts it all back:
it is one switch, in one place, and it reads as lit while the sliders are open.

There was a **Done** beside Reset that did exactly that, which made one switch
look like two — and between a word that appears at the far end of the bar only
while the panel is open and one that sits in the same place whichever screen you
are on, the second is the one worth keeping.

**Reset** fades in past the starburst on the way up, along with a drag handle at
the bar's centre, around buttons that were already there and don't move. Nothing
else arrives: what the panel can do lives in the panel, at the foot of the
sliders it belongs to, and the capture is a button of its own under the frame.

This was two bars: Develop and the heart centred under the shutter on the
camera screen, and the same two left-aligned in the panel's header once it
opened, with the roll laid separately under each. The same two buttons in two
arrangements read as two different pairs, and a bar that is in one place is
easier to learn than a bar that is in two.

The four filled squares drop the roll out from under the bar and bring it back.
With the panel open that is another two inches of sliders; with it closed it is
a frame with nothing under it but the shutter. It dims rather than lighting in
the accent when the roll is down: the one colour this interface has is spent on
settings that change the photograph, and whether the roll is showing is not one
of them.

**Holding them opens the whole roll as a wall.** Four squares are already a
picture of a grid, so a grid is what holding them gets you: the same frames the
line under the bar is showing, laid out as a page rather than a line — three
across, newest first, wearing the same corner marks. Tapping one opens it in the
viewer, and the strip underneath scrolls to it; with the develop panel up it
loads under the sliders instead, the way a frame chosen from the favourites
does. Double-tapping keeps it, as double-tapping a frame does anywhere else,
and holding one offers keep, **Share JPEG**, **Share RAW** and **Delete Image**
— the roll's own menu less Use Develop Settings, which belongs to the strip you
develop from.

**Select** at the top left turns the wall into checkboxes, and what is ticked
can be shared or deleted together. Deleting several asks first and says how
many, and the camera roll is asked for the lot in one go — iOS puts its
confirmation in front of each request, and a dozen frames should be one question
rather than a dozen. The wall stays in select mode with nothing ticked
afterwards, since clearing out is rarely one pass.

It is built the way the snapshots are, since it is the same shape of screen and
the two shouldn't read as two ideas. The one thing it doesn't borrow is
**Clear**: emptying a wall of accidents is housekeeping, and emptying a roll of
photographs is not something to leave one tap away.

The tap and the hold are said as an exclusive pair rather than as a button with
a hold hung off it. Any other way round, the tap fires as the finger lifts, and
the roll would drop out from under the wall that had just opened over it.

## Favorites

**Double-tap a frame to keep it** — a thumbnail in the roll, the frame in the
viewer, a negative under the sliders, or a row in the favourites. A small heart
appears in the thumbnail's lower left corner, in the same white as the corner
marks above it, because the two are one language rather than two. A frame open
in the viewer says the same thing in the row below it rather than on top of it,
opposite the label that says which of its two renderings you are looking at.

The heart on the action bar opens the kept frames as a list, one to a row: the
square on the left, and on the right when it was taken, where, and whatever was
written about it. A wall of squares is a good way to find a photograph you can
already picture and a poor way to read a roll. The heart is out while nothing is
kept: an empty list isn't worth a screen.

Tapping a row opens that frame in the viewer. Double-tapping its square lets it
go, and it leaves the list as it does. **Double-tapping the caption opens it for
editing in place**, with Save and Cancel under the field — the same division
between a tap and a double tap the roll makes, and the same caption the review
screen writes, so it lands in the sidecar and in the file's EXIF exactly as it
does there. A row with nothing written on it says *Add a caption*, which is
where one gets written.

A swipe in the viewer walks the roll, however the frame was reached. It used to
walk whichever list the frame was opened from — come in from the favourites and
you stayed among the ones you kept — which meant one gesture meant two things,
and from a short list of kept frames it meant nothing at all: two favourites,
and a swipe had nowhere to go. The strip under the frame is the roll, it scrolls
to whatever is up, and what a swipe moves along is the thing you can see it
moving along.

The list is a second window onto the same roll rather than a second roll —
nothing lives in it that isn't in the store, and keeping is one flag in the
shot's sidecar. Opening a frame from it while the develop panel is up loads it
under the sliders, the way tapping it in the roll does.

### Backing up what you kept

**Set Backup Folder**, in the menu at the top left of the list, asks for one
directory and then keeps every kept frame's files in it. The JPEG always; the
negative and its Camera Raw sidecar as well when the capture was RAW, since
apart the two of them mean nothing.

Snap does not sync anything. It writes into a folder somebody chose in the
system picker — iCloud Drive, Dropbox, Google Drive, anything with a file
provider behind it — and whatever owns that folder does the carrying. That is
the whole arrangement, and it is the reason there is no account to sign in to,
no progress bar worth watching, and nothing to configure but the one directory.
Choosing a folder your phone already backs up is the entire feature.

The rest of the menu appears once one is set: **Back Up Now**, **Change
Folder**, and **Stop Backing Up**, under a header naming where things are
going. Stopping leaves the folder exactly as it is. Those files are the user's,
in the user's folder, and an app that took them back out because a setting
changed would not be a backup — the same reason letting a frame go doesn't
reach in and remove its copy either.

Files are renamed on the way across: `Snap-2026-03-14-172309-9F3C1A0B.jpg`. The
store names its own files by UUID, which is the right name for a file nobody
opens and the wrong one for a folder somebody does — this reads as a date and
sorts as one, with the head of the UUID after it so two frames taken in the
same second stay two files. The `.dng` and `.xmp` take the same base name,
since Adobe finds a sidecar by matching it. And because the name is a function
of the shot rather than of when it was sent, a frame kept, let go and kept
again recognises its own copy instead of writing a second one.

**Under each caption, the row says what the folder has of it** — *Backed up ·
JPEG + RAW*, small and grey, next to nothing to read and nothing to do. It sits
below the caption because the lines above it are what the photograph is and
this is what has happened to it since, and because it is the only line in the
row with anything to do. While files are actually going across, the pane's
title reads **Backing Up** — said once, at the top, rather than as a spinner on
every row.

### The one case that isn't quiet

A folder somebody can open is a folder somebody can delete out of, so the
folder is *checked* rather than assumed. When a file that was copied is no
longer there, the row turns yellow, says which of the two formats went, and
offers the only two answers there are: **Resend**, or **Remove from Favorites**.

It does not simply put the file back. Re-copying on sight would be an app
arguing with a person about their own folder, and would make a deletion
impossible to carry out — the second answer exists because deleting the file
was very often the point. Yellow is already the colour of a reading that wants
looking at here; the EV number past a stop and a half wears the same one.

The same warning covers a copy that didn't finish, and a folder that has stopped
resolving — signed out of, renamed away, a provider uninstalled — which is worth
saying rather than reporting every frame as safely backed up somewhere
unreachable.

A file that is in the folder but not on *this* phone is a placeholder rather
than an absence: iCloud lists it as `.name.jpg.icloud`, which is the backup
working, not the backup failing, and the check reads the name back through
before deciding anything.

### Why none of it is in the way

The rule this is built around is that it may cost nothing at launch and nothing
at capture. So nothing runs on the way up, nothing is called from the shutter,
and every pass happens on one serial queue at utility priority, with the
folder's security scope held for exactly as long as the work takes.

Three moments start a pass, and there is no fourth:

| | |
| --- | --- |
| **A frame was kept** | Copies whatever the folder hasn't got, which is almost always the one file. Keeping is a decision made after the photograph rather than during it, so this is a moment with nothing else happening in it. |
| **The favourites opened** | The one screen any of this is visible on, and so the one worth a look at the folder. |
| **The app came forward** | Deferred four seconds, and dropped entirely if the folder was listed within the hour and nothing is outstanding. |

The third is the only one that can land near a launch, and it is the one that
does least: it waits for the camera to have its moment, and most of the time it
wakes up, reads a date, and goes back to sleep. Checking is one directory
listing — asking after each file on its own would be a round trip to the
provider per frame per format — and what came back last time is remembered in
`Documents/Backup.json`, which is a cache rather than a record. The folder is
the truth. If that file doesn't decode, the next listing rebuilds it; the one
thing it is there for is telling *never copied* apart from *copied, then taken
out*, which are the two cases that want opposite answers.

What the picker hands over is a URL that stops working when the app is
relaunched, so what is kept is a bookmark to the folder rather than a path —
the one thing that survives it being renamed or moved. Resolving one can go out
to a file provider, so it happens on that same background queue and never for
the sake of drawing a menu: the folder's name is remembered separately, which
is all the menu needs to say where things are going.

## Background snapshots

*Experimental.*

Put a camera app down without closing it and come back an hour later, and the
preview is still showing the frame it froze on when you left — a photograph of
wherever you were standing when the phone went in your pocket. Every camera app
does this. None of them keeps it: the frame is thrown away the moment the
session restarts.

Snap keeps it. The starburst at the right of the action bar opens them as a
grid — a wall of squares, which is the right way to look at frames nobody
composed and nobody wrote anything about. Tap one to see it whole, with when and
where it was left behind under it; long-press for **Share JPEG** or **Delete**.

The menu at the top left holds the three things you can do to the collection
rather than to one frame: **Select** turns the wall into checkboxes, with export
and delete for whatever you tick; **Export All** hands the lot to the share
sheet; **Clear** empties it, after asking.

They live in `Documents/Snapshots`, one JPEG each, apart from the roll and never
written to the camera roll: these are not photographs anybody took, and they
shouldn't turn up in a year's worth of ones that were. They carry their look in
EXIF like everything else the app writes, since they were graded on the way to
the screen — and the moment and the coordinate go in with it. AVFoundation
stamps a real capture with the time it was taken but hands over nothing at all
for a frame taken off the preview, so Snap writes both itself. A snapshot is a
photograph of somewhere at some time like any other, and that belongs in the
file rather than in a list the app keeps beside it. Preview frames from **PS**
are stamped the same way, for the same reason.

Two hundred are kept and then the oldest go — one lands every time the app is
put down with the preview up, which over a month is a great many frames of the
inside of a pocket, and an experiment shouldn't quietly fill a phone.

### Why it is done in two halves

The frame is *rendered* when the app goes inactive and *written* when it goes to
the background, which are two different moments on purpose.

What the renderer is holding is a recipe rather than a picture — the graded
frame is a chain of Core Image filters that costs nothing until something draws
it. Drawing it is Metal, and an app that reaches for the GPU once it is in the
background has its command buffer killed. Inactive is still the foreground: it
is the same moment an app blurs itself before the switcher takes its picture,
and rendering there is allowed. So the JPEG is encoded on the way out and held
in memory, and going to the background is only a file write.

Which also gives the feature its cancel. Inactive happens for anything that
takes focus — a notification, the control centre, a glance at the switcher — and
most of those come straight back. Returning to active throws the held frame
away, so only actually leaving keeps one.

A frame is kept only when the live preview is what is on screen. A saved frame
in the viewer freezes as itself, and that one is already in the roll; a negative
under the sliders freezes as a re-development of a frame that is also already in
the roll. Neither is a moment about to be lost.

## Sub-profiles

The look is built in daylight, and daylight is not where every photograph gets
taken. Under a warm lamp it comes out yellow, because a profile that assumes
5500K has no way to know it isn't; in a dark room it comes out grainy, because a
curve built to open shadows opens the sensor noise living in them.

Both are corrections rather than changes of mind about the look, so they don't
touch it. **Two small buttons above the shutter** — a house and a moon — lay a
named handful of settings over the top of the base profile, lit in the one
colour this interface has for something switched on:

| | Sets |
| --- | --- |
| **Indoor** | Temperature −20, which takes the yellow off a lamp-lit room without pretending it is daylight |
| **Night** | Exposure −0.6 and Shadows −40 — down, and shadows *closed* rather than opened, since what is in the shadows of a dark frame is mostly noise |

A sub-profile *sets* the settings it names rather than nudging them, so a toggle
means the same thing wherever the base happens to be sitting, and switching it
off puts the frame back exactly. Both at once apply in the order they sit in the
row.

Nothing here edits the base profile. The develop panel's sliders go on showing
the base values while one is lit, because the base is still what is being worked
on — the sub-profile is laid over it at the moment of rendering, by
`PositiveFilmProfile.resolved`, which is what every bake, capture and sidecar
goes through. What is *stored* keeps the two apart: the frame's EXIF carries the
base profile and the flags separately, so a shot can be reopened with its
sub-profile still switchable rather than baked into numbers nobody can pick
apart again. **Use Develop Settings** on such a frame lights the same buttons it
was taken with.

A frame taken with one lit says so on the review screen: the same house or moon
sits beside its shutter speed, in the same yellow.

### Temperature

Indoor needs a white balance to work with, so the Basic panel has one — a
**Temperature** slider in Lightroom's relative −100...100 units, negative for
cooler, first in the section the way a white balance comes first in any raw
pipeline.

It is baked into the same lookup table as everything else that is a pure
function of colour, which is what keeps the preview and the capture identical.
The maths is the temperature axis of a white balance and nothing more: red one
way, blue the other, green untouched, ±25% at full deflection, with the gains
divided through by what they do to white so the frame changes colour without
changing brightness. Green is the tint axis, and Snap has no tint slider — one
axis is what fixes a room.

The negative is the one place it can't fully follow. Camera Raw keeps a raw
file's white balance in Kelvin and reserves `crs:IncrementalTemperature` for
relative edits, which it may well ignore on a DNG; the sidecar writes it anyway
when it is non-zero, and where it is ignored the negative opens at the
temperature it was shot at, which is the honest fallback.

## Exposure

Two of the three classic modes mean something on a phone. An iPhone lens has a
fixed iris — `AVCaptureDevice.lensAperture` is read-only because there is
nothing to move — so aperture priority would be indistinguishable from auto,
and nothing sits where that button would be. The f-number was shown there for a
while as a readout; a number that never changes doesn't earn a place among
controls that do.

### Two pins, and the four things they mean

The column beside the frame is four cells: **A**, the shutter, the ISO, **M**.
The two in the middle are the settings themselves rather than letters standing
for them — they read what the camera is actually running at, **1/250** and
**ISO 400** — and tapping one opens the row that changes it.

**Colour says who is holding it.** Yellow means that setting is pinned, grey
means the camera is choosing it, everywhere the setting appears: the cell in the
column, the label at the head of its row, and the chosen stop within the row.
There is no fifth thing yellow can mean in this interface.

Each of the two is pinned or not on its own, and the *mode* is the reading of
that pair rather than a switch of its own:

| Shutter | ISO | Is |
| --- | --- | --- |
| camera | camera | **Auto** |
| pinned | camera | Shutter priority |
| camera | pinned | ISO priority |
| pinned | pinned | **Manual** |

**A** lets both go. **M** takes both, borrowing whatever the camera had arrived
at rather than jumping to numbers nobody chose, and opens both rows. The other
two states are reached by pinning one setting and leaving the other alone.

This is a repair as much as a rearrangement. The mode used to be the thing that
was stored, and the pins hung off it — so choosing an ISO while the mode said
auto set a number that auto then ignored on its way past, handing the whole
exposure back to the camera. The ISO you picked did nothing. A pin is a pin now,
and the mode is only its name.

### Neither priority is a mode iOS has

`setExposureModeCustom(duration:iso:)` fixes both halves; there is nothing in
between it and full auto. So both priorities are built the same way — pin both,
then nudge whichever half the photographer isn't holding toward the meter, using
`exposureTargetOffset`, which reports its error in stops.

Stops are exactly the units ISO scales in, so shutter priority is a single
multiply. Duration scales linearly with exposure, so ISO priority is the same
multiply on the other number. `AVCaptureDevice.currentExposureDuration` and
`currentISO` are the sentinels for "leave that half where it is", which is what
makes a half-pinned state expressible at all.

ISO priority bottoms out where the format does: a dark room at ISO 100 runs out
of shutter before it runs out of dark, and the frame is simply under. The EV
readout says so, which is the honest answer — quietly moving the ISO somebody
pinned is not.

### The rows

Tapping the shutter cell or the ISO cell opens that setting's row under the
frame, and tapping it again closes it; **M** opens both, **A** closes both. The
offered stops are trimmed to what the active lens and format actually accept,
and **AUTO** heads each row — handing that setting back is a choice like any
other, and it used to be buried in a menu.

The screen holds both rows' worth of height whether or not either is open, so
opening one reveals a row rather than pushing the frame, the shutter and the
roll down to make space.

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
sit from what the meter wants, in stops, negative for under. It is up whenever
the camera is what the screen is showing, auto included — it used to appear only
for the modes that drive the exposure by hand, on the grounds that auto holds it
at zero, but it does not sit at zero: it wanders while auto chases the scene,
and watching it settle is how you know the meter has. Past half a stop it
brightens; past a stop and a half it turns yellow. Anything that isn't the
camera puts it away — a saved frame in the viewer, a negative under the sliders
— since the reading belongs to whatever is about to be taken, and both of those
are photographs that already exist.

Tapping it takes the reading back the other way: a frame the meter calls 1.5
stops under sets Exposure to +1.5. It replaces rather than accumulates, because
the reading is about what the camera is doing and doesn't move when the develop
exposure does — so tapping twice means the same as tapping once. This is a
correction in the develop rather than in the camera; to fix it at the sensor
instead, move the shutter or ISO row and watch the number come back to zero.

The readings themselves are kept off `CameraModel` on purpose. They change
several times a second, and anything published there invalidates the whole
camera screen at that rate — enough to make a long-press menu flicker and
swallow the tap that follows it. `ExposureMeter` is its own small observable,
watched only by the two things that want it: the EV readout, and the exposure
column, which redraws four small cells rather than a screen.

It carries three numbers — the offset, and what the camera has actually settled
on for ISO and for shutter — and all three are read off the device rather than
remembered from the last thing the app set, which is what makes the two cells
right in auto as well as by hand. Each drops changes finer than it can show: a
tenth of a stop for the offset, a whole number for ISO, and for the shutter a
sixteenth of a stop, since the difference between 1/60 and 1/61 is not worth a
redraw and the difference between 1" and 1/2" is the same size.

Video HDR is switched off for the same reason. Left on, the video stream gets
local tone mapping the still explicitly does not, so the preview would show
recovered highlights and lifted shadows the negative never had.

Holding to focus moves focus only. Choosing what is sharp and choosing what is
bright are separate decisions, and the exposure controls own the second.

A rule-of-thirds guide sits over the live preview. Holding anywhere on it for
a second pins focus to that point and marks it with a yellow ring; any tap lets
it go again. Switching lens releases the point too, since it
means nothing on another lens.

A monochrome frame stays monochrome. Loading one for re-developing switches
B&W on and locks it: the colour it was rendered without isn't in the JPEG, and
re-developing it back to colour would quietly produce a different photograph
from the one that was taken. Exporting the DNG still gets you the colour.
Ending the session only puts B&W back the way it was if loading the negative
is what turned it on.

Preview frames have no negative, so they can't be re-developed — they show
dimmed in the roll while the panel is open, don't respond to a tap, and put
**Develop** out
while one is in the viewer. Their menu still works; they can be shared,
deleted, or have their settings borrowed.

**PS** beside the shutter saves the preview frame itself, skipping the RAW loop
entirely — no sensor round trip, no demosaic, no full-resolution grade, since
the graded frame is already on screen. It is as close to zero shutter lag as
the app gets, at the cost of coming out at preview resolution with no negative
behind it.

**The circle with a diagonal through it**, to the left of the shutter as PS is
to its right, renders the frame monochrome; switching it on inverts it to a
white disc with a black cut. The conversion happens at the *end* of the grade
rather than the start — so the colour mixer still shapes it, the way a
black-and-white mixer does:
desaturating a band changes that band's luminance. The negative keeps its
colour data, since this is how the frame is rendered rather than what was
recorded, but peeking at it behind a monochrome look shows it desaturated so
the two are comparable.

Storing full-resolution copies is what makes Share work on the original file
rather than a thumbnail; it also means the app's storage grows with use, and
Delete is the way to reclaim it.

## Re-developing a negative

The roll rides up with the bar when the panel opens, so it sits between the two.
Tapping a frame in it loads that frame's negative under the sliders in place of
the live camera, and moving a slider regrades it as you go — the label under the
frame reads **JPEG**, and holding the frame peeks at the ungraded development
the same way the saved-frame viewer does, where it reads **RAW**. It used to
read VERSION, which named the screen rather than the frame; the screen already
says Develop at the other end of the bar, and the one question that corner
answers — which of the frame's two renderings am I looking at — is the same
question it answers in the viewer, so it gets the same two answers. The loaded
frame is outlined in its thumbnail, and the strip scrolls to it — when the panel
opens, since a frame chosen on the way in may sit well down the roll, and again
each time a swipe steps to the next negative. Tapping that same thumbnail again
puts the negative down: the live preview comes back under the sliders, still
open.

**Snap** becomes **Capture Version** while a negative is loaded, and runs the same
pipeline the shutter does — develop, crop, grade, encode, square the DNG,
embed the settings — over the stored sensor data instead of the sensor. The
result is a new shot in its own right, not an edit of the old one, which is
why both share `prepareNegative`: a captured file and a re-developed one should
be indistinguishable apart from where the photons came from.

Re-grading is cheap because the negative is demosaiced once at viewer size and
kept; only the **Apple Tone Curve** slider feeds the RAW pipeline itself, so
only that one costs a re-develop.

## The develop editor

**Develop**, at the left of the action bar, fills everything below the bar with
every knob the look exposes and lights while it does, grouped the way Lightroom
groups them — Basic, Tone Curve, Color Mixer, Calibration, RAW. Moving a slider
regrades the live preview. Double-tap any slider to return it to neutral.

A saved frame that was open in the viewer comes along, as the negative behind
it rather than as the finished JPEG it was: same square, same subject, but live
under the sliders and ready to be re-developed. Develop changes the controls, not
what is being looked at.

Which is why **Develop** goes out while a preview frame is up. **PS** saves what
was already on screen and keeps no negative, so there is nothing behind that
JPEG for the sliders to reach — the button is dim rather than misleading, and
putting the frame down with the **X** brings it back.

The panel's own three actions are in three different places, because they are
three different kinds of thing.

**The capture is a button of its own under the frame**, centred, where the
shutter would be if you followed the frame's middle down. It says what it will
make rather than what it is: **CAPTURE VERSION** over a negative under the
sliders, **CAPTURE** over the live camera.

It was briefly the label in the corner — the one that used to read VERSION —
which put an action in the one place on that row reserved for saying what
something *is*. The corner is a label again, and the button is a button.

**Load Settings** and **Save Settings** sit side by side at the foot of the
sliders, under the RAW section. Load offers every shot as a card, newest first;
tap one to put its settings back on the sliders, swipe to delete. Save captures,
then asks for a title (defaulting to the timestamp) and a caption, and keeps the
look with the frame. They are neither ways out of the panel nor sliders, and the
end of the list is the one place that is neither.

Capture and Save both capture, store, and save to the camera roll — the only
difference is that Save ends at the naming sheet. Both mark the frame as made in
the develop screen, so the roll shows where it came from.

All three of these were a menu on the action bar before that, and a bar across
the bottom of the panel before that. A menu is a good place for things that have
nothing to do with each other; these three each have somewhere they belong.

### What the frame is

At the top of the sliders, while a negative is loaded, four short lines say what
is being developed: **when and where** on the left, **shutter and ISO** on the
right. A photograph is placed by time and by ground, and taken at a shutter and
a sensitivity, so each side reads as a pair — the first line of each carries the
reading and the second qualifies it. The same four lines sit under a frame open
in the viewer, in the same place relative to it, since the question there is the
same one.

**Tapping the place opens it in Google Maps** — an ordinary
`https://www.google.com/maps` link, which the app claims, so the tap lands in it
when it is installed and in a browser showing the same map when it isn't. Going
through a URL scheme instead would mean declaring it in the Info.plist for the
sake of asking whether the app is there.

Everything comes out of the file rather than out of the app's own records, the
same way the look does, so a frame taken by an older build still describes as
much of itself as it recorded. The timestamp is EXIF's `DateTimeOriginal`,
falling back to the shot's own; the shutter reads as a fraction until it passes
a second and as seconds after that; the coordinate is turned into the name of
somewhere by CoreLocation, and reads as degrees until that comes back — and goes
on reading as degrees if it never does. Reverse geocoding is a network round
trip that Apple rate-limits, so every answer is kept: a roll shot in one
afternoon is mostly one place.

The section is absent while the sliders are over the live camera. That isn't a
photograph yet — it has no timestamp and no place, and its shutter and ISO are
already on the rows above the panel.

**iOS never writes a coordinate into a capture.** `AVCapturePhoto.metadata`
carries exposure, lens and timestamp and nothing about where the phone is, so
Snap asks CoreLocation itself and writes the GPS block on the way to JPEG —
which means the coordinate travels with the file to the camera roll and through
the share sheet, not just to this readout. The fix is asked for while in use
only, to a hundred metres, and one older than five minutes is dropped rather
than written: a photograph is placed to the street, and no coordinate beats the
wrong one. A re-developed negative inherits the place of the frame it came from,
since it is the same photograph.

### Trading preview for panel

A handle fades into the centre of the action bar while the panel is open.
Dragging it up pulls the bar, the roll and the sliders over the preview, and the
square gives up exactly what they gain, which keeps the frame square while it
shrinks. The drag stops at 45% of the width — past that the viewfinder has
stopped being one. Closing the panel hands the whole square back.

### Copy Adjustments

At the foot of the sliders, **Copy Adjustments** puts everything that has moved
off the built-in look on the clipboard, one setting per line, each named the way
its slider is. Settings still sitting at their default are left out, so what
lands in a note is the *difference* — which is what a look is, and what would be
pasted back into `PositiveFilmProfile.swift` to make it the new default. The
button reads Nothing Adjusted while there is no difference to copy.

Those lines are printed under the button as well. The clipboard is not a place
you can look, and this is also the shortest way to read what a frame actually
is without walking forty sliders looking for the ones that moved. A lit
sub-profile is named there rather than expanded into the settings it sets,
since it is a switch rather than an edit.

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

### Both of them open the camera, not the app

Coming in from the lock screen means a photograph is about to be taken, now.
What the app was left in the middle of last time has nothing to do with it: a
negative under the sliders, the favourites open, an exposure pinned five stops
out, a look three sliders from the one it ships with. So arriving this way puts
all of it back — capture screen, auto exposure, the wide lens, the built-in
profile, Exposure at zero — and a camera reached in a hurry is the camera you
learned rather than the one you left. Opening the app any other way is
untouched: coming back to it is coming back to what you were doing.

An app cannot tell a launch from a resume, so the two entries say which is
happening by carrying a URL: `snapsquarecamera://capture`, the widget as its
`widgetURL` and the control as an `OpenURLIntent`. The control used to run an
`AppIntent` with `openAppWhenRun` and no body, which launched the app and told
it nothing — an intent performed out in the extension has no way to reach into
the app and say where the tap came from, and without an app group there is
nowhere to leave a note either. A URL is the one thing that crosses on its own.
`LaunchRoute` in the app answers it; `SnapLaunch` in the extension writes it.
One string in two targets, changed together, since the extension cannot see the
app's files.

The extension ships inside the app, so there is nothing extra to install — its
bundle identifier is the app's with `.widgets` on the end, and it has to share
the same signing team.

Its `Info.plist` lives in `Config/`, not beside the sources. A
`PBXFileSystemSynchronizedRootGroup` sweeps in *every* file under its folder,
so a plist left in `SnapWidgets/` gets copied as a bundle resource as well as
processed as the target's Info.plist — two build tasks writing the same output.
Keeping it outside the synchronised folder is what stops that; the same applies
to anything else added there that isn't source.

The app has one there too, `Config/Snap-Info.plist`, holding the URL type and
nothing else. Everything else in its Info.plist is generated from build
settings, which can say a string but not an array of dictionaries; a file and
the generated keys merge into one plist, which is the arrangement the widget's
own already had.

## Deliberately not here

Front camera, flash, zoom. The capture screen is a preview, a button, and the
roll. (Focus tap and the rule-of-thirds guide were on this list until they
weren't; the thumbnail grid the four squares now open is a way of looking at
the roll rather than a thing on the capture screen.)

Film noise is coming back later.
