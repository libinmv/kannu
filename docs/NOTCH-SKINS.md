# Notch skins

A notch skin is an image Kannu draws behind the notch, in place of the plain black fill. It shows
when the notch is open and, as a thin strip, when it is closed.

Pick one under **Brain › Appearance › Notch skin**:

- **Default**: the plain fill.
- **Horns**: red and black, built in.
- **Your own**: click **Upload skin** or drop an image on the grid. PNG, JPG, WebP, HEIC, GIF and
  SVG work; a raster image must be at least 200 × 40 pixels. Right-click an uploaded skin to remove
  it.

If the agent light or the text is hard to read on a skin, raise **Scrim opacity**: it lays black
over the image, up to 60%.

## Size and safe areas

Kannu scales a skin to fill the notch and crops what does not fit, keeping the centre.

- **Open:** 640 × 200 points by default (wider if you widen the notch or turn on more tabs). An
  image of **1920 × 600 pixels** is three times that, so it stays sharp on a Retina display.
- **Closed:** about 150–200 × 32 points. The full width shows, cropped to roughly the middle half of
  the height.
- **The centre** holds text, icons, album art and the coloured agent light, so keep the middle
  60% of the width dark and quiet. Put decoration toward the left and right edges. Kannu
  picks dark or light text from the skin's average colour under its scrim, but a busy or bright
  centre still reads worse than a dark one.
- **The top centre** meets the camera housing: keep it close to black.
- **The corners** are rounded and clipped: keep detail about 40 pixels in from every edge.

## Design one with AI

Click **Copy AI prompt** in the same section, paste it into ChatGPT or another AI that makes images,
and answer its questions. It asks about mood, colours, motifs, how bold, and what to avoid, then
draws a skin that follows the rules above. Save the image and upload it with **Upload skin**.

This is the prompt it copies:

```text
You are a designer making a background image ("skin") for Kannu, a macOS app that lives in the MacBook notch. The image fills the panel that drops down from the top centre of the screen.

First, ask me these questions one at a time, and wait for each answer. Do not generate anything until I have answered all of them.
1. What mood or theme do you want? (For example: calm, cosy, sci-fi, retro arcade, nature, devilish.)
2. Which two or three colours should lead?
3. Any motifs, textures or patterns? (For example: circuit lines, marble, waves, embers.)
4. How bold should it be: subtle, balanced or loud?
5. Anything to avoid?

Then sum up my answers in one short paragraph and generate one image that follows these rules:
- 1920 × 600 pixels, landscape, PNG.
- Keep the centre (about the middle 60% of the width) dark and low in detail. Kannu draws text, icons, album art and a small coloured status light there, and they must stay readable.
- Put the decoration toward the left and right edges, balanced on both sides.
- Keep the top centre close to black, so it blends into the camera notch.
- Keep important detail at least 40 pixels from every edge: the corners are rounded and clipped.
- No text, letters, logos, watermarks, interface elements, people or faces.
- It must still look right as a thin horizontal strip through the middle, which is all the closed notch shows.

If I ask for changes, keep the same size and rules.
```
