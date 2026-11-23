# Paper

A macOS menu bar app that downloads public-domain paintings from museums and
rotates them as your desktop wallpaper.

Paintings come from the open-access collections of the Met, the Rijksmuseum,
the Art Institute of Chicago and the Cleveland Museum of Art. No account or API
key is needed.

## Requirements

- macOS 14 or later
- Apple's command line tools, with Swift 5.10 or later: `xcode-select --install`

Built and tested on Apple Silicon; Intel Macs are untested.

## Install

Download or clone this repository, then from its folder:

```sh
Paper/build.sh --install
open /Applications/Paper.app
```

`build.sh` without `--install` only builds `Paper/build/Paper.app`.

## Use

Paper lives in the menu bar and has no Dock icon. It starts with no paintings,
so choose **Download New Collection…** and search for an artist, subject or
style, such as "Venice". Each search is saved as its own collection. Once you
have some paintings, Paper picks one within a minute or so.

- **Rotate Now** changes the wallpaper straight away, as does ⌃⌥⇧⌘R from any app.
- **Add to Favourites** makes a painting four times as likely to be picked.
- **Don’t Show Again** hides it and moves on. Bring hidden paintings back from
  the Collections menu.
- **Collections** turns whole collections on or off.
- **Change wallpaper** sets how often it rotates, from hourly to daily or never.

Paintings are kept in `~/Pictures/Wallpapers`, one folder per collection.

## What gets downloaded

- Only works the museums mark as public domain, or that the Rijksmuseum lists
  with an image available.
- Religious subjects are left out. The list is `excludeKeywords` in
  `Paper/Sources/Paper/Downloader.swift`. It matches words, so it sometimes
  drops a secular painting.
- Landscape orientation only, unless you turn that off.
- From the Met, only European Paintings dated 1400–1850.
- A search of several words keeps paintings that match any of them.

## Command line

```sh
/Applications/Paper.app/Contents/MacOS/Paper --download "Venice" --count 20
```

| Option | Meaning |
| --- | --- |
| `--download TERM` | Download without opening the menu bar app |
| `--count N` | Most images to save (default 300) |
| `--museums met,rijks,aic,cma` | Museums to search (default all) |
| `--any-orientation` | Include portrait paintings |
| `--root DIR` | Use a folder other than `~/Pictures/Wallpapers` |
| `--open-at-login on\|off` | Turn opening at login on or off |

## Uninstall

Turn off **Open at login**, quit Paper, and delete `/Applications/Paper.app`.
Your paintings stay in `~/Pictures/Wallpapers` until you delete them.

## Licence

The code is under the [MIT License](LICENSE). The paintings aren't part of this
repository; check each museum's terms for reusing its images.
